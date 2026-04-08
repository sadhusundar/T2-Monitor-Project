###############################################################################
# service_tempo.tf — Tempo (traces, S3 backend)
# Receives OTLP directly from the OTel Gateway NLB on ports 4317/4318
# Host-mounted /data/tempo for WAL
###############################################################################

resource "aws_ecs_task_definition" "tempo" {
  family                   = "otel-staging-tempo"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn
  cpu                      = "512"
  memory                   = "1536"

  volume {
    name      = "tempo-data"
    host_path = "/data/tempo"
  }

  container_definitions = jsonencode([
    {
      name      = "tempo"
      image     = "${var.ecr_base}/tempo:${var.image_tag}"
      essential = true
      user      = "0"   # root so it can write to /data/tempo host mount

      command = ["-config.file=/etc/tempo/config.yml", "-config.expand-env=true"]

      portMappings = [
        { containerPort = 3200, protocol = "tcp" },
        { containerPort = 4317, protocol = "tcp" },   # OTLP gRPC from gateway
        { containerPort = 4318, protocol = "tcp" },   # OTLP HTTP from gateway
      ]

      mountPoints = [
        { sourceVolume = "tempo-data", containerPath = "/var/tempo", readOnly = false }
      ]

      environment = [
        { name = "AWS_REGION",                  value = var.aws_region },
        { name = "S3_BUCKET",                   value = var.s3_bucket  },
        { name = "PROMETHEUS_REMOTE_WRITE_URL", value = "http://prometheus.observability.local:9090/api/v1/write" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/otel-staging/tempo"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "tempo"
          "awslogs-create-group"  = "true"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3200/ready || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 5
        startPeriod = 90
      }
    }
  ])

  depends_on = [aws_cloudwatch_log_group.otel_staging]
}

resource "aws_ecs_service" "tempo" {
  name            = "otel-staging-tempo"
  cluster         = data.aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.tempo.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets          = [var.subnet_id]
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services["tempo"].arn
  }

  scheduling_strategy                = "REPLICA"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [aws_ecs_cluster_capacity_providers.main]
}
