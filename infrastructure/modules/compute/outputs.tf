# ==============================================================================
# modules/compute/outputs.tf
# ==============================================================================

output "ffmpeg_lambda_name" {
  description = "Nombre de la Lambda FFmpeg. Úsalo en CI/CD: aws lambda update-function-code --function-name <valor>"
  value       = aws_lambda_function.ffmpeg.function_name
}

output "ffmpeg_lambda_arn" {
  description = "ARN de la Lambda FFmpeg."
  value       = aws_lambda_function.ffmpeg.arn
}

output "ffmpeg_lambda_role_arn" {
  description = "ARN del rol IAM de la Lambda FFmpeg."
  value       = aws_iam_role.ffmpeg.arn
}

output "metadata_lambda_name" {
  description = "Nombre de la Lambda de metadatos."
  value       = aws_lambda_function.metadata.function_name
}

output "metadata_lambda_arn" {
  description = "ARN de la Lambda de metadatos."
  value       = aws_lambda_function.metadata.arn
}

output "metadata_lambda_role_arn" {
  description = "ARN del rol IAM de la Lambda de metadatos."
  value       = aws_iam_role.metadata.arn
}

output "notification_lambda_name" {
  description = "Nombre de la Lambda de notificación."
  value       = aws_lambda_function.notification.function_name
}

output "notification_lambda_arn" {
  description = "ARN de la Lambda de notificación."
  value       = aws_lambda_function.notification.arn
}

output "notification_lambda_role_arn" {
  description = "ARN del rol IAM de la Lambda de notificación."
  value       = aws_iam_role.notification.arn
}

output "ffmpeg_log_group_name" {
  description = "Nombre del grupo de logs CloudWatch para la Lambda FFmpeg."
  value       = aws_cloudwatch_log_group.ffmpeg.name
}

output "metadata_log_group_name" {
  description = "Nombre del grupo de logs CloudWatch para la Lambda de metadatos."
  value       = aws_cloudwatch_log_group.metadata.name
}

output "notification_log_group_name" {
  description = "Nombre del grupo de logs CloudWatch para la Lambda de notificación."
  value       = aws_cloudwatch_log_group.notification.name
}
