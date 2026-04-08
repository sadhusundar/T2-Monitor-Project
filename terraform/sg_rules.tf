###############################################################################
# sg_rules.tf — Add open-source observability ports to the EXISTING SG
# SG: sg-07d2a5d42ac97171c
# We use aws_vpc_security_group_ingress_rule (not recreating the SG)
###############################################################################

# ── Prometheus ────────────────────────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "prometheus" {
  security_group_id = var.security_group_id
  description       = "Prometheus UI + scrape"
  from_port         = 9090
  to_port           = 9090
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"   # testing — tighten for production
}

# ── Loki ──────────────────────────────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "loki_http" {
  security_group_id = var.security_group_id
  description       = "Loki HTTP push + query"
  from_port         = 3100
  to_port           = 3100
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "loki_grpc" {
  security_group_id = var.security_group_id
  description       = "Loki gRPC"
  from_port         = 9095
  to_port           = 9095
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# ── Tempo ─────────────────────────────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "tempo_http" {
  security_group_id = var.security_group_id
  description       = "Tempo HTTP query"
  from_port         = 3200
  to_port           = 3200
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "otlp_grpc" {
  security_group_id = var.security_group_id
  description       = "OTLP gRPC (Tempo ingestion from OTel Gateway)"
  from_port         = 4317
  to_port           = 4317
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "otlp_http" {
  security_group_id = var.security_group_id
  description       = "OTLP HTTP (Tempo ingestion from OTel Gateway)"
  from_port         = 4318
  to_port           = 4318
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# ── Grafana ───────────────────────────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "grafana" {
  security_group_id = var.security_group_id
  description       = "Grafana UI"
  from_port         = 3000
  to_port           = 3000
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# ── Thanos ────────────────────────────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "thanos_grpc" {
  security_group_id = var.security_group_id
  description       = "Thanos gRPC (sidecar store API)"
  from_port         = 10901
  to_port           = 10901
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "thanos_http" {
  security_group_id = var.security_group_id
  description       = "Thanos HTTP (query UI + sidecar metrics)"
  from_port         = 10902
  to_port           = 10902
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# ── ALB listener ports ────────────────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "http_80" {
  security_group_id = var.security_group_id
  description       = "HTTP for ALB"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# ── EFS (NFS from within VPC only) ────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  security_group_id = var.security_group_id
  description       = "EFS NFS (Grafana data)"
  from_port         = 2049
  to_port           = 2049
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# ── Allow all outbound (keep existing pattern) ────────────────────────────────
resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = var.security_group_id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
