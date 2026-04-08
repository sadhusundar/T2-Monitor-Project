###############################################################################
# cloudwatch.tf — Pre-create CloudWatch log groups
# Avoids "log group doesn't exist" errors at container startup
# Alloy and node-exporter log groups removed
###############################################################################

locals {
  log_groups = [
    "/ecs/otel-staging/prometheus",
    "/ecs/otel-staging/thanos-sidecar",
    "/ecs/otel-staging/thanos-query",
    "/ecs/otel-staging/loki",
    "/ecs/otel-staging/tempo",
    "/ecs/otel-staging/grafana",
  ]
}

resource "aws_cloudwatch_log_group" "otel_staging" {
  for_each          = toset(local.log_groups)
  name              = each.value
  retention_in_days = 14   # short retention for testing

  tags = { Project = "otel-staging" }

  lifecycle {
    ignore_changes = all   # if awslogs-create-group already created it
  }
}
