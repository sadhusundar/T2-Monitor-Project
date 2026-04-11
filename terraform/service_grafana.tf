###############################################################################
# service_grafana.tf — Grafana with EFS for dashboard persistence
# Datasources are pre-provisioned via the baked-in datasources.yml
# EFS access point scoped to /grafana with UID/GID 472 (grafana user)
###############################################################################

resource "aws_ecs_task_definition" "grafana" {
  family                   = "otel-staging-grafana"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn
  cpu                      = "512"
  memory                   = "512"

  # EFS volume for Grafana data (dashboards, plugins, SQLite DB)
  volume {
    name = "grafana-efs"

    efs_volume_configuration {
      file_system_id          = aws_efs_file_system.grafana.id
      root_directory          = "/"
      transit_encryption      = "ENABLED"
      transit_encryption_port = 20049

      authorization_config {
        access_point_id = aws_efs_access_point.grafana.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "grafana"
      image     = "${var.ecr_base}/grafana:${var.image_tag}"
      essential = true
      user      = "root"

      portMappings = [
        { containerPort = 3000, protocol = "tcp" }
      ]

      mountPoints = [
        { sourceVolume = "grafana-efs", containerPath = "/var/lib/grafana", readOnly = false }
      ]

      environment = [
        { name = "GF_SECURITY_ADMIN_USER",                    value = "admin"    },
        { name = "GF_SECURITY_ADMIN_PASSWORD",                value = "admin123" },
        { name = "GF_AUTH_ANONYMOUS_ENABLED",                 value = "false"    },
        { name = "GF_SERVER_ROOT_URL",                        value = "http://grafana.observability.local:3000" },
        { name = "GF_FEATURE_TOGGLES_ENABLE",                 value = "traceqlEditor" },
        { name = "GF_UPDATES_CHECK_FOR_UPDATES",              value = "false"    },
        { name = "GF_ANALYTICS_CHECK_FOR_UPDATES",            value = "false"    },
        { name = "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES",     value = "false"    },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/otel-staging/grafana"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "grafana"
          "awslogs-create-group"  = "true"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 120
      }
    }
  ])

  depends_on = [
    aws_cloudwatch_log_group.otel_staging,
    aws_efs_mount_target.grafana,
  ]
}

resource "aws_ecs_service" "grafana" {
  name            = "otel-staging-grafana"
  cluster         = data.aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = 1
  launch_type     = "EC2"

  health_check_grace_period_seconds  = 300

  network_configuration {
    subnets          = [var.subnet_id]
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services["grafana"].arn
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.grafana.arn
    container_name   = "grafana"
    container_port   = 3000
  }

  scheduling_strategy                = "REPLICA"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_ecs_service.loki,
    aws_ecs_service.tempo,
    aws_ecs_service.thanos_query,
    aws_ecs_cluster_capacity_providers.main,
    aws_lb_listener.grafana_direct,
    aws_efs_mount_target.grafana,
  ]
}

#needed