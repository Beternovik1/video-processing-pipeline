# ==============================================================================
# environments/dev/variables.tf
# ==============================================================================

# ------------------------------------------------------------------------------
# Global
# ------------------------------------------------------------------------------

variable "project" {
  description = "Nombre del proyecto. Prefijo raíz de todos los recursos."
  type        = string
}

variable "environment" {
  description = "Entorno de despliegue (dev | staging | prod)."
  type        = string
}

variable "aws_region" {
  description = "Región AWS para todos los recursos de este entorno."
  type        = string
}

# ------------------------------------------------------------------------------
# Módulo storage — S3 raw
# ------------------------------------------------------------------------------

variable "raw_bucket_suffix" {
  type    = string
  default = "raw-ingestion"
}

variable "raw_bucket_force_destroy" {
  type    = bool
  default = false
}

variable "raw_bucket_lifecycle_expiration_days" {
  type    = number
  default = 90
}

# ------------------------------------------------------------------------------
# Módulo storage — S3 processed
# ------------------------------------------------------------------------------

variable "processed_bucket_suffix" {
  type    = string
  default = "processed-output"
}

variable "processed_bucket_force_destroy" {
  type    = bool
  default = false
}

variable "processed_bucket_lifecycle_expiration_days" {
  type    = number
  default = 365
}

# ------------------------------------------------------------------------------
# Módulo storage — DynamoDB
# ------------------------------------------------------------------------------

variable "dynamodb_table_suffix" {
  type    = string
  default = "video-metadata"
}

variable "dynamodb_billing_mode" {
  type    = string
  default = "PAY_PER_REQUEST"
}

variable "dynamodb_point_in_time_recovery" {
  type    = bool
  default = false
}

# ------------------------------------------------------------------------------
# Módulo messaging — SNS ingesta
# ------------------------------------------------------------------------------

variable "sns_ingest_topic_suffix" {
  type    = string
  default = "video-ingest-fanout"
}

variable "sns_kms_master_key_id" {
  type    = string
  default = "alias/aws/sns"
}

# ------------------------------------------------------------------------------
# Módulo messaging — SNS alertas
# ------------------------------------------------------------------------------

variable "sns_alerts_topic_suffix" {
  type    = string
  default = "video-pipeline-alerts"
}

# ------------------------------------------------------------------------------
# Módulo messaging — SQS FFmpeg
# ------------------------------------------------------------------------------

variable "ffmpeg_queue_suffix" {
  type    = string
  default = "ffmpeg-processing"
}

variable "ffmpeg_queue_visibility_timeout_seconds" {
  type    = number
  default = 360
}

variable "ffmpeg_queue_max_receive_count" {
  type    = number
  default = 3
}

# ------------------------------------------------------------------------------
# Módulo messaging — SQS metadata
# ------------------------------------------------------------------------------

variable "metadata_queue_suffix" {
  type    = string
  default = "metadata-extraction"
}

variable "metadata_queue_visibility_timeout_seconds" {
  type    = number
  default = 120
}

variable "metadata_queue_max_receive_count" {
  type    = number
  default = 3
}

# ------------------------------------------------------------------------------
# Módulo messaging — DLQs compartidas
# ------------------------------------------------------------------------------

variable "dlq_message_retention_seconds" {
  type    = number
  default = 1209600
}

# ------------------------------------------------------------------------------
# Módulo messaging — Filtros S3
# ------------------------------------------------------------------------------

variable "s3_notification_filter_prefix" {
  type    = string
  default = "uploads/"
}

variable "s3_notification_filter_suffix" {
  type    = string
  default = ".mp4"
}

# ------------------------------------------------------------------------------
# Módulo compute — Lambda compartido
# ------------------------------------------------------------------------------

variable "lambda_runtime" {
  type    = string
  default = "python3.12"
}

variable "lambda_architecture" {
  type    = string
  default = "arm64"
}

variable "lambda_log_retention_days" {
  type    = number
  default = 14
}

# ------------------------------------------------------------------------------
# Módulo compute — Lambda FFmpeg
# ------------------------------------------------------------------------------

variable "ffmpeg_lambda_suffix" {
  type    = string
  default = "ffmpeg-processor"
}

variable "ffmpeg_lambda_memory_mb" {
  type    = number
  default = 3008
}

variable "ffmpeg_lambda_timeout_seconds" {
  type    = number
  default = 60
}

variable "ffmpeg_esm_batch_size" {
  type    = number
  default = 1
}

variable "ffmpeg_esm_max_concurrency" {
  type    = number
  default = 5
}

# ------------------------------------------------------------------------------
# Módulo compute — Lambda metadata
# ------------------------------------------------------------------------------

variable "metadata_lambda_suffix" {
  type    = string
  default = "metadata-extractor"
}

variable "metadata_lambda_memory_mb" {
  type    = number
  default = 512
}

variable "metadata_lambda_timeout_seconds" {
  type    = number
  default = 20
}

variable "metadata_esm_batch_size" {
  type    = number
  default = 5
}

variable "metadata_esm_max_concurrency" {
  type    = number
  default = 10
}

# ------------------------------------------------------------------------------
# Módulo compute — Lambda notification
# ------------------------------------------------------------------------------

variable "notification_lambda_suffix" {
  type    = string
  default = "notification"
}

variable "notification_lambda_memory_mb" {
  type    = number
  default = 256
}

variable "notification_lambda_timeout_seconds" {
  type    = number
  default = 15
}

variable "notification_esm_batch_size" {
  type    = number
  default = 10
}

variable "notification_esm_starting_position" {
  type    = string
  default = "LATEST"
}

# ------------------------------------------------------------------------------
# Tags
# ------------------------------------------------------------------------------

variable "additional_tags" {
  type    = map(string)
  default = {}
}
