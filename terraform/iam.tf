###############################################################################
# iam.tf — IAM Roles for otel-staging
# All names are unique / staging-prefixed so they don't clash with existing roles
###############################################################################

data "aws_iam_policy_document" "ecs_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ── ECS Task Execution Role ────────────────────────────────────────────────────
# Used by ECS agent to pull images from ECR and write CloudWatch logs
resource "aws_iam_role" "execution" {
  name               = "otel-staging-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json

  tags = { Project = "otel-staging" }
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_logs" {
  name = "otel-staging-execution-logs"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ecs/otel-staging/*"
    }]
  })
}

# ── ECS Task Role ──────────────────────────────────────────────────────────────
# Used by running containers (S3 for Loki/Tempo/Thanos, EFS for Grafana)
resource "aws_iam_role" "task" {
  name               = "otel-staging-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json

  tags = { Project = "otel-staging" }
}

resource "aws_iam_role_policy" "task_s3" {
  name = "otel-staging-s3-access"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket}",
          "arn:aws:s3:::${var.s3_bucket}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ecs/otel-staging/*"
      },
      {
        # EFS access for Grafana data persistence
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:ClientRootAccess",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "task_efs" {
  name = "otel-staging-efs-access"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:ClientRootAccess",
          "elasticfilesystem:DescribeMountTargets"
        ]
        Resource = "arn:aws:elasticfilesystem:${var.aws_region}:${data.aws_caller_identity.current.account_id}:file-system/fs-024599e51a908e3d3"
      }
    ]
  })
}