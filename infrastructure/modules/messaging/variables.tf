# ==============================================================================
# modules/messaging/variables.tf
# ==============================================================================

variable "project" {
  description = "Nombre del proyecto. Prefijo raíz de todos los recursos."
  type        = string
}

variable "environment" {
  description = "Entorno de despliegue (dev | staging | prod)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment debe ser dev, staging, o prod."
  }
}

variable "aws_region" {
  description = "Región AWS donde se despliegan los recursos."
  type        = string
}

variable "aws_account_id" {
  description = "ID de la cuenta AWS. Usado en resource policies para el Confused Deputy fix."
  type        = string
}

# ------------------------------------------------------------------------------
# Inputs del módulo storage (DAG unidireccional)
# El módulo messaging no importa storage directamente — recibe sus datos como
# variables desde dev/main.tf. Esto mantiene la dependencia en una sola dirección.
# ------------------------------------------------------------------------------

variable "raw_bucket_id" {
  description = "Nombre del bucket S3 de ingesta. Fuente: module.storage.raw_bucket_id."
  type        = string
}

variable "raw_bucket_arn" {
  description = "ARN del bucket S3 de ingesta. Usado en la SNS topic policy (Confused Deputy fix)."
  type        = string
}

# ------------------------------------------------------------------------------
# SNS — Topic de ingesta (fan-out hacia SQS)
# ------------------------------------------------------------------------------

variable "sns_ingest_topic_suffix" {
  description = "Sufijo para el SNS topic de fan-out de ingesta de videos."
  type        = string
  default     = "video-ingest-fanout"
}

variable "sns_kms_master_key_id" {
  description = "Clave KMS para cifrado en reposo de SNS. 'alias/aws/sns' usa la clave administrada por AWS sin costo extra."
  type        = string
  default     = "alias/aws/sns"
}

# ------------------------------------------------------------------------------
# SNS — Topic de alertas al operador
#
# DECISIÓN ARQUITECTÓNICA: Se usa SNS en lugar de SES para notificaciones.
# Ventaja: el operador se suscribe con su email desde la consola en 30 segundos.
# Sin dominios, sin Route53, sin tickets de soporte de SES sandbox.
# La Lambda de Notificación publica aquí; SNS entrega el texto crudo al email.
# ------------------------------------------------------------------------------

variable "sns_alerts_topic_suffix" {
  description = "Sufijo para el SNS topic de alertas. El operador se suscribe manualmente con su email."
  type        = string
  default     = "video-pipeline-alerts"
}

# ------------------------------------------------------------------------------
# SQS — Cola FFmpeg
# ------------------------------------------------------------------------------

variable "ffmpeg_queue_suffix" {
  description = "Sufijo para la cola SQS de procesamiento FFmpeg."
  type        = string
  default     = "ffmpeg-processing"
}

variable "ffmpeg_queue_visibility_timeout_seconds" {
  description = "Visibility timeout en segundos. Regla de oro: mínimo 6x el timeout de la Lambda consumidora."
  type        = number
  default     = 360

  validation {
    condition     = var.ffmpeg_queue_visibility_timeout_seconds >= 0 && var.ffmpeg_queue_visibility_timeout_seconds <= 43200
    error_message = "El visibility timeout debe estar entre 0 y 43200 segundos."
  }
}

variable "ffmpeg_queue_max_receive_count" {
  description = "Número de intentos de entrega antes de enviar el mensaje al DLQ de FFmpeg."
  type        = number
  default     = 3
}

# ------------------------------------------------------------------------------
# SQS — Cola metadata
# ------------------------------------------------------------------------------

variable "metadata_queue_suffix" {
  description = "Sufijo para la cola SQS de extracción de metadatos."
  type        = string
  default     = "metadata-extraction"
}

variable "metadata_queue_visibility_timeout_seconds" {
  description = "Visibility timeout en segundos para la cola de metadatos."
  type        = number
  default     = 120

  validation {
    condition     = var.metadata_queue_visibility_timeout_seconds >= 0 && var.metadata_queue_visibility_timeout_seconds <= 43200
    error_message = "El visibility timeout debe estar entre 0 y 43200 segundos."
  }
}

variable "metadata_queue_max_receive_count" {
  description = "Número de intentos de entrega antes de enviar el mensaje al DLQ de metadatos."
  type        = number
  default     = 3
}

# ------------------------------------------------------------------------------
# SQS — Configuración compartida de DLQs
# ------------------------------------------------------------------------------

variable "dlq_message_retention_seconds" {
  description = "Tiempo de retención en DLQs. Default: 14 días (máximo de SQS). Da tiempo máximo para debuggear."
  type        = number
  default     = 1209600

  validation {
    condition     = var.dlq_message_retention_seconds >= 60 && var.dlq_message_retention_seconds <= 1209600
    error_message = "La retención debe estar entre 60 y 1,209,600 segundos (14 días)."
  }
}

# ------------------------------------------------------------------------------
# Filtros del evento S3
# ------------------------------------------------------------------------------

variable "s3_notification_filter_prefix" {
  description = "Prefijo S3 para filtrar eventos. Solo objetos bajo esta ruta disparan el pipeline."
  type        = string
  default     = "uploads/"
}

variable "s3_notification_filter_suffix" {
  description = "Sufijo S3 para filtrar eventos. Restringe el trigger a extensiones específicas."
  type        = string
  default     = ".mp4"
}

# ------------------------------------------------------------------------------
# Tags
# ------------------------------------------------------------------------------

variable "additional_tags" {
  description = "Tags adicionales fusionados en todos los recursos del módulo."
  type        = map(string)
  default     = {}
}
