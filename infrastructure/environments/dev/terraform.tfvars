# ==============================================================================
# environments/dev/terraform.tfvars
# ==============================================================================

# ------------------------------------------------------------------------------
# Global
# ------------------------------------------------------------------------------
project     = "video-pipeline-edgar-alfaro-2026"
environment = "dev"
aws_region  = "us-east-1"

# ------------------------------------------------------------------------------
# Storage — S3 raw
# Nombre: video-pipeline-dev-raw-ingestion
# ------------------------------------------------------------------------------
raw_bucket_suffix                    = "raw-ingestion"
raw_bucket_force_destroy             = true
raw_bucket_lifecycle_expiration_days = 30

# ------------------------------------------------------------------------------
# Storage — S3 processed
# Nombre: video-pipeline-dev-processed-output
# ------------------------------------------------------------------------------
processed_bucket_suffix                    = "processed-output"
processed_bucket_force_destroy             = true
processed_bucket_lifecycle_expiration_days = 60

# ------------------------------------------------------------------------------
# Storage — DynamoDB
# Nombre: video-pipeline-dev-video-metadata
# ------------------------------------------------------------------------------
dynamodb_table_suffix           = "video-metadata"
dynamodb_billing_mode           = "PAY_PER_REQUEST"
dynamodb_point_in_time_recovery = false

# ------------------------------------------------------------------------------
# Messaging — SNS ingesta
# Nombre: video-pipeline-dev-video-ingest-fanout
# ------------------------------------------------------------------------------
sns_ingest_topic_suffix = "video-ingest-fanout"
sns_kms_master_key_id   = "alias/aws/sns"

# ------------------------------------------------------------------------------
# Messaging — SNS alertas
# Nombre: video-pipeline-dev-video-pipeline-alerts
#
# Después del apply, suscribe tu email:
#   Consola AWS → SNS → Topics → video-pipeline-dev-video-pipeline-alerts
#   → Create subscription → Protocol: Email → tu@email.com → Confirm
# ------------------------------------------------------------------------------
sns_alerts_topic_suffix = "video-pipeline-alerts"

# ------------------------------------------------------------------------------
# Messaging — SQS FFmpeg
# Nombre: video-pipeline-dev-ffmpeg-processing
#
# REGLA 6x: visibility_timeout >= 6 × ffmpeg_lambda_timeout_seconds
#   ffmpeg_lambda_timeout_seconds = 900
#   900 × 6 = 5400 segundos ← este valor
#
# Si visibility_timeout < 5400: SQS redistribuye el mensaje antes de que
# la Lambda termine → dos Lambdas procesando el mismo video → duplicados.
# ------------------------------------------------------------------------------
ffmpeg_queue_suffix                     = "ffmpeg-processing"
ffmpeg_queue_visibility_timeout_seconds = 5400
ffmpeg_queue_max_receive_count          = 3

# ------------------------------------------------------------------------------
# Messaging — SQS metadata
# Nombre: video-pipeline-dev-metadata-extraction
# visibility_timeout = 6 × 20s = 120s
# ------------------------------------------------------------------------------
metadata_queue_suffix                     = "metadata-extraction"
metadata_queue_visibility_timeout_seconds = 120
metadata_queue_max_receive_count          = 3

# ------------------------------------------------------------------------------
# Messaging — DLQs
# 1209600 = 14 días = máximo de SQS
# ------------------------------------------------------------------------------
dlq_message_retention_seconds = 1209600

# ------------------------------------------------------------------------------
# Messaging — Filtros S3
# ------------------------------------------------------------------------------
s3_notification_filter_prefix = "uploads/"
s3_notification_filter_suffix = ".mp4"

# ------------------------------------------------------------------------------
# Compute — Lambda compartido
# arm64/Graviton: ~20% más barato que x86_64 con igual rendimiento en Python
# ------------------------------------------------------------------------------
lambda_runtime            = "python3.12"
lambda_architecture       = "arm64"
lambda_log_retention_days = 14

# ------------------------------------------------------------------------------
# Compute — Lambda FFmpeg
# Nombre: video-pipeline-dev-ffmpeg-processor
#
# memory_mb = 3008: ~1.7 vCPU, punto óptimo costo/rendimiento para 1080p.
# timeout   = 900:  máximo de Lambda. Necesario para videos grandes en dev.
# batch     = 1:    un video por invocación — FFmpeg usa toda la memoria.
# concurrency = 5:  5 × 3008 MB = ~15 GB RAM concurrente máximo. Controlable.
# ------------------------------------------------------------------------------
ffmpeg_lambda_suffix          = "ffmpeg-processor"
ffmpeg_lambda_memory_mb       = 3008
ffmpeg_lambda_timeout_seconds = 900
ffmpeg_esm_batch_size         = 1
ffmpeg_esm_max_concurrency    = 5

# ------------------------------------------------------------------------------
# Compute — Lambda metadata
# Nombre: video-pipeline-dev-metadata-extractor
#
# memory_mb = 512:  proceso I/O bound, no necesita más CPU.
# timeout   = 20s:  suficiente incluso para videos de varios GB.
# batch     = 5:    extracción es ligera, varios en paralelo no es problema.
# concurrency = 10: más permisivo que FFmpeg — el proceso es barato.
# ------------------------------------------------------------------------------
metadata_lambda_suffix          = "metadata-extractor"
metadata_lambda_memory_mb       = 512
metadata_lambda_timeout_seconds = 20
metadata_esm_batch_size         = 5
metadata_esm_max_concurrency    = 10

# ------------------------------------------------------------------------------
# Compute — Lambda notification
# Nombre: video-pipeline-dev-notification
#
# memory_mb = 256:  proceso mínimo: leer Stream + llamar sns:Publish.
# timeout   = 15s:  más que suficiente para una llamada a la API de SNS.
# batch     = 10:   puede procesar varios cambios de estado en una invocación.
# ------------------------------------------------------------------------------
notification_lambda_suffix          = "notification"
notification_lambda_memory_mb       = 256
notification_lambda_timeout_seconds = 15
notification_esm_batch_size         = 10
notification_esm_starting_position  = "LATEST"

# ------------------------------------------------------------------------------
# Tags
# ------------------------------------------------------------------------------
additional_tags = {
  Owner      = "platform-team"
  CostCenter = "engineering-dev"
}
