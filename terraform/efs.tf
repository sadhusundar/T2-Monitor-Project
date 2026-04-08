###############################################################################
# efs.tf — EFS filesystem for Grafana dashboard persistence
# Created new (unique name), mounted into the existing subnet/SG
###############################################################################

resource "aws_efs_file_system" "grafana" {
  creation_token   = "otel-staging-grafana-efs"
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = true

  tags = {
    Name    = "otel-staging-grafana-efs"
    Project = "otel-staging"
  }
}

# Mount target in the existing subnet (us-east-1a)
resource "aws_efs_mount_target" "grafana" {
  file_system_id  = aws_efs_file_system.grafana.id
  subnet_id       = var.subnet_id
  security_groups = [var.security_group_id]
}

# EFS Access Point — scoped to /grafana directory with correct UID
resource "aws_efs_access_point" "grafana" {
  file_system_id = aws_efs_file_system.grafana.id

  root_directory {
    path = "/grafana"
    creation_info {
      owner_gid   = 472   # grafana GID inside the container
      owner_uid   = 472   # grafana UID inside the container
      permissions = "755"
    }
  }

  posix_user {
    gid = 472
    uid = 472
  }

  tags = {
    Name    = "otel-staging-grafana-ap"
    Project = "otel-staging"
  }
}
