# otel-staging — Observability Stack on AWS ECS

Prometheus · Thanos · Loki · Tempo · Grafana  
Deployed on existing ECS cluster `otel-sample-apps` using EC2 launch type.

---

## What Changed From the Original

| Component | Status | Reason |
|-----------|--------|--------|
| **Alloy** | ❌ Removed | OTel Gateway (other team) pushes OTLP directly to Tempo/Loki/Prometheus |
| **Node Exporter** | ❌ Removed | OTel Gateway handles host metrics collection |
| `prometheus.yml` | ✏️ Updated | Removed alloy/node-exporter scrape jobs; DNS names updated to ECS service discovery format |
| `grafana/provisioning/datasources.yml` | ✏️ Updated | URLs changed from Docker Compose names (`http://loki:3100`) to ECS Cloud Map DNS (`http://loki.observability.local:3100`) |
| `tempo/tempo.yml` | ✏️ Updated | Replaced hardcoded bucket name and account ID with `${S3_BUCKET}` / `${AWS_REGION}` env vars |
| All other Dockerfiles & configs | ✅ Unchanged | Kept exactly as they were |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Other Team                                                  │
│  Java / Node.js / Python / Go  →  OTel agents (OTLP)       │
│                    ↓                                         │
│  OTel Collector Gateway NLB                                  │
│  gRPC: :4317   HTTP: :4318                                  │
└──────────────────────┬──────────────────────────────────────┘
                       │ OTLP traces/logs/metrics
                       ↓
┌─────────────────────────────────────────────────────────────┐
│  VPC: vpc-0018aa4902fa67a2c                                  │
│  Subnet: subnet-0548c87344ac6f8a2  (us-east-1a)             │
│  ECS Cluster: otel-sample-apps                               │
│  EC2 instances: i-0c09824da8b1c165f, i-0f146b4d8449d639d,  │
│                 i-0ffd2ea7e79dc6174                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  ECS Tasks (awsvpc mode, DNS via observability.local) │   │
│  │                                                        │   │
│  │  Loki  :3100/:9095      ← logs from gateway           │   │
│  │  Tempo :3200/:4317/:4318 ← traces from gateway        │   │
│  │  Prometheus :9090        ← metrics (remote_write)     │   │
│  │    └─ Thanos Sidecar :10901/:10902                    │   │
│  │  Thanos Query :10902     ← long-term metrics          │   │
│  │  Grafana :3000           ← dashboards (EFS)           │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ALB: otel-staging-alb                                       │
│    :3000 → Grafana     :9090 → Prometheus                   │
│                                                              │
│  S3: otel-staging-observability-store                        │
│    loki/90d  tempo/14d  thanos/1yr                           │
│                                                              │
│  EFS: otel-staging-grafana-efs  → Grafana /var/lib/grafana  │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow (New Plan — No Alloy/Node Exporter)

```
OTel Gateway ──OTLP gRPC──► Tempo      (traces  → S3)
             ──OTLP HTTP──► Loki       (logs    → S3)
             ──remote_write► Prometheus (metrics → TSDB → S3 via Thanos)

Tempo metrics_generator ──remote_write──► Prometheus

Grafana reads from:
  Prometheus  (current metrics)
  Thanos Query (long-term metrics via Thanos sidecar → S3)
  Loki        (logs)
  Tempo       (traces)
```

---

## Prerequisites

| Tool | Min Version | Check |
|------|-------------|-------|
| AWS CLI | v2 | `aws --version` |
| Terraform | ≥ 1.5 | `terraform version` |
| Docker | any recent | `docker info` |
| AWS credentials | AdministratorAccess recommended | `aws sts get-caller-identity` |

---

## Execution Order — Step by Step

### Step 0 — Clone / extract and verify AWS access

```bash
cd otel-staging

# Confirm you are in the right account
aws sts get-caller-identity
# Expected: Account = 584554046133
```

---

### Step 1 — Create S3 bucket, ECR repos, EFS

```bash
./scripts/01-setup.sh
```

**What it creates:**
- S3 bucket `otel-staging-observability-store` with lifecycle rules (loki 90d, tempo 14d, thanos 1yr)
- ECR repositories: `otel-staging/loki`, `otel-staging/tempo`, `otel-staging/prometheus`, `otel-staging/thanos`, `otel-staging/grafana`
- EFS filesystem `otel-staging-grafana-efs` with mount target

