# ==============================================================================
# modules/storage/main.tf
#
# Responsibility: Raw ingestion bucket, processed output bucket, and
# DynamoDB metadata table with Streams enabled.
#
# This module is intentionally AGNOSTIC of SNS, SQS, and Lambda.
# The aws_s3_bucket_notification resource lives OUTSIDE this module
# (in the messaging module or dev/main.tf) to preserve the
# unidirectional DAG and avoid circular dependencies.
# ==============================================================================

locals {
  # Canonical prefix used across every resource name
  name_prefix = "${var.project}-${var.environment}"

  # Merged tags applied to every resource in this module
  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
      Module      = "storage"
    },
    var.additional_tags
  )
}

# ==============================================================================
# S3 — Raw Ingestion Bucket
# ==============================================================================

resource "aws_s3_bucket" "raw" {
  bucket        = "${local.name_prefix}-${var.raw_bucket_suffix}"
  force_destroy = var.raw_bucket_force_destroy

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-${var.raw_bucket_suffix}" })
}

# Block ALL public access — videos are private assets
resource "aws_s3_bucket_public_access_block" "raw" {
  bucket = aws_s3_bucket.raw.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enforce AES-256 server-side encryption at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Enable versioning so overwrites are recoverable
resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Lifecycle: expire non-current versions quickly in dev; current objects after N days
resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  # Lifecycle config requires versioning to be enabled first
  depends_on = [aws_s3_bucket_versioning.raw]

  bucket = aws_s3_bucket.raw.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  dynamic "rule" {
    for_each = var.raw_bucket_lifecycle_expiration_days > 0 ? [1] : []
    content {
      id     = "expire-current-objects"
      status = "Enabled"

      filter {}

      expiration {
        days = var.raw_bucket_lifecycle_expiration_days
      }
    }
  }
}

# ==============================================================================
# S3 — Processed Output Bucket
# ==============================================================================

resource "aws_s3_bucket" "processed" {
  bucket        = "${local.name_prefix}-${var.processed_bucket_suffix}"
  force_destroy = var.processed_bucket_force_destroy

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-${var.processed_bucket_suffix}" })
}

resource "aws_s3_bucket_public_access_block" "processed" {
  bucket = aws_s3_bucket.processed.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "processed" {
  bucket = aws_s3_bucket.processed.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "processed" {
  depends_on = [aws_s3_bucket_versioning.processed]

  bucket = aws_s3_bucket.processed.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 60
    }
  }

  dynamic "rule" {
    for_each = var.processed_bucket_lifecycle_expiration_days > 0 ? [1] : []
    content {
      id     = "expire-current-objects"
      status = "Enabled"

      filter {}

      expiration {
        days = var.processed_bucket_lifecycle_expiration_days
      }
    }
  }
}

# ==============================================================================
# DynamoDB — Video Metadata Table
#
# Streams are enabled with NEW_AND_OLD_IMAGES so the Notification Lambda
# can compare before/after state on every write.
# ==============================================================================

resource "aws_dynamodb_table" "video_metadata" {
  name         = "${local.name_prefix}-${var.dynamodb_table_suffix}"
  billing_mode = var.dynamodb_billing_mode

  # Conditionally set capacity units — only valid for PROVISIONED mode
  read_capacity  = var.dynamodb_billing_mode == "PROVISIONED" ? var.dynamodb_read_capacity : null
  write_capacity = var.dynamodb_billing_mode == "PROVISIONED" ? var.dynamodb_write_capacity : null

  # Primary Key — video_id partitions data; uploaded_at enables range queries
  hash_key  = "video_id"
  range_key = "uploaded_at"

  attribute {
    name = "video_id"
    type = "S"
  }

  attribute {
    name = "uploaded_at"
    type = "S"
  }

  # GSI: query all videos by processing status (e.g. "PENDING", "DONE", "FAILED")
  global_secondary_index {
    name            = "StatusIndex"
    hash_key        = "processing_status"
    range_key       = "uploaded_at"
    projection_type = "ALL"

    # Required only for PROVISIONED; ignored for PAY_PER_REQUEST
    read_capacity  = var.dynamodb_billing_mode == "PROVISIONED" ? var.dynamodb_read_capacity : null
    write_capacity = var.dynamodb_billing_mode == "PROVISIONED" ? var.dynamodb_write_capacity : null
  }

  attribute {
    name = "processing_status"
    type = "S"
  }

  # DynamoDB Streams — delivers both old and new item images to the trigger Lambda
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  # PITR — controlled per environment via variable
  point_in_time_recovery {
    enabled = var.dynamodb_point_in_time_recovery
  }

  # Encryption at rest using the AWS-managed DynamoDB key (no cost overhead)
  server_side_encryption {
    enabled = true
  }

  # Prevent accidental table deletion in automated pipelines
  lifecycle {
    prevent_destroy = false # Set to true in prod via override
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-${var.dynamodb_table_suffix}" })
}
