# ==============================================================================
# environments/dev/main.tf
#
# Punto de entrada del entorno dev. Orquesta los tres módulos del pipeline.
#
# DAG de dependencias (unidireccional, sin ciclos):
#   module.storage  ──outputs──► module.messaging
#   module.storage  ──outputs──► module.compute
#   module.messaging ──outputs──► module.compute
#
# DECISIÓN ARQUITECTÓNICA REGISTRADA:
#   Las notificaciones al operador usan SNS (alerts topic), no SES.
#   alerts_topic_arn fluye de module.messaging → module.compute.
# ==============================================================================

terraform {
  required_version = ">= 1.6.0"

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
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# Resuelve el account ID en tiempo de plan — sin hardcodear números de cuenta.
# Funciona correctamente en dev, staging, y prod sin cambiar el código.
data "aws_caller_identity" "current" {}

# ==============================================================================
# Módulo 1: Storage
# Crea: S3 raw, S3 processed, DynamoDB + Stream
# ==============================================================================

module "storage" {
  source = "../../modules/storage"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  raw_bucket_suffix                    = var.raw_bucket_suffix
  raw_bucket_force_destroy             = var.raw_bucket_force_destroy
  raw_bucket_lifecycle_expiration_days = var.raw_bucket_lifecycle_expiration_days

  processed_bucket_suffix                    = var.processed_bucket_suffix
  processed_bucket_force_destroy             = var.processed_bucket_force_destroy
  processed_bucket_lifecycle_expiration_days = var.processed_bucket_lifecycle_expiration_days

  dynamodb_table_suffix           = var.dynamodb_table_suffix
  dynamodb_billing_mode           = var.dynamodb_billing_mode
  dynamodb_point_in_time_recovery = var.dynamodb_point_in_time_recovery

  additional_tags = var.additional_tags
}

# ==============================================================================
# Módulo 2: Messaging
# Crea: SNS ingesta, SNS alertas, SQS x2, DLQ x2, policies, subscriptions,
#        S3 bucket notification
#
# Recibe raw_bucket_id y raw_bucket_arn de module.storage.
# Esta referencia es la que construye el DAG: Terraform crea storage primero.
# ==============================================================================

module "messaging" {
  source = "../../modules/messaging"

  project        = var.project
  environment    = var.environment
  aws_region     = var.aws_region
  aws_account_id = data.aws_caller_identity.current.account_id

  # ── DAG edge: storage → messaging ──────────────────────────────────────────
  raw_bucket_id  = module.storage.raw_bucket_id
  raw_bucket_arn = module.storage.raw_bucket_arn

  # ── SNS ────────────────────────────────────────────────────────────────────
  sns_ingest_topic_suffix = var.sns_ingest_topic_suffix
  sns_alerts_topic_suffix = var.sns_alerts_topic_suffix
  sns_kms_master_key_id   = var.sns_kms_master_key_id

  # ── SQS FFmpeg ──────────────────────────────────────────────────────────────
  ffmpeg_queue_suffix                     = var.ffmpeg_queue_suffix
  ffmpeg_queue_visibility_timeout_seconds = var.ffmpeg_queue_visibility_timeout_seconds
  ffmpeg_queue_max_receive_count          = var.ffmpeg_queue_max_receive_count

  # ── SQS metadata ───────────────────────────────────────────────────────────
  metadata_queue_suffix                     = var.metadata_queue_suffix
  metadata_queue_visibility_timeout_seconds = var.metadata_queue_visibility_timeout_seconds
  metadata_queue_max_receive_count          = var.metadata_queue_max_receive_count

  # ── DLQs ───────────────────────────────────────────────────────────────────
  dlq_message_retention_seconds = var.dlq_message_retention_seconds

  # ── Filtros S3 ─────────────────────────────────────────────────────────────
  s3_notification_filter_prefix = var.s3_notification_filter_prefix
  s3_notification_filter_suffix = var.s3_notification_filter_suffix

  additional_tags = var.additional_tags
}

# ==============================================================================
# Módulo 3: Compute
# Crea: 3 IAM roles, 3 Lambdas, 3 CloudWatch Log Groups, 3 ESMs
#
# Recibe outputs de ambos módulos anteriores.
# alerts_topic_arn viene de module.messaging — elimina SES por completo.
# ==============================================================================

module "compute" {
  source = "../../modules/compute"

  project        = var.project
  environment    = var.environment
  aws_region     = var.aws_region
  aws_account_id = data.aws_caller_identity.current.account_id

  # ── DAG edge: storage → compute ────────────────────────────────────────────
  raw_bucket_arn       = module.storage.raw_bucket_arn
  processed_bucket_arn = module.storage.processed_bucket_arn
  processed_bucket_id  = module.storage.processed_bucket_id
  dynamodb_table_arn   = module.storage.dynamodb_table_arn
  dynamodb_table_id    = module.storage.dynamodb_table_id
  dynamodb_stream_arn  = module.storage.dynamodb_stream_arn

  # ── DAG edge: messaging → compute ──────────────────────────────────────────
  ffmpeg_queue_arn   = module.messaging.ffmpeg_queue_arn
  metadata_queue_arn = module.messaging.metadata_queue_arn
  alerts_topic_arn   = module.messaging.sns_alerts_topic_arn

  # ── Lambda compartido ───────────────────────────────────────────────────────
  lambda_runtime            = var.lambda_runtime
  lambda_architecture       = var.lambda_architecture
  lambda_log_retention_days = var.lambda_log_retention_days

  # ── FFmpeg Lambda ───────────────────────────────────────────────────────────
  ffmpeg_lambda_suffix          = var.ffmpeg_lambda_suffix
  ffmpeg_lambda_memory_mb       = var.ffmpeg_lambda_memory_mb
  ffmpeg_lambda_timeout_seconds = var.ffmpeg_lambda_timeout_seconds
  ffmpeg_esm_batch_size         = var.ffmpeg_esm_batch_size
  ffmpeg_esm_max_concurrency    = var.ffmpeg_esm_max_concurrency

  # ── Metadata Lambda ─────────────────────────────────────────────────────────
  metadata_lambda_suffix          = var.metadata_lambda_suffix
  metadata_lambda_memory_mb       = var.metadata_lambda_memory_mb
  metadata_lambda_timeout_seconds = var.metadata_lambda_timeout_seconds
  metadata_esm_batch_size         = var.metadata_esm_batch_size
  metadata_esm_max_concurrency    = var.metadata_esm_max_concurrency

  # ── Notification Lambda ─────────────────────────────────────────────────────
  notification_lambda_suffix          = var.notification_lambda_suffix
  notification_lambda_memory_mb       = var.notification_lambda_memory_mb
  notification_lambda_timeout_seconds = var.notification_lambda_timeout_seconds
  notification_esm_batch_size         = var.notification_esm_batch_size
  notification_esm_starting_position  = var.notification_esm_starting_position

  additional_tags = var.additional_tags
}

# ==============================================================================
# Outputs del entorno
# Visibles con: terraform output
# Consumibles por otros stacks con: data "terraform_remote_state"
# ==============================================================================

# --- Storage ---
output "raw_bucket_id"        { value = module.storage.raw_bucket_id }
output "raw_bucket_arn"       { value = module.storage.raw_bucket_arn }
output "processed_bucket_id"  { value = module.storage.processed_bucket_id }
output "dynamodb_table_id"    { value = module.storage.dynamodb_table_id }
output "dynamodb_stream_arn"  { value = module.storage.dynamodb_stream_arn }

# --- Messaging ---
output "sns_ingest_topic_arn" { value = module.messaging.sns_ingest_topic_arn }
output "sns_alerts_topic_arn" { value = module.messaging.sns_alerts_topic_arn }
output "sns_alerts_topic_name" {
  description = "Nombre del topic de alertas. Búscalo en la consola SNS para suscribir tu email."
  value       = module.messaging.sns_alerts_topic_name
}
output "ffmpeg_queue_arn"     { value = module.messaging.ffmpeg_queue_arn }
output "metadata_queue_arn"   { value = module.messaging.metadata_queue_arn }
output "ffmpeg_dlq_arn"       { value = module.messaging.ffmpeg_dlq_arn }
output "metadata_dlq_arn"     { value = module.messaging.metadata_dlq_arn }

# --- Compute ---
output "ffmpeg_lambda_name"       { value = module.compute.ffmpeg_lambda_name }
output "metadata_lambda_name"     { value = module.compute.metadata_lambda_name }
output "notification_lambda_name" { value = module.compute.notification_lambda_name }
output "ffmpeg_log_group"         { value = module.compute.ffmpeg_log_group_name }
output "metadata_log_group"       { value = module.compute.metadata_log_group_name }
output "notification_log_group"   { value = module.compute.notification_log_group_name }

# ==============================================================================
# AWS Budgets: Control de Costos (FinOps)
# ==============================================================================

resource "aws_budgets_budget" "cost_limit" {
  name              = "presupuesto-mensual-${var.project}"
  budget_type       = "COST"
  limit_amount      = "10"
  limit_unit        = "USD"
  time_period_start = "2026-04-01_00:00"
  time_unit         = "MONTHLY"

  # Alerta 1: Cuando el gasto REAL llega al 80% ($8)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["edgaralfarohernandez15@gmail.com"] 
  }

  # Alerta 2: Cuando el gasto PROYECTADO llega al 100% ($10)
  # Esto avisa ANTES de que te cobren, basándose en el ritmo de uso.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = ["edgaralfarohernandez15@gmail.com"]
  }
}