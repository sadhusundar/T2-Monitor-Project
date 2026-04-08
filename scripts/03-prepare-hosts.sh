#!/usr/bin/env bash
###############################################################################
# 03-prepare-hosts.sh — Prepare host directories on all ECS EC2 instances
#
# ECS tasks use host-mounted paths for Prometheus, Loki, Tempo data.
# These directories must exist with correct permissions before tasks start.
# Run via SSM so you don't need SSH access.
###############################################################################
set -euo pipefail

REGION="us-east-1"
CLUSTER="otel-sample-apps"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${YELLOW}[→]${NC} $*"; }

info "Fetching EC2 instance IDs from ECS cluster: $CLUSTER"

# Get all container instance ARNs
INSTANCE_ARNS=$(aws ecs list-container-instances \
  --cluster "$CLUSTER" \
  --region "$REGION" \
  --query 'containerInstanceArns[]' \
  --output text)

if [[ -z "$INSTANCE_ARNS" ]]; then
  echo "No container instances found in cluster $CLUSTER"
  exit 1
fi

# Get EC2 instance IDs
EC2_IDS=$(aws ecs describe-container-instances \
  --cluster "$CLUSTER" \
  --container-instances $INSTANCE_ARNS \
  --region "$REGION" \
  --query 'containerInstances[*].ec2InstanceId' \
  --output text)

info "Found instances: $EC2_IDS"

# SSM command to prepare directories on each instance
SSM_COMMAND='
#!/bin/bash
set -e
# Data directories for ECS task host mounts
mkdir -p /data/prometheus /data/loki /data/tempo
chmod 777 /data/prometheus /data/loki /data/tempo

# Loki subdirectories (WAL, index, cache, compactor, rules)
mkdir -p /data/loki/wal /data/loki/index /data/loki/cache /data/loki/compactor /data/loki/rules /data/loki/rules-temp
chmod -R 777 /data/loki

# Tempo subdirectories (WAL, generator WAL)
mkdir -p /data/tempo/wal /data/tempo/generator
chmod -R 777 /data/tempo

echo "Host directories ready"
ls -la /data/
'

for INSTANCE_ID in $EC2_IDS; do
  info "Preparing instance: $INSTANCE_ID"
  CMD_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=['${SSM_COMMAND}']" \
    --region "$REGION" \
    --query 'Command.CommandId' \
    --output text)

  info "Waiting for command to complete on $INSTANCE_ID..."
  aws ssm wait command-executed \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" 2>/dev/null || sleep 10

  OUTPUT=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null || echo "Could not get output")

  ok "Instance $INSTANCE_ID prepared"
  echo "$OUTPUT"
done

ok "All instances prepared"
