###############################################################################
# outputs.tf — Useful values after terraform apply
###############################################################################

output "ecs_cluster_name" {
  value = data.aws_ecs_cluster.main.cluster_name
}

output "alb_dns_name" {
  description = "ALB DNS — use this to open Grafana and Prometheus in browser"
  value       = aws_lb.otel_staging.dns_name
}

output "grafana_url" {
  value = "http://${aws_lb.otel_staging.dns_name}:3000  (admin / admin123)"
}

output "prometheus_url" {
  value = "http://${aws_lb.otel_staging.dns_name}:9090"
}

output "efs_filesystem_id" {
  description = "EFS ID — copy this into terraform.tfvars efs_filesystem_id"
  value       = aws_efs_file_system.grafana.id
}

output "s3_bucket" {
  value = var.s3_bucket
}

output "ecr_base" {
  value = var.ecr_base
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "service_discovery_namespace" {
  value = aws_service_discovery_private_dns_namespace.otel_staging.name
}

output "verify_services_command" {
  value = <<-CMD
    aws ecs describe-services \
      --cluster ${data.aws_ecs_cluster.main.cluster_name} \
      --services \
        otel-staging-prometheus \
        otel-staging-loki \
        otel-staging-tempo \
        otel-staging-thanos-query \
        otel-staging-grafana \
      --query 'services[*].{Name:serviceName,Running:runningCount,Desired:desiredCount,Status:status}' \
      --output table
  CMD
}
