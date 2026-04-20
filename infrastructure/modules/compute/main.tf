# ==============================================================================
# modules/compute/main.tf
#
# Responsabilidad: roles IAM, funciones Lambda, log groups CloudWatch,
# y Event Source Mappings que conectan SQS/DynamoDB Stream con las Lambdas.
#
# Sin CloudWatch Alarms. Sin Dashboards. Solo infraestructura de ejecución.
# ==============================================================================

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
      Module      = "compute"
    },
    var.additional_tags
  )

  ffmpeg_function_name       = "${local.name_prefix}-${var.ffmpeg_lambda_suffix}"
  metadata_function_name     = "${local.name_prefix}-${var.metadata_lambda_suffix}"
  notification_function_name = "${local.name_prefix}-${var.notification_lambda_suffix}"
}

# ==============================================================================
# ZIP placeholder
#
# Terraform requiere un paquete válido para crear la Lambda.
# Este handler mínimo es el placeholder — el código real lo despliega
# CI/CD con `aws lambda update-function-code` después del apply.
# ==============================================================================

data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "/tmp/lambda_placeholder.zip"

  source {
    content  = <<-PYTHON
      import json

      def handler(event, context):
          print(json.dumps({"message": "Placeholder. Deploy real code via CI/CD.", "event": event}))
          return {"statusCode": 200}
    PYTHON
    filename = "handler.py"
  }
}

# ==============================================================================
# IAM — Trust policy compartida entre los tres roles
# "¿Quién puede asumir este rol?" → solo Lambda Service
# ==============================================================================

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    sid     = "AllowLambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ==============================================================================
# Lambda FFmpeg — IAM + Log Group + Function + ESM
# ==============================================================================

resource "aws_iam_role" "ffmpeg" {
  name               = "${local.ffmpeg_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = merge(local.common_tags, { Name = "${local.ffmpeg_function_name}-role" })
}

resource "aws_iam_role_policy_attachment" "ffmpeg_basic" {
  role       = aws_iam_role.ffmpeg.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "ffmpeg_custom" {
  name = "${local.ffmpeg_function_name}-policy"
  role = aws_iam_role.ffmpeg.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadRawVideo"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:HeadObject"]
        Resource = "${var.raw_bucket_arn}/*"
      },
      {
        Sid      = "WriteProcessedVideo"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:PutObjectTagging"]
        Resource = "${var.processed_bucket_arn}/*"
      },
      {
        Sid    = "UpdateVideoStatus"
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem", "dynamodb:Query"]
        Resource = [
          var.dynamodb_table_arn,
          "${var.dynamodb_table_arn}/index/*"
        ]
      },
      {
        Sid      = "ConsumeSQSQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = var.ffmpeg_queue_arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "ffmpeg" {
  name              = "/aws/lambda/${local.ffmpeg_function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = merge(local.common_tags, { Name = "/aws/lambda/${local.ffmpeg_function_name}" })
}

