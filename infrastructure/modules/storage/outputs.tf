# ==============================================================================
# modules/storage/outputs.tf
#
# All ARNs, IDs, and names are exported so that downstream modules
# (messaging, compute, etc.) can consume them without knowing the
# internal naming conventions of this module.
# ==============================================================================

# ------------------------------------------------------------------------------
# S3 — Raw Ingestion Bucket
# ------------------------------------------------------------------------------

output "raw_bucket_id" {
  description = "The name (ID) of the raw ingestion S3 bucket."
  value       = aws_s3_bucket.raw.id
}

output "raw_bucket_arn" {
  description = "The ARN of the raw ingestion S3 bucket. Use this when granting IAM permissions or configuring SNS/SQS resource policies."
  value       = aws_s3_bucket.raw.arn
}

output "raw_bucket_domain_name" {
  description = "The bucket-regional domain name of the raw ingestion bucket (useful for CloudFront origins)."
  value       = aws_s3_bucket.raw.bucket_regional_domain_name
}

# ------------------------------------------------------------------------------
# S3 — Processed Output Bucket
# ------------------------------------------------------------------------------

output "processed_bucket_id" {
  description = "The name (ID) of the processed output S3 bucket."
  value       = aws_s3_bucket.processed.id
}

output "processed_bucket_arn" {
  description = "The ARN of the processed output S3 bucket."
  value       = aws_s3_bucket.processed.arn
}

output "processed_bucket_domain_name" {
  description = "The bucket-regional domain name of the processed output bucket."
  value       = aws_s3_bucket.processed.bucket_regional_domain_name
}

# ------------------------------------------------------------------------------
# DynamoDB — Video Metadata Table
# ------------------------------------------------------------------------------

output "dynamodb_table_id" {
  description = "The name (ID) of the DynamoDB video metadata table."
  value       = aws_dynamodb_table.video_metadata.id
}

output "dynamodb_table_arn" {
  description = "The ARN of the DynamoDB video metadata table. Use this in Lambda execution role policies."
  value       = aws_dynamodb_table.video_metadata.arn
}

output "dynamodb_stream_arn" {
  description = "The ARN of the DynamoDB Stream. Wire this into the aws_lambda_event_source_mapping for the Notification Lambda."
  value       = aws_dynamodb_table.video_metadata.stream_arn
}

output "dynamodb_stream_label" {
  description = "A timestamp in ISO 8601 format of when the stream was created."
  value       = aws_dynamodb_table.video_metadata.stream_label
}
