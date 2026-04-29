# ==============================================================================
# modules/messaging/main.tf
#
# Responsabilidad: infraestructura completa de mensajería del pipeline.
#
# Recursos que crea:
#   1. SNS topic de ingesta   → fan-out de eventos S3 hacia las colas SQS
#   2. SNS topic policy       → autoriza a S3 a publicar (Confused Deputy fix)
#   3. SQS ffmpeg + DLQ       → cola de procesamiento de video con FFmpeg
#   4. SQS metadata + DLQ     → cola de extracción de metadatos
#   5. SQS queue policies     → autorizan a SNS a escribir en cada cola
#   6. SNS subscriptions      → conectan el topic de ingesta a las dos colas
#   7. S3 bucket notification → dispara el pipeline en uploads de .mp4
#   8. SNS topic de alertas   → recibe publicaciones de la Lambda Notificación
#
# Flujo de ingesta:
#   S3 upload → SNS ingest → SQS ffmpeg   → Lambda FFmpeg
#                         └→ SQS metadata → Lambda Metadata
#
# Flujo de alertas (DECISIÓN ARQUITECTÓNICA: SNS, no SES):
#   Lambda Notificación → SNS alerts → email del operador (suscripción manual)
#
# DAG: este módulo recibe raw_bucket_id y raw_bucket_arn como variables.
# No importa el módulo storage directamente. La dependencia la resuelve dev/main.tf.
# ==============================================================================

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
      Module      = "messaging"
    },
    var.additional_tags
  )
}

# ==============================================================================
# 1. SNS — Topic de ingesta (fan-out)
# ==============================================================================

resource "aws_sns_topic" "ingest" {
  name              = "${local.name_prefix}-${var.sns_ingest_topic_suffix}"
  # kms_master_key_id = var.sns_kms_master_key_id <- Esta linea esta maldita

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-${var.sns_ingest_topic_suffix}"
    Purpose = "ingest-fanout"
  })
}

# ==============================================================================
# 2. SNS Topic Policy — Confused Deputy fix
#
# Sin esta policy, cualquier bucket S3 en cualquier cuenta AWS podría publicar
# en este topic si conociera su ARN. Las dos condiciones simultáneas lo evitan:
#   - ArnLike:      solo el bucket específico de este pipeline
#   - StringEquals: solo desde esta cuenta AWS específica
# ==============================================================================

resource "aws_sns_topic_policy" "ingest" {
  arn = aws_sns_topic.ingest.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.name_prefix}-sns-ingest-policy"
    Statement = [
      {
        Sid    = "AllowS3ToPublish"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.ingest.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = var.raw_bucket_arn
          }
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })
}

# ==============================================================================
# 3. SQS — Cola FFmpeg + DLQ
#
# La DLQ se crea ANTES que la cola principal porque la cola principal
# la referencia en su redrive_policy. Terraform infiere el orden por
# la referencia aws_sqs_queue.ffmpeg_dlq.arn.
# ==============================================================================

resource "aws_sqs_queue" "ffmpeg_dlq" {
  name                      = "${local.name_prefix}-${var.ffmpeg_queue_suffix}-dlq"
  message_retention_seconds = var.dlq_message_retention_seconds

  sqs_managed_sse_enabled = true

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-${var.ffmpeg_queue_suffix}-dlq"
    Type    = "DLQ"
    Purpose = "ffmpeg-failures"
  })
}

resource "aws_sqs_queue" "ffmpeg" {
  name = "${local.name_prefix}-${var.ffmpeg_queue_suffix}"

  # Visibility timeout = 6x el timeout de la Lambda FFmpeg (60s × 6 = 360s).
  # Si fuera menor, SQS creería que la Lambda falló antes de terminar y
  # redistribuiría el mensaje — dos Lambdas procesando el mismo video.
  visibility_timeout_seconds = var.ffmpeg_queue_visibility_timeout_seconds

  # Long polling: SQS espera hasta 20s antes de responder vacío.
  # Reduce llamadas API innecesarias y costo en pipelines con tráfico intermitente.
  receive_wait_time_seconds = 20

  sqs_managed_sse_enabled = true

  # Después de max_receive_count intentos fallidos, el mensaje va al DLQ.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ffmpeg_dlq.arn
    maxReceiveCount     = var.ffmpeg_queue_max_receive_count
  })

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-${var.ffmpeg_queue_suffix}"
    Purpose = "ffmpeg-processing"
  })
}

# ==============================================================================
# 4. SQS — Cola metadata + DLQ
# ==============================================================================

resource "aws_sqs_queue" "metadata_dlq" {
  name                      = "${local.name_prefix}-${var.metadata_queue_suffix}-dlq"
  message_retention_seconds = var.dlq_message_retention_seconds

  sqs_managed_sse_enabled = true

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-${var.metadata_queue_suffix}-dlq"
    Type    = "DLQ"
    Purpose = "metadata-failures"
  })
}