resource "aws_lambda_function" "ffmpeg" {
  function_name = local.ffmpeg_function_name
  description   = "Transcodifica videos con FFmpeg. Lee de S3 raw, escribe en S3 processed y DynamoDB."
  role          = aws_iam_role.ffmpeg.arn

  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256
  handler          = "handler.handler"
  runtime          = var.lambda_runtime
  architectures    = [var.lambda_architecture]

  # Límites físicos configurables por entorno
  memory_size = var.ffmpeg_lambda_memory_mb
  timeout     = var.ffmpeg_lambda_timeout_seconds

  environment {
    variables = {
      ENVIRONMENT      = var.environment
      PROCESSED_BUCKET = var.processed_bucket_id
      DYNAMODB_TABLE   = var.dynamodb_table_id
      LOG_LEVEL        = var.environment == "prod" ? "WARNING" : "DEBUG"
      FFMPEG_PRESET    = var.environment == "prod" ? "medium" : "ultrafast"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.ffmpeg,
    aws_iam_role_policy_attachment.ffmpeg_basic,
    aws_iam_role_policy.ffmpeg_custom,
  ]

  tags = merge(local.common_tags, { Name = local.ffmpeg_function_name })
}

resource "aws_lambda_event_source_mapping" "ffmpeg" {
  event_source_arn = var.ffmpeg_queue_arn
  function_name    = aws_lambda_function.ffmpeg.arn
  enabled          = true

  # 1 mensaje = 1 video = 1 Lambda. FFmpeg usa toda la memoria asignada —
  # varios videos en paralelo dentro de la misma invocación causarían OOM.
  batch_size = var.ffmpeg_esm_batch_size

  # Cap duro de concurrencia. Sin este límite, 100 uploads simultáneos
  # podrían lanzar 100 Lambdas de 3 GB → factura inesperada en dev.
  scaling_config {
    maximum_concurrency = var.ffmpeg_esm_max_concurrency
  }

  maximum_batching_window_in_seconds = 0

  # Solo los mensajes fallidos van al DLQ, no todo el batch.
  function_response_types = ["ReportBatchItemFailures"]
}

# ==============================================================================
# Lambda Metadata — IAM + Log Group + Function + ESM
# ==============================================================================

resource "aws_iam_role" "metadata" {
  name               = "${local.metadata_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = merge(local.common_tags, { Name = "${local.metadata_function_name}-role" })
}

resource "aws_iam_role_policy_attachment" "metadata_basic" {
  role       = aws_iam_role.metadata.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "metadata_custom" {
  name = "${local.metadata_function_name}-policy"
  role = aws_iam_role.metadata.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadRawVideo"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:HeadObject"]
        Resource = "${var.raw_bucket_arn}/*"
      },
      {
        Sid    = "WriteMetadata"
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = [
          var.dynamodb_table_arn,
          "${var.dynamodb_table_arn}/index/*"
        ]
      },
      {
        Sid      = "ConsumeSQSQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = var.metadata_queue_arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "metadata" {
  name              = "/aws/lambda/${local.metadata_function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = merge(local.common_tags, { Name = "/aws/lambda/${local.metadata_function_name}" })
}

resource "aws_lambda_function" "metadata" {
  function_name = local.metadata_function_name
  description   = "Extrae metadatos de video (codec, resolución, FPS, duración) y los escribe en DynamoDB."
  role          = aws_iam_role.metadata.arn

  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256
  handler          = "handler.handler"
  runtime          = var.lambda_runtime
  architectures    = [var.lambda_architecture]

  memory_size = var.metadata_lambda_memory_mb
  timeout     = var.metadata_lambda_timeout_seconds

  environment {
    variables = {
      ENVIRONMENT    = var.environment
      DYNAMODB_TABLE = var.dynamodb_table_id
      LOG_LEVEL      = var.environment == "prod" ? "WARNING" : "DEBUG"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.metadata,
    aws_iam_role_policy_attachment.metadata_basic,
    aws_iam_role_policy.metadata_custom,
  ]

  tags = merge(local.common_tags, { Name = local.metadata_function_name })
}

resource "aws_lambda_event_source_mapping" "metadata" {
  event_source_arn = var.metadata_queue_arn
  function_name    = aws_lambda_function.metadata.arn
  enabled          = true

  batch_size = var.metadata_esm_batch_size

  scaling_config {
    maximum_concurrency = var.metadata_esm_max_concurrency
  }

  # 5s de ventana: acumula hasta batch_size mensajes antes de invocar.
  # Metadata es ligero — procesar varios a la vez reduce costo de invocaciones.
  maximum_batching_window_in_seconds = 5

  function_response_types = ["ReportBatchItemFailures"]
}

# ==============================================================================
# Lambda Notification — IAM + Log Group + Function + ESM
# Publica en SNS alerts topic. Sin SES.
# ==============================================================================

resource "aws_iam_role" "notification" {
  name               = "${local.notification_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = merge(local.common_tags, { Name = "${local.notification_function_name}-role" })
}

resource "aws_iam_role_policy_attachment" "notification_basic" {
  role       = aws_iam_role.notification.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "notification_custom" {
  name = "${local.notification_function_name}-policy"
  role = aws_iam_role.notification.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadDynamoDBStream"
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream",
          "dynamodb:ListStreams"
        ]
        Resource = [
          var.dynamodb_stream_arn,
          var.dynamodb_table_arn
        ]
      },
      {
        Sid      = "PublishToAlertsTopic"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.alerts_topic_arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "notification" {
  name              = "/aws/lambda/${local.notification_function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = merge(local.common_tags, { Name = "/aws/lambda/${local.notification_function_name}" })
}

resource "aws_lambda_function" "notification" {
  function_name = local.notification_function_name
  description   = "Lee el DynamoDB Stream y publica en SNS cuando cambia processing_status."
  role          = aws_iam_role.notification.arn

  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256
  handler          = "handler.handler"
  runtime          = var.lambda_runtime
  architectures    = [var.lambda_architecture]

  memory_size = var.notification_lambda_memory_mb
  timeout     = var.notification_lambda_timeout_seconds

  environment {
    variables = {
      ENVIRONMENT      = var.environment
      DYNAMODB_TABLE   = var.dynamodb_table_id
      SNS_ALERTS_TOPIC = var.alerts_topic_arn
      LOG_LEVEL        = var.environment == "prod" ? "WARNING" : "DEBUG"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.notification,
    aws_iam_role_policy_attachment.notification_basic,
    aws_iam_role_policy.notification_custom,
  ]

  tags = merge(local.common_tags, { Name = local.notification_function_name })
}

resource "aws_lambda_event_source_mapping" "notification" {
  event_source_arn  = var.dynamodb_stream_arn
  function_name     = aws_lambda_function.notification.arn
  enabled           = true
  starting_position = var.notification_esm_starting_position

  batch_size             = var.notification_esm_batch_size
  maximum_retry_attempts = 3

  # Si el batch falla, lo divide en dos mitades y reintenta.
  # Aísla el registro corrupto sin bloquear el shard completo.
  bisect_batch_on_function_error = true

  # Solo invoca cuando el ítem nuevo tiene processing_status.
  # Sin esto: cualquier write en DynamoDB (timestamps, retry_count, etc.)
  # dispara una notificación → spam al operador.
  filter_criteria {
    filter {
      pattern = jsonencode({
        dynamodb = {
          NewImage = {
            processing_status = { S = [{ exists = true }] }
          }
        }
      })
    }
  }

  function_response_types = ["ReportBatchItemFailures"]
}
