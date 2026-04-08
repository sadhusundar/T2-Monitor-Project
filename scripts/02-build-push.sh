#!/usr/bin/env bash
###############################################################################
# 02-build-push.sh — Build Docker images and push to ECR
# Alloy and node-exporter are NOT built (removed per requirements)
#
# Run from project root: ./scripts/02-build-push.sh
###############################################################################
set -euo pipefail

REGION="us-east-1"
ACCOUNT_ID="584554046133"
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/otel-staging"
TAG="${IMAGE_TAG:-latest}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "${YELLOW}[→]${NC} $*"; }

# ── ECR Login ─────────────────────────────────────────────────────────────────
info "Logging in to ECR..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ok "ECR login successful"

build_and_push() {
  local NAME=$1
  local CONTEXT="./docker/${NAME}"
  local REMOTE_TAG="${ECR_BASE}/${NAME}:${TAG}"

  echo ""
  info "Building: ${NAME}"
  if docker build --platform linux/amd64 -t "$REMOTE_TAG" "$CONTEXT"; then
    ok "Build OK: $NAME"
  else
    err "Build FAILED: $NAME"
    return 1
  fi

  info "Pushing: $NAME → $REMOTE_TAG"
  if docker push "$REMOTE_TAG"; then
    ok "Push OK: $NAME"
  else
    err "Push FAILED: $NAME"
    return 1
  fi
}

# Thanos uses upstream image — just retag and push
push_thanos() {
  local REMOTE_TAG="${ECR_BASE}/thanos:${TAG}"
  info "Pulling upstream Thanos image..."
  docker pull quay.io/thanos/thanos:v0.35.1
  docker tag quay.io/thanos/thanos:v0.35.1 "$REMOTE_TAG"
  docker push "$REMOTE_TAG"
  ok "Thanos pushed: $REMOTE_TAG"
}

# Build and push all services (alloy and node-exporter excluded)
build_and_push "loki"
build_and_push "tempo"
build_and_push "prometheus"
build_and_push "grafana"
push_thanos

echo ""
echo "============================================================"
ok "All images pushed to ECR"
echo " Base: ${ECR_BASE}"
echo " Images: loki, tempo, prometheus, thanos, grafana"
echo " Tag: ${TAG}"
echo "============================================================"
