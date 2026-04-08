#!/usr/bin/env bash
###############################################################################
# 05-validate.sh — Verify all ECS services and endpoints are healthy
###############################################################################
set -euo pipefail

REGION="us-east-1"
CLUSTER="otel-sample-apps"
SERVICES=(
  "otel-staging-loki"
  "otel-staging-tempo"
  "otel-staging-prometheus"
  "otel-staging-thanos-query"
  "otel-staging-grafana"
)

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()     { echo -e "${GREEN}[✓]${NC} $*"; }
fail()   { echo -e "${RED}[✗]${NC} $*"; ERRORS=$((ERRORS+1)); }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
info()   { echo -e "${YELLOW}[→]${NC} $*"; }
header() { echo -e "\n${CYAN}── $* ──────────────────────────────────${NC}"; }

ERRORS=0

echo "========================================"
echo " otel-staging Deployment Validation"
echo " Cluster: $CLUSTER"
echo "========================================"

# ── 1. ECS Cluster ────────────────────────────────────────────────────────────
header "1. ECS Cluster"
CLUSTER_STATUS=$(aws ecs describe-clusters \
  --clusters "$CLUSTER" --region "$REGION" \
  --query 'clusters[0].status' --output text 2>/dev/null || echo "MISSING")

if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
  ok "Cluster '$CLUSTER' is ACTIVE"
else
  fail "Cluster '$CLUSTER': $CLUSTER_STATUS"
fi

INSTANCES=$(aws ecs describe-clusters \
  --clusters "$CLUSTER" --region "$REGION" \
  --query 'clusters[0].registeredContainerInstancesCount' --output text 2>/dev/null || echo "0")
info "Registered container instances: $INSTANCES"
[[ "$INSTANCES" -ge 1 ]] && ok "$INSTANCES instance(s) registered" || fail "No instances registered in cluster"

# ── 2. ECS Services ───────────────────────────────────────────────────────────
header "2. ECS Services"
aws ecs describe-services \
  --cluster "$CLUSTER" --region "$REGION" \
  --services "${SERVICES[@]}" \
  --query 'services[*].{Name:serviceName,Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount}' \
  --output table 2>/dev/null || true

for SVC in "${SERVICES[@]}"; do
  DATA=$(aws ecs describe-services \
    --cluster "$CLUSTER" --region "$REGION" \
    --services "$SVC" \
    --query 'services[0].{status:status,desired:desiredCount,running:runningCount}' \
    --output json 2>/dev/null || echo '{}')

  STATUS=$(echo "$DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','MISSING'))" 2>/dev/null || echo "MISSING")
  DESIRED=$(echo "$DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('desired',0))" 2>/dev/null || echo "0")
  RUNNING=$(echo "$DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('running',0))" 2>/dev/null || echo "0")

  if [[ "$STATUS" == "ACTIVE" && "$RUNNING" -ge 1 ]]; then
    ok "$SVC: ACTIVE ($RUNNING/$DESIRED running)"
  elif [[ "$STATUS" == "ACTIVE" && "$RUNNING" -eq 0 ]]; then
    fail "$SVC: ACTIVE but 0/$DESIRED running — check logs"
  else
    fail "$SVC: $STATUS ($RUNNING/$DESIRED)"
  fi
done

# ── 3. ECS Task Health ────────────────────────────────────────────────────────
header "3. Task Health Checks"
for SVC in "${SERVICES[@]}"; do
  TASK_ARN=$(aws ecs list-tasks \
    --cluster "$CLUSTER" --region "$REGION" \
    --service-name "$SVC" \
    --query 'taskArns[0]' --output text 2>/dev/null || echo "")

  if [[ -z "$TASK_ARN" || "$TASK_ARN" == "None" ]]; then
    fail "$SVC: no running task found"
    continue
  fi

  HEALTH=$(aws ecs describe-tasks \
    --cluster "$CLUSTER" --region "$REGION" \
    --tasks "$TASK_ARN" \
    --query 'tasks[0].healthStatus' --output text 2>/dev/null || echo "UNKNOWN")

  # Count recent stopped tasks (indicator of crash loops)
  STOPPED=$(aws ecs list-tasks \
    --cluster "$CLUSTER" --region "$REGION" \
    --service-name "$SVC" \
    --desired-status STOPPED \
    --query 'length(taskArns)' --output text 2>/dev/null || echo "0")

  if [[ "$STOPPED" -gt 5 ]]; then
    warn "$SVC: $STOPPED stopped tasks (possible crash loop) — run: aws logs tail /ecs/otel-staging/${SVC#otel-staging-} --follow"
  fi

  if [[ "$HEALTH" == "HEALTHY" || "$HEALTH" == "UNKNOWN" ]]; then
    ok "$SVC: task health = $HEALTH"
  else
    fail "$SVC: task health = $HEALTH"
  fi
done