resource "aws_sqs_queue" "metadata" {
  name                       = "${local.name_prefix}-${var.metadata_queue_suffix}"
  visibility_timeout_seconds = var.metadata_queue_visibility_timeout_seconds
  receive_wait_time_seconds  = 20

  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.metadata_dlq.arn
    maxReceiveCount     = var.metadata_queue_max_receive_count
  })

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-${var.metadata_queue_suffix}"
    Purpose = "metadata-extraction"
  })
}

# ==============================================================================
# 5. SQS Queue Policies
#
# Sin estas policies, SNS intenta entregar el mensaje, AWS lo rechaza
# SILENCIOSAMENTE — no hay error en SNS, el mensaje desaparece.
# Es uno de los bugs más difíciles de diagnosticar en arquitecturas SNS→SQS.
#
# La condición ArnEquals limita la escritura exclusivamente a nuestro topic.
# ==============================================================================

resource "aws_sqs_queue_policy" "ffmpeg" {
  queue_url = aws_sqs_queue.ffmpeg.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.name_prefix}-ffmpeg-sqs-policy"
    Statement = [
      {
        Sid    = "AllowSNSIngestToSend"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.ffmpeg.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_sns_topic.ingest.arn
          }
        }
      }
    ]
  })
}

resource "aws_sqs_queue_policy" "metadata" {
  queue_url = aws_sqs_queue.metadata.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.name_prefix}-metadata-sqs-policy"
    Statement = [
      {
        Sid    = "AllowSNSIngestToSend"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.metadata.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_sns_topic.ingest.arn
          }
        }
      }
    ]
  })
}

# ==============================================================================
# 6. SNS → SQS Subscriptions (fan-out wiring)
#
# raw_message_delivery = true: entrega el JSON del evento S3 directamente.
# Con false, el JSON llega envuelto en el sobre de SNS y requiere doble parse:
#   JSON.parse(JSON.parse(body).Message)
# Con true, la Lambda recibe el evento S3 limpio directamente.
#
# depends_on explícito: cuando SNS registra la suscripción, AWS hace una
# validación en vivo publicando un mensaje de prueba en la cola. Si la
# queue policy no existe aún, el mensaje es rechazado y la suscripción
# queda en PendingConfirmation — nunca activa.
# ==============================================================================

resource "aws_sns_topic_subscription" "to_ffmpeg" {
  topic_arn            = aws_sns_topic.ingest.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.ffmpeg.arn
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.ffmpeg]
}

resource "aws_sns_topic_subscription" "to_metadata" {
  topic_arn            = aws_sns_topic.ingest.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.metadata.arn
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.metadata]
}

# ==============================================================================
# 7. S3 Bucket Notification → SNS ingest
#
# Este recurso CIERRA el loop de ingesta. Vive en este módulo (no en storage)
# porque requiere el ARN del SNS topic — que solo existe después de que
# este módulo crea sus recursos.
#
# filter_prefix + filter_suffix evitan loops infinitos:
#   Sin prefix: cualquier archivo en el bucket (incluyendo outputs del pipeline)
#               dispararía el pipeline de nuevo → loop infinito.
#   Sin suffix: archivos .txt, .jpg, .log dispararían FFmpeg → fallo seguro.
#
# depends_on: S3 valida la notificación publicando un mensaje de prueba en SNS.
# Si la topic policy no existe, la validación falla y el apply lanza error.
# ==============================================================================

resource "aws_s3_bucket_notification" "raw_to_sns" {
  bucket = var.raw_bucket_id

  topic {
    topic_arn     = aws_sns_topic.ingest.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = var.s3_notification_filter_prefix
    filter_suffix = var.s3_notification_filter_suffix
  }

  depends_on = [aws_sns_topic_policy.ingest]
}

# ==============================================================================
# 8. SNS — Topic de alertas al operador
#
# DECISIÓN ARQUITECTÓNICA FINAL: SNS reemplaza a SES para notificaciones.
#
# Flujo: Lambda Notificación → sns:Publish → este topic → email del operador
#
# El operador se suscribe manualmente desde la consola AWS:
#   SNS → Topics → video-pipeline-dev-video-pipeline-alerts
#   → Create subscription → Protocol: Email → tu@email.com
#   → Confirmar el email que llega en segundos
#
# Ventajas sobre SES:
#   - Sin verificación de dominio ni Route53
#   - Sin salir del sandbox de SES
#   - Sin tickets de soporte a AWS
#   - Tiempo de setup: ~30 segundos
#   - El mensaje llega como texto plano — perfecto para alertas operacionales
# ==============================================================================

resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-${var.sns_alerts_topic_suffix}"
  # kms_master_key_id = var.sns_kms_master_key_id <- Esta linea esta maldita

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-${var.sns_alerts_topic_suffix}"
    Purpose = "operator-alerts"
  })
}
