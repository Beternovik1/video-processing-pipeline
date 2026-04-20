# ==============================================================================
# modules/compute/variables.tf
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
  description = "ID de la cuenta AWS."
  type        = string
}

# ------------------------------------------------------------------------------
# Inputs de module.storage
# ------------------------------------------------------------------------------

variable "raw_bucket_arn" {
  description = "ARN del bucket S3 de ingesta. Permiso de lectura para la Lambda FFmpeg."
  type        = string
}

variable "processed_bucket_arn" {
  description = "ARN del bucket S3 procesado. Permiso de escritura para la Lambda FFmpeg."
  type        = string
}

variable "processed_bucket_id" {
  description = "Nombre del bucket S3 procesado. Variable de entorno en la Lambda FFmpeg."
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN de la tabla DynamoDB."
  type        = string
}

variable "dynamodb_table_id" {
  description = "Nombre de la tabla DynamoDB. Variable de entorno en las Lambdas."
  type        = string
}

variable "dynamodb_stream_arn" {
  description = "ARN del DynamoDB Stream. Fuente de eventos de la Lambda Notification."
  type        = string
}

# ------------------------------------------------------------------------------
# Inputs de module.messaging
# ------------------------------------------------------------------------------

variable "ffmpeg_queue_arn" {
  description = "ARN de la cola SQS de FFmpeg. Fuente de eventos de la Lambda FFmpeg."
  type        = string
}

variable "metadata_queue_arn" {
  description = "ARN de la cola SQS de metadatos. Fuente de eventos de la Lambda Metadata."
  type        = string
}

variable "alerts_topic_arn" {
  description = "ARN del SNS topic de alertas. La Lambda Notification publica aquí."
  type        = string
}

# ------------------------------------------------------------------------------
# Lambda — Configuración compartida
# ------------------------------------------------------------------------------

variable "lambda_runtime" {
  description = "Runtime de todas las Lambdas del pipeline."
  type        = string
  default     = "python3.12"
}

variable "lambda_architecture" {
  description = "Arquitectura (x86_64 | arm64). arm64/Graviton es ~20% más barato."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.lambda_architecture)
    error_message = "Debe ser x86_64 o arm64."
  }
}

variable "lambda_log_retention_days" {
  description = "Retención de logs CloudWatch en días. Previene acumulación infinita de logs."
  type        = number
  default     = 14
}

# ------------------------------------------------------------------------------
# Lambda FFmpeg — Límites físicos
#
# memory_mb: Lambda asigna vCPU proporcional a memoria.
#   128 MB  = 0.07 vCPU  → demasiado lento para transcodificación
#   1769 MB = 1 vCPU exacto (umbral documentado por AWS)
#   3008 MB ≈ 1.7 vCPU   → punto de costo/rendimiento óptimo para 1080p
#   10240 MB = 6 vCPU    → máximo absoluto
#
# timeout_seconds: 900 = 15 minutos = máximo de Lambda.
#   Requerido para videos grandes en dev donde no hay restricciones de SLA.
#   IMPORTANTE: el visibility_timeout de la cola SQS ffmpeg debe ser
#   mínimo 6x este valor → 5400 segundos. Ver terraform.tfvars.
# ------------------------------------------------------------------------------

variable "ffmpeg_lambda_suffix" {
  description = "Sufijo del nombre de la Lambda FFmpeg."
  type        = string
  default     = "ffmpeg-processor"
}

variable "ffmpeg_lambda_memory_mb" {
  description = "Memoria en MB para la Lambda FFmpeg. Controla directamente la CPU asignada por AWS."
  type        = number
  default     = 3008

  validation {
    condition     = var.ffmpeg_lambda_memory_mb >= 128 && var.ffmpeg_lambda_memory_mb <= 10240
    error_message = "La memoria debe estar entre 128 MB y 10240 MB."
  }
}

variable "ffmpeg_lambda_timeout_seconds" {
  description = "Timeout de la Lambda FFmpeg en segundos. 900 = máximo de Lambda. La cola SQS debe tener visibility_timeout >= 6x este valor."
  type        = number
  default     = 900

  validation {
    condition     = var.ffmpeg_lambda_timeout_seconds >= 1 && var.ffmpeg_lambda_timeout_seconds <= 900
    error_message = "El timeout debe estar entre 1 y 900 segundos."
  }
}

# ------------------------------------------------------------------------------
# ESM FFmpeg — Protecciones de concurrencia
#
# batch_size = 1: un video por invocación. FFmpeg usa toda la memoria
#   asignada — procesar varios en paralelo dentro de la misma Lambda
#   agotaría la memoria y causaría OOM kills.
#
# max_concurrency = 5: cap duro de Lambdas simultáneas leyendo esta cola.
#   Sin este límite, 100 uploads simultáneos en dev podrían lanzar
#   100 Lambdas de 3 GB cada una → ~300 GB de RAM consumidos → factura inesperada.
#   5 Lambdas × 3008 MB = ~15 GB máximo concurrente. Controlable.
# ------------------------------------------------------------------------------

