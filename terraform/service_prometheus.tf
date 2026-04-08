###############################################################################
# service_prometheus.tf — Prometheus + Thanos Sidecar (single task)
#
# Two containers share a task so they share the prometheus-data volume.
# Thanos sidecar uploads TSDB blocks to S3 and exposes Store API on :10901.
# Prometheus receives remote_write from Tempo metrics generator.
###############################################################################

resource "aws_ecs_task_definition" "prometheus" {
  family                   = "otel-staging-prometheus"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn
  cpu                      = "1024"
  memory                   = "2048"

  volume {
    name      = "prometheus-data"
    host_path = "/data/prometheus"
  }

  container_definitions = jsonencode([
    # ── Container 1: Prometheus ────────────────────────────────────────────────
    {
      name      = "prometheus"
      image     = "${var.ecr_base}/prometheus:${var.image_tag}"
      essential = true
      user      = "root"

      portMappings = [
        { containerPort = 9090, protocol = "tcp" }
      ]

      mountPoints = [
        { sourceVolume = "prometheus-data", containerPath = "/prometheus", readOnly = false }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/otel-staging/prometheus"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "prometheus"
          "awslogs-create-group"  = "true"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:9090/-/ready || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 5
        startPeriod = 60
      }
    },

    # ── Container 2: Thanos Sidecar ────────────────────────────────────────────
    # essential=false — task stays alive if sidecar crashes
    {
      name      = "thanos-sidecar"
      image     = "${var.ecr_base}/thanos:${var.image_tag}"
      essential = false

      command = [
        "sidecar",
        "--tsdb.path=/prometheus",
        "--prometheus.url=http://localhost:9090",
        "--grpc-address=0.0.0.0:10901",
        "--http-address=0.0.0.0:10902",
        "--objstore.config-file=/etc/thanos/bucket.yml",
      ]

      portMappings = [
        { containerPort = 10901, protocol = "tcp" },
        { containerPort = 10902, protocol = "tcp" },
      ]

      mountPoints = [
        { sourceVolume = "prometheus-data", containerPath = "/prometheus", readOnly = true }
      ]

      environment = [
        { name = "S3_BUCKET",  value = var.s3_bucket  },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      # Wait for prometheus to pass its health check
      dependsOn = [
        { containerName = "prometheus", condition = "HEALTHY" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/otel-staging/thanos-sidecar"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "thanos-sidecar"
          "awslogs-create-group"  = "true"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:10902/-/ready || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 5
        startPeriod = 90
      }
    }
  ])

  depends_on = [aws_cloudwatch_log_group.otel_staging]
}

resource "aws_ecs_service" "prometheus" {
  name            = "otel-staging-prometheus"
  cluster         = data.aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets          = [var.subnet_id]
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services["prometheus"].arn
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.prometheus.arn
    container_name   = "prometheus"
    container_port   = 9090
  }

  scheduling_strategy                = "REPLICA"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_lb_listener.prometheus_direct,
  ]
}
