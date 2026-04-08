#!/usr/bin/env bash
###############################################################################
# 04-terraform-deploy.sh — Run Terraform to deploy all AWS infrastructure
#
# Pre-requisites:
#   1. scripts/01-setup.sh  completed  (S3, ECR, EFS created)
#   2. scripts/02-build-push.sh  completed  (images in ECR)
#   3. scripts/03-prepare-hosts.sh  completed  (host dirs on EC2s)
#   4. terraform/terraform.tfvars updated with efs_filesystem_id
#
# What this creates:
#   - IAM roles (otel-staging-ecs-execution-role, otel-staging-ecs-task-role)
#   - Security group rules on existing SG
#   - EFS mount target + access point
#   - CloudWatch log groups
#   - Cloud Map namespace + service discovery records
#   - ECS capacity provider attached to existing ASG
#   - ALB + target groups + listeners (Grafana :3000, Prometheus :9090)
#   - ECS task definitions + services for all 5 components
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()     { echo -e "${GREEN}[✓]${NC} $*"; }
err()    { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info()   { echo -e "${YELLOW}[→]${NC} $*"; }
header() { echo -e "\n${CYAN}══════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════${NC}"; }

cd "$TF_DIR"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
header "Pre-flight Checks"

# Check efs_filesystem_id is filled in
if grep -q 'FILL_AFTER_SETUP' terraform.tfvars; then
  err "terraform.tfvars still has FILL_AFTER_SETUP for efs_filesystem_id.
  Run scripts/01-setup.sh first, then copy the EFS ID into terraform.tfvars"
fi
ok "terraform.tfvars looks configured"

# Check AWS credentials
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "AWS credentials not configured. Run: aws configure"
ok "AWS account: $ACCOUNT"

# Check ECS cluster exists
CLUSTER_STATUS=$(aws ecs describe-clusters \
  --clusters otel-sample-apps \
  --region us-east-1 \
  --query 'clusters[0].status' \
  --output text 2>/dev/null || echo "MISSING")
[[ "$CLUSTER_STATUS" == "ACTIVE" ]] \
  || err "ECS cluster 'otel-sample-apps' not found or not ACTIVE (got: $CLUSTER_STATUS)"
ok "ECS cluster otel-sample-apps is ACTIVE"

# Check ASG exists
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names otel-opensource-asg \
  --region us-east-1 \
  --query 'AutoScalingGroups[0].AutoScalingGroupName' \
  --output text > /dev/null 2>&1 \
  || err "ASG 'otel-opensource-asg' not found"
ok "ASG otel-opensource-asg found"

# Check ECR images exist
info "Checking ECR images..."
for SVC in loki tempo prometheus thanos grafana; do
  COUNT=$(aws ecr describe-images \
    --repository-name "otel-staging/${SVC}" \
    --region us-east-1 \
    --query 'length(imageDetails)' \
    --output text 2>/dev/null || echo "0")
  if [[ "$COUNT" -gt 0 ]]; then
    ok "ECR otel-staging/${SVC}: $COUNT image(s)"
  else
    err "ECR otel-staging/${SVC} has no images. Run scripts/02-build-push.sh first"
  fi
done

# ── Terraform Init ────────────────────────────────────────────────────────────
header "Terraform Init"
terraform init -upgrade
ok "Terraform initialised"

# ── Terraform Validate ────────────────────────────────────────────────────────
header "Terraform Validate"
terraform validate && ok "Configuration valid"

# ── Terraform Plan ────────────────────────────────────────────────────────────
header "Terraform Plan"
terraform plan -out=tfplan.binary
terraform show -no-color tfplan.binary > tfplan.txt
ok "Plan saved to terraform/tfplan.txt — review before continuing"
echo ""
read -rp "Continue with apply? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# ── Phase 1: Foundation (IAM, SG rules, EFS, CloudWatch, Service Discovery) ───
header "Phase 1: Foundation Resources"
terraform apply \
  -target=aws_iam_role.execution \
  -target=aws_iam_role.task \
  -target=aws_iam_role_policy_attachment.execution_managed \
  -target=aws_iam_role_policy.execution_logs \
  -target=aws_iam_role_policy.task_s3 \
  -target=aws_vpc_security_group_ingress_rule.prometheus \
  -target=aws_vpc_security_group_ingress_rule.loki_http \
  -target=aws_vpc_security_group_ingress_rule.loki_grpc \
  -target=aws_vpc_security_group_ingress_rule.tempo_http \
  -target=aws_vpc_security_group_ingress_rule.otlp_grpc \
  -target=aws_vpc_security_group_ingress_rule.otlp_http \
  -target=aws_vpc_security_group_ingress_rule.grafana \
  -target=aws_vpc_security_group_ingress_rule.thanos_grpc \
  -target=aws_vpc_security_group_ingress_rule.thanos_http \
  -target=aws_vpc_security_group_ingress_rule.http_80 \
  -target=aws_vpc_security_group_ingress_rule.efs_nfs \
  -target=aws_vpc_security_group_egress_rule.all_out \
  -target=aws_efs_file_system.grafana \
  -target=aws_efs_mount_target.grafana \
  -target=aws_efs_access_point.grafana \
  -target=aws_cloudwatch_log_group.otel_staging \
  -target=aws_service_discovery_private_dns_namespace.otel_staging \
  -target=aws_service_discovery_service.services \
  -auto-approve
ok "Phase 1 complete"

# ── Phase 2: Capacity Provider + ALB ─────────────────────────────────────────
header "Phase 2: Capacity Provider + ALB"
terraform apply \
  -target=aws_ecs_capacity_provider.ec2 \
  -target=aws_ecs_cluster_capacity_providers.main \
  -target=aws_lb.otel_staging \
  -target=aws_lb_target_group.grafana \
  -target=aws_lb_target_group.prometheus \
  -target=aws_lb_listener.http \
  -target=aws_lb_listener_rule.prometheus \
  -target=aws_lb_listener.grafana_direct \
  -target=aws_lb_listener.prometheus_direct \
  -auto-approve
ok "Phase 2 complete"

info "Waiting 30s for ALB to provision..."
sleep 30

# ── Phase 3: ECS Services (in dependency order) ───────────────────────────────
header "Phase 3: ECS Services"

info "Deploying Loki..."
terraform apply \
  -target=aws_ecs_task_definition.loki \
  -target=aws_ecs_service.loki \
  -auto-approve
ok "Loki deployed"

info "Deploying Tempo..."
terraform apply \
  -target=aws_ecs_task_definition.tempo \
  -target=aws_ecs_service.tempo \
  -auto-approve
ok "Tempo deployed"

info "Deploying Prometheus + Thanos Sidecar..."
terraform apply \
  -target=aws_ecs_task_definition.prometheus \
  -target=aws_ecs_service.prometheus \
  -auto-approve
ok "Prometheus deployed"

info "Deploying Thanos Query..."
terraform apply \
  -target=aws_ecs_task_definition.thanos_query \
  -target=aws_ecs_service.thanos_query \
  -auto-approve
ok "Thanos Query deployed"

info "Deploying Grafana..."
terraform apply \
  -target=aws_ecs_task_definition.grafana \
  -target=aws_ecs_service.grafana \
  -auto-approve
ok "Grafana deployed"

# ── Final full apply (catch any remaining resources) ──────────────────────────
header "Final Apply"
terraform apply -auto-approve
ok "Full apply complete"

# ── Print outputs ─────────────────────────────────────────────────────────────
header "Deployment Complete"
echo ""
terraform output
echo ""
echo "Next: run scripts/05-validate.sh to verify all services are healthy"