**⚠️ Manual step after this script:**  
Copy the printed EFS ID into `terraform/terraform.tfvars`:

```hcl
efs_filesystem_id = "fs-xxxxxxxxxxxxxxxxx"   # ← paste here
```

---

### Step 2 — Build and push Docker images

```bash
./scripts/02-build-push.sh
```

**What it builds** (from `./docker/` directory):

| Image | Source | Notes |
|-------|--------|-------|
| `otel-staging/loki:latest` | `docker/loki/` | Unchanged from original |
| `otel-staging/tempo:latest` | `docker/tempo/` | Unchanged Dockerfile; tempo.yml uses env vars |
| `otel-staging/prometheus:latest` | `docker/prometheus/` | Updated prometheus.yml (no alloy/node-exporter) |
| `otel-staging/thanos:latest` | upstream `quay.io/thanos/thanos:v0.35.1` | Retagged and pushed |
| `otel-staging/grafana:latest` | `docker/grafana/` | Updated datasources.yml (ECS DNS names) |

**Alloy and Node Exporter are NOT built** — removed entirely.

Run from the project root (`otel-staging/`), not from inside `scripts/`.

---

### Step 3 — Prepare EC2 host directories

```bash
./scripts/03-prepare-hosts.sh
```

Creates `/data/loki`, `/data/tempo`, `/data/prometheus` on all 3 EC2 instances via SSM.  
These are needed because ECS task definitions use host-mounted volumes for WAL and data persistence.

**Requires:** SSM agent running on the EC2 instances (installed by default on Amazon Linux 2 ECS AMI).

---

### Step 4 — Deploy infrastructure with Terraform

```bash
./scripts/04-terraform-deploy.sh
```

The script runs pre-flight checks, then applies in three phases:

| Phase | Resources |
|-------|-----------|
| 1 — Foundation | IAM roles, SG rules, EFS access point, CloudWatch log groups, Cloud Map |
| 2 — Platform | ECS capacity provider, ALB, target groups, listeners |
| 3 — Services | Loki → Tempo → Prometheus+Thanos → Thanos Query → Grafana |

**Interactive:** You will be asked to confirm before each apply.

---

### Step 5 — Validate

```bash
./scripts/05-validate.sh
```

Checks: ECS cluster, all 5 services running, ALB health, CloudWatch logs, S3, EFS, Cloud Map, IAM roles.

On success it prints:
```
  Grafana:    http://<alb-dns>:3000   (admin / admin123)
  Prometheus: http://<alb-dns>:9090
```

---

## Where to Update Values

| File | What to update | When |
|------|---------------|------|
| `terraform/terraform.tfvars` | `efs_filesystem_id` | After Step 1 |
| `docker/grafana/provisioning/datasources.yml` | Already updated — no action needed | — |
| `docker/prometheus/prometheus.yml` | Add extra scrape targets if needed | Optional |
| `docker/tempo/tempo.yml` | `${S3_BUCKET}` / `${AWS_REGION}` come from ECS env vars — no edit needed | — |
| `terraform/service_grafana.tf` | `GF_SECURITY_ADMIN_PASSWORD` — change `admin123` | Before deploy |

---

## Resource Naming

All new resources follow the `otel-staging-` prefix:

| Resource | Name |
|----------|------|
| S3 bucket | `otel-staging-observability-store` |
| ECR repos | `otel-staging/loki`, `otel-staging/tempo`, `otel-staging/prometheus`, `otel-staging/thanos`, `otel-staging/grafana` |
| EFS | `otel-staging-grafana-efs` |
| ECS execution role | `otel-staging-ecs-execution-role` |
| ECS task role | `otel-staging-ecs-task-role` |
| ECS capacity provider | `otel-staging-ec2-cp` |
| ALB | `otel-staging-alb` |
| Target groups | `otel-staging-grafana-tg`, `otel-staging-prometheus-tg` |
| CloudWatch log groups | `/ecs/otel-staging/{loki,tempo,prometheus,thanos-sidecar,thanos-query,grafana}` |
| Cloud Map namespace | `observability.local` |
| ECS services | `otel-staging-{loki,tempo,prometheus,thanos-query,grafana}` |
| ECS task families | `otel-staging-{loki,tempo,prometheus,thanos-query,grafana}` |

