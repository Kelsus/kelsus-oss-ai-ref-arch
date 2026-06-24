# ---------------------------------------------------------------------------
# Security baseline — the account/region-level detective controls a SOC2 audit
# expects. These are account singletons (one CloudTrail, one Config recorder,
# one GuardDuty detector, one Security Hub per region), so they live in their own
# root (envs/account-baseline) and persist independent of any cluster's lifecycle
# — a `terraform destroy` of a benchmark cluster must never delete the audit
# trail. Per-VPC flow logs are cluster-scoped and live in the refarch-stack VPC.
#
#   CloudTrail      — immutable API audit log (CC7)         -> S3 + CloudWatch
#   GuardDuty       — threat detection (CC7)
#   AWS Config      — resource inventory + baseline rules (CC4/CC7)
#   Security Hub    — posture scoring vs. AWS FSBP (CC4/CC7)
#
# Encryption at rest is SSE-S3 on the audit bucket (sufficient for "logs
# encrypted at rest"); swap to SSE-KMS if a CMK is required — see README.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  partition   = data.aws_partition.current.partition
  bucket_name = "${var.name_prefix}-audit-logs-${var.env}-${local.account_id}"
  bucket_arn  = "arn:${local.partition}:s3:::${local.bucket_name}"
  tags        = merge({ Component = "security-baseline" }, var.tags)

  create_bucket = var.enable_cloudtrail || var.enable_config # bucket only needed for trail/Config delivery
}

# ---------------------------------------------------------------------------
# Audit log bucket — receives CloudTrail and AWS Config deliveries
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "audit" {
  count  = local.create_bucket ? 1 : 0
  bucket = local.bucket_name
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "audit" {
  count                   = local.create_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.audit[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "audit" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.audit[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.audit[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.audit[0].id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    expiration { days = 730 } # keep 2y of raw logs; CloudWatch holds the hot copy
  }
}

# CloudTrail and Config write to the bucket via their service principals.
resource "aws_s3_bucket_policy" "audit" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.audit[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = local.bucket_arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${local.bucket_arn}/AWSLogs/${local.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
      {
        Sid       = "AWSConfigAclCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = local.bucket_arn
      },
      {
        Sid       = "AWSConfigWrite"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${local.bucket_arn}/AWSLogs/${local.account_id}/Config/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# CloudTrail — multi-region, log-file validation on, mirrored to CloudWatch
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "trail" {
  count             = var.enable_cloudtrail ? 1 : 0
  name              = "/aws/cloudtrail/${var.name_prefix}-${var.env}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_iam_role" "trail_cwl" {
  count = var.enable_cloudtrail ? 1 : 0
  name  = "${var.name_prefix}-${var.env}-cloudtrail-cwl"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "trail_cwl" {
  count = var.enable_cloudtrail ? 1 : 0
  name  = "deliver-to-cloudwatch"
  role  = aws_iam_role.trail_cwl[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.trail[0].arn}:*"
    }]
  })
}

resource "aws_cloudtrail" "main" {
  count                         = var.enable_cloudtrail ? 1 : 0
  name                          = "${var.name_prefix}-${var.env}"
  s3_bucket_name                = aws_s3_bucket.audit[0].id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.trail[0].arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.trail_cwl[0].arn

  tags       = local.tags
  depends_on = [aws_s3_bucket_policy.audit]
}

# ---------------------------------------------------------------------------
# GuardDuty
# ---------------------------------------------------------------------------
resource "aws_guardduty_detector" "this" {
  count                        = var.enable_guardduty ? 1 : 0
  enable                       = true
  finding_publishing_frequency = "SIX_HOURS"
  tags                         = local.tags
}

# ---------------------------------------------------------------------------
# AWS Config — recorder + delivery + a small baseline of managed rules
# ---------------------------------------------------------------------------
resource "aws_iam_role" "config" {
  count = var.enable_config ? 1 : 0
  name  = "${var.name_prefix}-${var.env}-config"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  count      = var.enable_config ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  count = var.enable_config ? 1 : 0
  name  = "deliver-to-s3"
  role  = aws_iam_role.config[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "s3:PutObject"
        Resource  = "${local.bucket_arn}/AWSLogs/${local.account_id}/Config/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetBucketAcl"
        Resource = local.bucket_arn
      }
    ]
  })
}

resource "aws_config_configuration_recorder" "this" {
  count    = var.enable_config ? 1 : 0
  name     = "${var.name_prefix}-${var.env}"
  role_arn = aws_iam_role.config[0].arn
  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  count          = var.enable_config ? 1 : 0
  name           = "${var.name_prefix}-${var.env}"
  s3_bucket_name = aws_s3_bucket.audit[0].id
  depends_on     = [aws_config_configuration_recorder.this, aws_s3_bucket_policy.audit]
}

resource "aws_config_configuration_recorder_status" "this" {
  count      = var.enable_config ? 1 : 0
  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

# A starter set of managed rules mapped to common CC6/CC7 checks. Extend freely.
locals {
  config_rules = var.enable_config ? {
    s3-public-read-prohibited = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
    encrypted-volumes         = "ENCRYPTED_VOLUMES"
    iam-user-mfa-enabled      = "IAM_USER_MFA_ENABLED"
    cloudtrail-enabled        = "CLOUD_TRAIL_ENABLED"
    incoming-ssh-disabled     = "INCOMING_SSH_DISABLED"
  } : {}
}

resource "aws_config_config_rule" "managed" {
  for_each = local.config_rules
  name     = each.key
  source {
    owner             = "AWS"
    source_identifier = each.value
  }
  depends_on = [aws_config_configuration_recorder_status.this]
}

# ---------------------------------------------------------------------------
# Security Hub — account enablement + AWS Foundational Security Best Practices.
# Add CIS / PCI standards by appending standards_subscription resources.
# ---------------------------------------------------------------------------
resource "aws_securityhub_account" "this" {
  count                    = var.enable_securityhub ? 1 : 0
  enable_default_standards = false # FSBP is subscribed explicitly below
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  count         = var.enable_securityhub ? 1 : 0
  standards_arn = "arn:${local.partition}:securityhub:${local.region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.this]
}
