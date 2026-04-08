#!/usr/bin/env bash
###############################################################################
# 06-teardown.sh — Remove all otel-staging resources (DESTRUCTIVE)
# Does NOT touch the existing cluster, ASG, VPC, subnet, or security group.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"
REGION="us-east-1"
CLUSTER="otel-sample-apps"

RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo ""
echo -e "${RED}⚠ WARNING: This will DELETE all otel-staging resources:${NC}"
echo "  - ECS services and task definitions"
echo "  - ALB, target groups, listeners"
echo "  - EFS filesystem (Grafana dashboards will be lost)"
echo "  - IAM roles otel-staging-ecs-*"
echo "  - CloudWatch log groups /ecs/otel-staging/*"
echo "  - Cloud Map namespace observability.local"
echo "  - SG rules added to sg-07d2a5d42ac97171c"
echo ""
echo "  NOT deleted: ECS cluster, ASG, VPC, subnet, SG itself, S3 bucket, ECR images"
echo ""
read -rp "Type 'yes' to confirm: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

cd "$TF_DIR"

# Scale down services first so tasks drain cleanly
echo ""
echo "Scaling down ECS services..."
for SVC in otel-staging-grafana otel-staging-thanos-query otel-staging-prometheus otel-staging-tempo otel-staging-loki; do
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SVC" \
    --desired-count 0 \
    --region "$REGION" > /dev/null 2>&1 && echo "  Scaled down $SVC" || echo "  $SVC not found (skipping)"
done

echo "Waiting 30s for tasks to stop..."
sleep 30

terraform destroy -auto-approve

echo ""
echo "Teardown complete."
echo "S3 bucket and ECR images were NOT deleted."
echo "To clean those up manually:"
echo "  aws s3 rb s3://otel-staging-observability-store --force"
echo "  for img in loki tempo prometheus thanos grafana; do aws ecr delete-repository --repository-name otel-staging/\$img --force --region $REGION; done"
