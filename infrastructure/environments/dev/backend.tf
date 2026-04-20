# ==============================================================================
# environments/dev/backend.tf
#
# Le dice a Terraform dónde guardar el state (S3) y cómo hacer locking
# para evitar applies simultáneos (DynamoDB).
#
# Los valores de bucket y dynamodb_table deben coincidir exactamente
# con los nombres que creó backend-setup. Verifícalos con:
#   cd infrastructure/backend-setup && terraform output
# ==============================================================================

terraform {
  backend "s3" {
    bucket         = "video-pipeline-tf-state-edgar-alfaro-2026"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "video-pipeline-tf-locks"
  }
}
