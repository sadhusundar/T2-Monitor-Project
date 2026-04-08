###############################################################################
# terraform.tfvars
# ⚠ EDIT: set efs_filesystem_id after running scripts/01-setup.sh
###############################################################################

aws_region  = "us-east-1"
account_id  = "584554046133"

# Existing — do NOT change
ecs_cluster_name  = "otel-OS-observability"
asg_name          = "otel-opensource-asg"
security_group_id = "sg-066a98cb67cf37cd3"
vpc_id            = "vpc-0018aa4902fa67a2c"
subnet_id         = "subnet-0548c87344ac6f8a2"

# ALB public subnets (for browser access to Grafana/Prometheus)
public_subnet_ids = [
  "subnet-04d2a16e59711c474",
  "subnet-0d062118b30606dce"
  # Add a second public subnet here if you have one for high availability
]

# New resources
s3_bucket = "otel-staging-observability-store"
ecr_base  = "584554046133.dkr.ecr.us-east-1.amazonaws.com/otel-staging"
image_tag = "latest"

# ⚠ REQUIRED: fill this after running scripts/01-setup.sh
efs_filesystem_id = "fs-07f6fd4f80dc0c8fd"

# OTel Gateway (other team — don't change)
otel_gateway_grpc = "otel-gateway-nlb-3b88104205cc8ef6.elb.us-east-1.amazonaws.com:4317"
otel_gateway_http = "http://otel-gateway-nlb-3b88104205cc8ef6.elb.us-east-1.amazonaws.com:4318"