variable "ffmpeg_esm_batch_size" {
  description = "Mensajes SQS por invocación FFmpeg. Mantener en 1: un video por Lambda."
  type        = number
  default     = 1

  validation {
    condition     = var.ffmpeg_esm_batch_size >= 1 && var.ffmpeg_esm_batch_size <= 10000
    error_message = "batch_size debe estar entre 1 y 10000."
  }
}

variable "ffmpeg_esm_max_concurrency" {
  description = "Máximo de Lambdas FFmpeg concurrentes. Protección contra scaling descontrolado en dev."
  type        = number
  default     = 5

  validation {
    condition     = var.ffmpeg_esm_max_concurrency >= 2 && var.ffmpeg_esm_max_concurrency <= 1000
    error_message = "max_concurrency debe estar entre 2 y 1000."
  }
}

# ------------------------------------------------------------------------------
# Lambda Metadata — Límites físicos
#
# Proceso I/O bound (lee del video, escribe en DynamoDB).
# No necesita más de 512 MB — no hay procesamiento de frames.
# Timeout de 20s es suficiente incluso para videos de varios GB.
# ------------------------------------------------------------------------------

variable "metadata_lambda_suffix" {
  description = "Sufijo del nombre de la Lambda de metadatos."
  type        = string
  default     = "metadata-extractor"
}

variable "metadata_lambda_memory_mb" {
  description = "Memoria en MB para la Lambda de metadatos."
  type        = number
  default     = 512

  validation {
    condition     = var.metadata_lambda_memory_mb >= 128 && var.metadata_lambda_memory_mb <= 10240
    error_message = "La memoria debe estar entre 128 MB y 10240 MB."
  }
}

variable "metadata_lambda_timeout_seconds" {
  description = "Timeout de la Lambda de metadatos en segundos."
  type        = number
  default     = 20

  validation {
    condition     = var.metadata_lambda_timeout_seconds >= 1 && var.metadata_lambda_timeout_seconds <= 900
    error_message = "El timeout debe estar entre 1 y 900 segundos."
  }
}

variable "metadata_esm_batch_size" {
  description = "Mensajes SQS por invocación de la Lambda de metadatos."
  type        = number
  default     = 5

  validation {
    condition     = var.metadata_esm_batch_size >= 1 && var.metadata_esm_batch_size <= 10000
    error_message = "batch_size debe estar entre 1 y 10000."
  }
}

variable "metadata_esm_max_concurrency" {
  description = "Máximo de Lambdas de metadatos concurrentes."
  type        = number
  default     = 10

  validation {
    condition     = var.metadata_esm_max_concurrency >= 2 && var.metadata_esm_max_concurrency <= 1000
    error_message = "max_concurrency debe estar entre 2 y 1000."
  }
}

# ------------------------------------------------------------------------------
# Lambda Notification — Límites físicos
#
# Proceso ultra-ligero: lee un registro del Stream, construye un string,
# llama a sns:Publish. 256 MB y 15s son más que suficientes.
# ------------------------------------------------------------------------------

variable "notification_lambda_suffix" {
  description = "Sufijo del nombre de la Lambda de notificación."
  type        = string
  default     = "notification"
}

variable "notification_lambda_memory_mb" {
  description = "Memoria en MB para la Lambda de notificación."
  type        = number
  default     = 256

  validation {
    condition     = var.notification_lambda_memory_mb >= 128 && var.notification_lambda_memory_mb <= 10240
    error_message = "La memoria debe estar entre 128 MB y 10240 MB."
  }
}

variable "notification_lambda_timeout_seconds" {
  description = "Timeout de la Lambda de notificación en segundos."
  type        = number
  default     = 15

  validation {
    condition     = var.notification_lambda_timeout_seconds >= 1 && var.notification_lambda_timeout_seconds <= 900
    error_message = "El timeout debe estar entre 1 y 900 segundos."
  }
}

variable "notification_esm_batch_size" {
  description = "Registros del DynamoDB Stream por invocación de la Lambda de notificación."
  type        = number
  default     = 10

  validation {
    condition     = var.notification_esm_batch_size >= 1 && var.notification_esm_batch_size <= 10000
    error_message = "batch_size debe estar entre 1 y 10000."
  }
}

variable "notification_esm_starting_position" {
  description = "Posición inicial del iterador del Stream. LATEST = solo eventos nuevos desde el deploy."
  type        = string
  default     = "LATEST"

  validation {
    condition     = contains(["TRIM_HORIZON", "LATEST"], var.notification_esm_starting_position)
    error_message = "Debe ser TRIM_HORIZON o LATEST."
  }
}

# ------------------------------------------------------------------------------
# Tags
# ------------------------------------------------------------------------------

variable "additional_tags" {
  description = "Tags adicionales fusionados en todos los recursos del módulo."
  type        = map(string)
  default     = {}
}
