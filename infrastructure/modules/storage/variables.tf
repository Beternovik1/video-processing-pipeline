# ==============================================================================
# modules/storage/variables.tf
# Input variables for the storage module.
# All resources are named using: {project}-{environment}-{resource_suffix}
# ==============================================================================

variable "project" {
  description = "Project name used as a prefix for all resource names and tags."
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "The environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region where resources will be deployed."
  type        = string
  default     = "us-east-1"
}

# ------------------------------------------------------------------------------
# S3 — Ingestion Bucket
# ------------------------------------------------------------------------------

variable "raw_bucket_suffix" {
  description = "Suffix appended to the project-environment prefix for the raw ingestion bucket."
  type        = string
  default     = "raw-ingestion"
}

variable "raw_bucket_force_destroy" {
  description = "Allow Terraform to destroy the raw bucket even when it contains objects. Set to false in prod."
  type        = bool
  default     = false
}

variable "raw_bucket_lifecycle_expiration_days" {
  description = "Number of days after which raw objects are permanently deleted. 0 disables the rule."
  type        = number
  default     = 90

  validation {
    condition     = var.raw_bucket_lifecycle_expiration_days >= 0
    error_message = "Lifecycle expiration days must be 0 (disabled) or a positive integer."
  }
}

# ------------------------------------------------------------------------------
# S3 — Processed Bucket
# ------------------------------------------------------------------------------

variable "processed_bucket_suffix" {
  description = "Suffix appended to the project-environment prefix for the processed output bucket."
  type        = string
  default     = "processed-output"
}

variable "processed_bucket_force_destroy" {
  description = "Allow Terraform to destroy the processed bucket even when it contains objects. Set to false in prod."
  type        = bool
  default     = false
}

variable "processed_bucket_lifecycle_expiration_days" {
  description = "Number of days after which processed objects are permanently deleted. 0 disables the rule."
  type        = number
  default     = 365

  validation {
    condition     = var.processed_bucket_lifecycle_expiration_days >= 0
    error_message = "Lifecycle expiration days must be 0 (disabled) or a positive integer."
  }
}

# ------------------------------------------------------------------------------
# DynamoDB — Video Metadata Table
# ------------------------------------------------------------------------------

variable "dynamodb_table_suffix" {
  description = "Suffix appended to the project-environment prefix for the DynamoDB table name."
  type        = string
  default     = "video-metadata"
}

variable "dynamodb_billing_mode" {
  description = "DynamoDB billing mode. PAY_PER_REQUEST recommended for dev; PROVISIONED for steady-state prod traffic."
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.dynamodb_billing_mode)
    error_message = "dynamodb_billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "dynamodb_read_capacity" {
  description = "Read capacity units. Only used when billing_mode is PROVISIONED."
  type        = number
  default     = 5
}

variable "dynamodb_write_capacity" {
  description = "Write capacity units. Only used when billing_mode is PROVISIONED."
  type        = number
  default     = 5
}

variable "dynamodb_point_in_time_recovery" {
  description = "Enable DynamoDB Point-in-Time Recovery (PITR). Strongly recommended for prod."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Tags
# ------------------------------------------------------------------------------

variable "additional_tags" {
  description = "Additional tags to merge with the module's default tags. Useful for cost allocation."
  type        = map(string)
  default     = {}
}
