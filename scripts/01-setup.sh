#!/usr/bin/env bash
###############################################################################
# 01-setup.sh — Create S3 bucket, EFS filesystem, and ECR repos
# Run this FIRST before building Docker images or running Terraform.
###############################################################################
set -euo pipefail

REGION="us-east-1"
ACCOUNT_ID="584554046133"
BUCKET="otel-staging-observability-store"
ECR_NAMESPACE="otel-staging"
SUBNET_ID="subnet-0548c87344ac6f8a2"
SG_ID="sg-07d2a5d42ac97171c"
VPC_ID="vpc-0018aa4902fa67a2c"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${YELLOW}[→]${NC} $*"; }

# ── S3 Bucket ─────────────────────────────────────────────────────────────────
info "Creating S3 bucket: $BUCKET"
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" 2>/dev/null || echo "  Bucket already exists"

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "loki-retention",
        "Status": "Enabled",
        "Filter": {"Prefix": "loki/"},
        "Expiration": {"Days": 90}
      },
      {
        "ID": "tempo-retention",
        "Status": "Enabled",
        "Filter": {"Prefix": "tempo/"},
        "Expiration": {"Days": 14}
      },
      {
        "ID": "thanos-retention",
        "Status": "Enabled",
        "Filter": {"Prefix": "thanos/"},
        "Expiration": {"Days": 365}
      }
    ]
  }'
ok "S3 bucket ready: $BUCKET"

# ── ECR Repositories (single namespace, sub-image tags) ───────────────────────
info "Creating ECR repositories under $ECR_NAMESPACE/"
IMAGES=("loki" "tempo" "prometheus" "thanos" "grafana")

for IMG in "${IMAGES[@]}"; do
  aws ecr create-repository \
    --repository-name "${ECR_NAMESPACE}/${IMG}" \
    --region "$REGION" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE 2>/dev/null \
    && ok "ECR created: ${ECR_NAMESPACE}/${IMG}" \
    || echo "  ECR already exists: ${ECR_NAMESPACE}/${IMG}"

  # Lifecycle: keep last 5 images
  aws ecr put-lifecycle-policy \
    --repository-name "${ECR_NAMESPACE}/${IMG}" \
    --region "$REGION" \
    --lifecycle-policy-text '{
      "rules": [{
        "rulePriority": 1,
        "description": "Keep last 5 images",
        "selection": {"tagStatus": "any", "countType": "imageCountMoreThan", "countNumber": 5},
        "action": {"type": "expire"}
      }]
    }' > /dev/null
done

# ── EFS Filesystem ────────────────────────────────────────────────────────────
info "Creating EFS filesystem for Grafana dashboards..."
EFS_ID=$(aws efs create-file-system \
  --creation-token "otel-staging-grafana-efs-$(date +%s)" \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --region "$REGION" \
  --tags Key=Name,Value=otel-staging-grafana-efs Key=Project,Value=otel-staging \
  --query 'FileSystemId' \
  --output text)

ok "EFS created: $EFS_ID"

info "Waiting for EFS to become available..."
aws efs wait file-system-available --file-system-id "$EFS_ID" --region "$REGION" 2>/dev/null || sleep 20

info "Creating EFS mount target in subnet $SUBNET_ID..."
aws efs create-mount-target \
  --file-system-id "$EFS_ID" \
  --subnet-id "$SUBNET_ID" \
  --security-groups "$SG_ID" \
  --region "$REGION" 2>/dev/null || echo "  Mount target may already exist"
ok "EFS mount target created"

# ── Output ────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " Setup complete. Copy this value into terraform/terraform.tfvars:"
echo ""
echo "   efs_filesystem_id = \"$EFS_ID\""
echo ""
echo " S3 bucket   : $BUCKET"
echo " ECR base    : ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_NAMESPACE}"
echo "============================================================"
