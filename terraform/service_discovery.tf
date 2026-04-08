###############################################################################
# service_discovery.tf — AWS Cloud Map private DNS (observability.local)
# Alloy and node-exporter entries removed
###############################################################################

resource "aws_service_discovery_private_dns_namespace" "otel_staging" {
  name        = "observability.local"
  description = "Private DNS for otel-staging ECS services"
  vpc         = var.vpc_id

  tags = { Project = "otel-staging" }
}

locals {
  discovery_services = {
    "prometheus"   = 9090
    "loki"         = 3100
    "tempo"        = 3200
    "thanos-query" = 10902
    "grafana"      = 3000
  }
}

resource "aws_service_discovery_service" "services" {
  for_each = local.discovery_services

  name = each.key

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.otel_staging.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = { Project = "otel-staging" }
}
