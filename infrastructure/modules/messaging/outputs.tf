# ==============================================================================
# modules/messaging/outputs.tf
#
# Exporta todos los ARNs y URLs que necesitan los módulos compute y dev.
# Estos son los valores computados por AWS en tiempo de apply — no se inventan.
# ==============================================================================

# ------------------------------------------------------------------------------
# SNS — Topic de ingesta
# ------------------------------------------------------------------------------

output "sns_ingest_topic_arn" {
  description = "ARN del SNS topic de fan-out de ingesta."
  value       = aws_sns_topic.ingest.arn
}

output "sns_ingest_topic_name" {
  description = "Nombre del SNS topic de ingesta."
  value       = aws_sns_topic.ingest.name
}

# ------------------------------------------------------------------------------
# SNS — Topic de alertas
#
# Este ARN es el que necesita la Lambda de Notificación para publicar.
# También se usa en la policy IAM del rol de esa Lambda (sns:Publish).
# ------------------------------------------------------------------------------

output "sns_alerts_topic_arn" {
  description = "ARN del SNS topic de alertas. La Lambda Notificación publica aquí. El operador se suscribe manualmente con su email."
  value       = aws_sns_topic.alerts.arn
}

output "sns_alerts_topic_name" {
  description = "Nombre del SNS topic de alertas. Úsalo para encontrarlo en la consola y suscribir tu email."
  value       = aws_sns_topic.alerts.name
}

# ------------------------------------------------------------------------------
# SQS — Cola FFmpeg
# ------------------------------------------------------------------------------

output "ffmpeg_queue_arn" {
  description = "ARN de la cola SQS de FFmpeg. Usado en aws_lambda_event_source_mapping."
  value       = aws_sqs_queue.ffmpeg.arn
}

output "ffmpeg_queue_url" {
  description = "URL de la cola SQS de FFmpeg. Usado por la Lambda para eliminar mensajes tras procesarlos."
  value       = aws_sqs_queue.ffmpeg.id
}

output "ffmpeg_dlq_arn" {
  description = "ARN del DLQ de FFmpeg. Conéctalo a una alarma de CloudWatch para alertas de fallos."
  value       = aws_sqs_queue.ffmpeg_dlq.arn
}

output "ffmpeg_dlq_url" {
  description = "URL del DLQ de FFmpeg. Úsalo para inspeccionar o hacer replay de mensajes fallidos."
  value       = aws_sqs_queue.ffmpeg_dlq.id
}

# ------------------------------------------------------------------------------
# SQS — Cola metadata
# ------------------------------------------------------------------------------

output "metadata_queue_arn" {
  description = "ARN de la cola SQS de metadatos. Usado en aws_lambda_event_source_mapping."
  value       = aws_sqs_queue.metadata.arn
}

output "metadata_queue_url" {
  description = "URL de la cola SQS de metadatos."
  value       = aws_sqs_queue.metadata.id
}

output "metadata_dlq_arn" {
  description = "ARN del DLQ de metadatos."
  value       = aws_sqs_queue.metadata_dlq.arn
}

output "metadata_dlq_url" {
  description = "URL del DLQ de metadatos."
  value       = aws_sqs_queue.metadata_dlq.id
}
