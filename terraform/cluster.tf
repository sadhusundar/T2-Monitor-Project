###############################################################################
# cluster.tf — Reference EXISTING cluster + ASG (do NOT recreate)
# Cluster: otel-OS-observability
# ASG:     otel-opensource-asg
###############################################################################

# Reference the existing ECS cluster by name
data "aws_ecs_cluster" "main" {
  cluster_name = var.ecs_cluster_name
}

# Reference the existing ASG so we can attach a capacity provider
data "aws_autoscaling_group" "ecs" {
  name = var.asg_name
}

# ── Capacity Provider — attach existing ASG to cluster ────────────────────────
# Creates a capacity provider if one doesn't already exist for this ASG.
resource "aws_ecs_capacity_provider" "ec2" {
  name = "otel-staging-ec2-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = data.aws_autoscaling_group.ecs.arn
    managed_termination_protection = "DISABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 2
    }
  }

  tags = { Project = "otel-staging" }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = data.aws_ecs_cluster.main.cluster_name
  capacity_providers = [aws_ecs_capacity_provider.ec2.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 1
    base              = 1
  }
}