**Existing resources reused (not recreated):**

| Resource | ID/Name |
|----------|---------|
| ECS cluster | `otel-sample-apps` |
| ASG | `otel-opensource-asg` |
| Security group | `sg-07d2a5d42ac97171c` |
| VPC | `vpc-0018aa4902fa67a2c` |
| Subnet | `subnet-0548c87344ac6f8a2` |

---

## Security Group Rules Added

The script adds rules to the **existing** SG `sg-07d2a5d42ac97171c`. No new SG is created.

| Port | Protocol | Purpose |
|------|----------|---------|
| 80 | TCP | ALB HTTP listener |
| 2049 | TCP | EFS NFS mount |
| 3000 | TCP | Grafana UI |
| 3100 | TCP | Loki HTTP push/query |
| 3200 | TCP | Tempo HTTP |
| 4317 | TCP | OTLP gRPC (from OTel Gateway) |
| 4318 | TCP | OTLP HTTP (from OTel Gateway) |
| 9090 | TCP | Prometheus UI + scrape |
| 9095 | TCP | Loki gRPC |
| 10901 | TCP | Thanos gRPC (store API) |
| 10902 | TCP | Thanos HTTP (query + metrics) |

> These are open to `0.0.0.0/0` for testing. Restrict CIDRs for production.

---

## Accessing Grafana and Prometheus

After deployment the ALB DNS name is printed by `terraform output` and `scripts/05-validate.sh`.

```
Grafana:    http://<alb-dns>:3000   Login: admin / admin123
Prometheus: http://<alb-dns>:9090
```

**Pre-configured Grafana datasources** (from `docker/grafana/provisioning/datasources.yml`):
- **Prometheus** → `http://prometheus.observability.local:9090`
- **Loki** → `http://loki.observability.local:3100`
- **Tempo** → `http://tempo.observability.local:3200`
- **Thanos** → `http://thanos-query.observability.local:10902`

---

## Assumptions

1. The three EC2 instances (`i-0c09824da8b1c165f`, `i-0f146b4d8449d639d`, `i-0ffd2ea7e79dc6174`) are already registered with the `otel-sample-apps` cluster. If not, check that the user data on the ASG launch template sets `ECS_CLUSTER=otel-sample-apps` in `/etc/ecs/ecs.config`.

2. The EC2 instances have SSM agent running so `03-prepare-hosts.sh` can create host directories. All Amazon Linux 2 ECS AMIs include SSM by default.

3. The subnet `subnet-0548c87344ac6f8a2` is in us-east-1a. For ALB to work you need at least two subnets in different AZs — if you get an ALB error about subnets, add a second subnet variable and update `alb.tf`.

4. The OTel Gateway NLB (`otel-gateway-nlb-3b88104205cc8ef6.elb.us-east-1.amazonaws.com`) is managed by another team and already running. Tempo listens on `:4317`/`:4318` for OTLP from it. Loki receives logs on `:3100`. Prometheus receives metrics via remote_write.

5. Thanos sidecar runs inside the Prometheus ECS task (same task definition). It uploads TSDB blocks to S3 prefix `thanos/` and exposes the Store gRPC API on `:10901` for Thanos Query.

6. EFS is used only for Grafana `/var/lib/grafana` (dashboards, SQLite DB, plugins). Loki/Tempo/Prometheus use host-mounted paths (`/data/loki`, `/data/tempo`, `/data/prometheus`) for local WAL, backed by S3.

7. This is a **testing/staging** deployment — no HTTPS, passwords are simple, SG rules are open to 0.0.0.0/0. Do not use these settings in production.

---

## Troubleshooting

### Task stops immediately

```bash
# Get the stopped task ARN
TASK=$(aws ecs list-tasks \
  --cluster otel-sample-apps \
  --service-name otel-staging-loki \
  --desired-status STOPPED \
  --query 'taskArns[0]' --output text)

# See why it stopped
aws ecs describe-tasks \
  --cluster otel-sample-apps \
  --tasks $TASK \
  --query 'tasks[0].{StopReason:stoppedReason,Containers:containers[*].{Name:name,Reason:reason,ExitCode:exitCode}}'
```

