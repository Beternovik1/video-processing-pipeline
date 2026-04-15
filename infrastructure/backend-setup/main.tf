# infrastructure/backend-setup/main.tf

terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Project   = "VideoProcessingPipeline"
      ManagedBy = "Terraform"
      Purpose   = "StateBackend"
    }
  }
}

# ============================================================================
# S3 Bucket para el Estado de Terraform
# ============================================================================

resource "aws_s3_bucket" "terraform_state" {
  bucket = var.state_bucket_name
  
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "Terraform State Storage"
  }
}

# Versionamiento: Permite recuperar estados anteriores
resource "aws_s3_bucket_versioning" "enabled" {
  bucket = aws_s3_bucket.terraform_state.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

# Encriptación: Protege datos sensibles en el estado
resource "aws_s3_bucket_server_side_encryption_configuration" "default" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true  # Reduce costos de encriptación
  }
}

# Bloqueo de acceso público: CRÍTICO para seguridad
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Logging: Auditoría de accesos al estado
resource "aws_s3_bucket_logging" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  target_bucket = aws_s3_bucket.terraform_state.id
  target_prefix = "access-logs/"
}

# Lifecycle: Limpia versiones antiguas para controlar costos
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90  # Mantén versiones por 90 días
    }
  }

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {
      prefix = "access-logs/"
    }

    expiration {
      days = 30  # Logs solo por 30 días
    }
  }
}

# ============================================================================
# DynamoDB para State Locking
# ============================================================================

resource "aws_dynamodb_table" "terraform_locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Point-in-time recovery: Backup automático (cuesta ~$0.20/mes)
  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name = "Terraform State Locks"
  }
}

# ============================================================================
# Outputs para otros módulos
# ============================================================================

output "state_bucket_id" {
  description = "ID del bucket S3 para el estado de Terraform"
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN del bucket S3"
  value       = aws_s3_bucket.terraform_state.arn
}

output "dynamodb_table_name" {
  description = "Nombre de la tabla DynamoDB para locks"
  value       = aws_dynamodb_table.terraform_locks.name
}

output "dynamodb_table_arn" {
  description = "ARN de la tabla DynamoDB"
  value       = aws_dynamodb_table.terraform_locks.arn
}