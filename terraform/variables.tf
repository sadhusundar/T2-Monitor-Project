###############################################################################
# variables.tf — All inputs for otel-staging stack
###############################################################################

variable "aws_region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "account_id" {
  description = "AWS account ID"
  default     = "584554046133"
}

# ── Existing resources — do NOT recreate ─────────────────────────────────────
variable "ecs_cluster_name" {
  description = "Existing ECS cluster name"
  default     = "otel-OS-observability"
}

variable "asg_name" {
  description = "Existing Auto Scaling Group name"
  default     = "otel-opensource-asg"
}

variable "security_group_id" {
  description = "Existing security group — ports will be added to this SG"
  default     = "sg-066a98cb67cf37cd3"
}

variable "vpc_id" {
  description = "Existing VPC ID"
  default     = "vpc-0018aa4902fa67a2c"
}

variable "subnet_id" {
  description = "Existing subnet ID (us-east-1a)"
  default     = "subnet-0548c87344ac6f8a2"
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for ALB"
  type        = list(string)
}

# ── New resources ─────────────────────────────────────────────────────────────
variable "s3_bucket" {
  description = "Globally unique S3 bucket name (no account number)"
  default     = "otel-staging-observability-store"
}

variable "ecr_base" {
  description = "ECR base URI — single repo namespace for all images"
  default     = "584554046133.dkr.ecr.us-east-1.amazonaws.com/otel-staging"
}

variable "image_tag" {
  description = "Docker image tag"
  default     = "latest"
}

variable "efs_filesystem_id" {
  description = "EFS filesystem ID (created by 01-setup.sh or pre-existing)"
  default     = ""   # filled by setup script output
}

# ── OTel Gateway NLB (other team's — used as OTLP source) ─────────────────────
variable "otel_gateway_grpc" {
  description = "OTel Gateway gRPC endpoint (other team)"
  default     = "otel-gateway-nlb-3b88104205cc8ef6.elb.us-east-1.amazonaws.com:4317"
}

variable "otel_gateway_http" {
  description = "OTel Gateway HTTP endpoint (other team)"
  default     = "http://otel-gateway-nlb-3b88104205cc8ef6.elb.us-east-1.amazonaws.com:4318"
}