# ── 4. ALB ────────────────────────────────────────────────────────────────────
header "4. ALB"
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "otel-staging-alb" --region "$REGION" \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "")

if [[ -n "$ALB_DNS" && "$ALB_DNS" != "None" ]]; then
  ok "ALB DNS: $ALB_DNS"

  # Test Grafana via ALB
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time 10 \
    "http://${ALB_DNS}:3000/api/health" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    ok "Grafana health: HTTP $HTTP_CODE"
    echo "    ✓ Grafana URL: http://${ALB_DNS}:3000  (admin / admin123)"
  else
    warn "Grafana health: HTTP $HTTP_CODE (may still be starting — try again in 60s)"
  fi

  # Test Prometheus via ALB
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time 10 \
    "http://${ALB_DNS}:9090/-/ready" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    ok "Prometheus health: HTTP $HTTP_CODE"
    echo "    ✓ Prometheus URL: http://${ALB_DNS}:9090"
  else
    warn "Prometheus health: HTTP $HTTP_CODE (may still be starting)"
  fi
else
  fail "ALB 'otel-staging-alb' not found"
fi

# ── 5. CloudWatch Log Groups ──────────────────────────────────────────────────
header "5. CloudWatch Log Groups"
LOG_GROUPS=(
  "/ecs/otel-staging/loki"
  "/ecs/otel-staging/tempo"
  "/ecs/otel-staging/prometheus"
  "/ecs/otel-staging/thanos-sidecar"
  "/ecs/otel-staging/thanos-query"
  "/ecs/otel-staging/grafana"
)
for LG in "${LOG_GROUPS[@]}"; do
  EXISTS=$(aws logs describe-log-groups \
    --log-group-name-prefix "$LG" --region "$REGION" \
    --query 'length(logGroups)' --output text 2>/dev/null || echo "0")
  [[ "$EXISTS" -gt 0 ]] && ok "$LG" || fail "$LG not found"
done

# ── 6. S3 Bucket ──────────────────────────────────────────────────────────────
header "6. S3 Bucket"
if aws s3api head-bucket --bucket "otel-staging-observability-store" --region "$REGION" 2>/dev/null; then
  ok "S3 bucket: otel-staging-observability-store"
else
  fail "S3 bucket not found — run scripts/01-setup.sh"
fi

# ── 7. EFS ────────────────────────────────────────────────────────────────────
header "7. EFS"
EFS_COUNT=$(aws efs describe-file-systems \
  --region "$REGION" \
  --query 'length(FileSystems[?Tags[?Key==`Name` && Value==`otel-staging-grafana-efs`]])' \
  --output text 2>/dev/null || echo "0")
[[ "$EFS_COUNT" -gt 0 ]] && ok "EFS otel-staging-grafana-efs found" || fail "EFS not found"

# ── 8. Service Discovery ──────────────────────────────────────────────────────
header "8. Cloud Map"
NS=$(aws servicediscovery list-namespaces \
  --region "$REGION" \
  --filters Name=NAME,Values=observability.local,Condition=EQ \
  --query 'Namespaces[0].Id' --output text 2>/dev/null || echo "")
if [[ -n "$NS" && "$NS" != "None" ]]; then
  ok "Namespace observability.local: $NS"
  SVCS=$(aws servicediscovery list-services \
    --region "$REGION" \
    --filters Name=NAMESPACE_ID,Values="$NS",Condition=EQ \
    --query 'Services[*].Name' --output text 2>/dev/null || echo "")
  info "Registered services: $SVCS"
else
  fail "Cloud Map namespace observability.local not found"
fi

# ── 9. IAM Roles ─────────────────────────────────────────────────────────────
header "9. IAM Roles"
for ROLE in "otel-staging-ecs-execution-role" "otel-staging-ecs-task-role"; do
  aws iam get-role --role-name "$ROLE" > /dev/null 2>&1 \
    && ok "$ROLE" \
    || fail "$ROLE not found"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
if [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${GREEN} All checks passed ✓${NC}"
  if [[ -n "${ALB_DNS:-}" ]]; then
    echo ""
    echo "  Grafana:    http://${ALB_DNS}:3000   (admin / admin123)"
    echo "  Prometheus: http://${ALB_DNS}:9090"
  fi
else
  echo -e "${RED} $ERRORS check(s) FAILED${NC}"
  echo ""
  echo "Troubleshooting commands:"
  echo "  # View logs for a service:"
  echo "  aws logs tail /ecs/otel-staging/loki --follow --region $REGION"
  echo ""
  echo "  # View stopped task reason:"
  echo "  TASK=\$(aws ecs list-tasks --cluster $CLUSTER --service-name otel-staging-loki --desired-status STOPPED --query 'taskArns[0]' --output text)"
  echo "  aws ecs describe-tasks --cluster $CLUSTER --tasks \$TASK --query 'tasks[0].stoppedReason'"
fi
echo "========================================"
exit "$ERRORS"