### View service logs

```bash
aws logs tail /ecs/otel-staging/loki --follow --region us-east-1
aws logs tail /ecs/otel-staging/tempo --follow --region us-east-1
aws logs tail /ecs/otel-staging/prometheus --follow --region us-east-1
aws logs tail /ecs/otel-staging/grafana --follow --region us-east-1
```

### Loki WAL permission error

Loki runs as `user=0` (root) in the task definition to avoid `permission denied` on `/data/loki`. If you see permission errors, re-run `scripts/03-prepare-hosts.sh`.

### Tempo S3 endpoint error

The `tempo.yml` no longer has a hardcoded bucket name. It uses `${S3_BUCKET}` and `${AWS_REGION}` injected as environment variables by the ECS task definition. If Tempo fails to start, check that `var.s3_bucket` in `terraform.tfvars` matches the bucket created by `scripts/01-setup.sh`.

### Grafana can't reach datasources

Grafana datasources use `observability.local` DNS names. These resolve only within the VPC via Cloud Map. If Grafana can reach the ALB but datasources time out, check that Cloud Map service records exist:

```bash
aws servicediscovery list-namespaces \
  --filters Name=NAME,Values=observability.local,Condition=EQ
```

### ALB returns 502

The ALB target groups use `ip` target type (awsvpc mode). ECS registers task IPs automatically when the service starts. A 502 means the task hasn't registered yet — wait ~60 seconds and retry.

### EFS mount fails

If Grafana fails with EFS mount errors, check that:
1. The EFS mount target is in the same subnet as the ECS tasks
2. Port 2049 (NFS) is open in the security group
3. The ECS task role has `elasticfilesystem:ClientMount` permission

---

## Teardown

```bash
./scripts/06-teardown.sh
```

Removes all `otel-staging-*` resources. Does **not** delete the ECS cluster, ASG, VPC, subnet, security group itself, S3 bucket, or ECR images.

---

## Directory Structure

```
otel-staging/
├── README.md
├── docker/
│   ├── grafana/
│   │   ├── Dockerfile                        # unchanged
│   │   └── provisioning/
│   │       └── datasources.yml               # updated: ECS DNS names
│   ├── loki/
│   │   ├── Dockerfile                        # unchanged
│   │   └── loki.yml                          # unchanged
│   ├── prometheus/
│   │   ├── Dockerfile                        # unchanged
│   │   └── prometheus.yml                    # updated: removed alloy/node-exporter
│   ├── tempo/
│   │   ├── Dockerfile                        # unchanged
│   │   └── tempo.yml                         # updated: env vars for bucket/region
│   └── thanos/
│       └── Dockerfile                        # unchanged (upstream image)
├── terraform/
│   ├── main.tf                               # provider config
│   ├── variables.tf                          # all variables
│   ├── terraform.tfvars                      # ← edit efs_filesystem_id after step 1
│   ├── iam.tf                                # otel-staging-ecs-* roles
│   ├── cluster.tf                            # references existing cluster + ASG
│   ├── efs.tf                                # new EFS + mount target + access point
│   ├── cloudwatch.tf                         # log groups /ecs/otel-staging/*
│   ├── sg_rules.tf                           # rules added to existing SG
│   ├── service_discovery.tf                  # Cloud Map observability.local
│   ├── alb.tf                                # ALB + TGs + listeners
│   ├── service_loki.tf
│   ├── service_tempo.tf
│   ├── service_prometheus.tf                 # includes thanos-sidecar container
│   ├── service_thanos_query.tf
│   ├── service_grafana.tf                    # EFS volume mount
│   └── outputs.tf
└── scripts/
    ├── 01-setup.sh          # S3 + ECR repos + EFS   ← run first
    ├── 02-build-push.sh     # docker build + push
    ├── 03-prepare-hosts.sh  # host dirs on EC2s via SSM
    ├── 04-terraform-deploy.sh  # phased terraform apply
    ├── 05-validate.sh       # health checks
    └── 06-teardown.sh       # destroy all otel-staging resources
```
