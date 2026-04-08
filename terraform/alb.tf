###############################################################################
# alb.tf — Application Load Balancer for Grafana + Prometheus web access
#
# Both services sit in the private subnet (no public IP).
# The ALB is internet-facing so you can open a browser directly.
# For testing only — no HTTPS/ACM certificate configured.
###############################################################################

# ── ALB (internet-facing for testing) ────────────────────────────────────────
resource "aws_lb" "otel_staging" {
  name               = "otel-staging-alb"
  internal           = false           # internet-facing for browser access
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets            = var.public_subnet_ids  # add a second subnet if you have one

  enable_deletion_protection = false     # testing — easy to tear down

  tags = {
    Name    = "otel-staging-alb"
    Project = "otel-staging"
  }
}

# ── Target Group: Grafana (port 3000) ─────────────────────────────────────────
resource "aws_lb_target_group" "grafana" {
  name        = "otel-staging-grafana-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"   # required for awsvpc network mode

  health_check {
    enabled             = true
    path                = "/api/health"
    port                = "3000"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
    matcher             = "200"
  }

  tags = {
    Name    = "otel-staging-grafana-tg"
    Project = "otel-staging"
  }
}

# ── Target Group: Prometheus (port 9090) ──────────────────────────────────────
resource "aws_lb_target_group" "prometheus" {
  name        = "otel-staging-prometheus-tg"
  port        = 9090
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/-/ready"
    port                = "9090"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
    matcher             = "200"
  }

  tags = {
    Name    = "otel-staging-prometheus-tg"
    Project = "otel-staging"
  }
}

# ── Listener: port 80 → Grafana (default) ─────────────────────────────────────
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.otel_staging.arn
  port              = 80
  protocol          = "HTTP"

  # Default: forward to Grafana
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# ── Listener rule: /prometheus* → Prometheus (port 80, path-based) ────────────
resource "aws_lb_listener_rule" "prometheus" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.prometheus.arn
  }

  condition {
    path_pattern {
      values = ["/graph*", "/metrics*", "/-/ready*", "/api/v1/*"]
    }
  }
}

# ── Listener: port 3000 → Grafana directly (convenience) ─────────────────────
resource "aws_lb_listener" "grafana_direct" {
  load_balancer_arn = aws_lb.otel_staging.arn
  port              = 3000
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# ── Listener: port 9090 → Prometheus directly ─────────────────────────────────
resource "aws_lb_listener" "prometheus_direct" {
  load_balancer_arn = aws_lb.otel_staging.arn
  port              = 9090
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.prometheus.arn
  }
}
