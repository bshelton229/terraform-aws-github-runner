locals {
  lambda_zip = var.config.lambda_zip == null ? "${path.module}/../../../lambdas/functions/webhook/webhook.zip" : var.config.lambda_zip
}

resource "aws_lambda_function" "webhook" {
  s3_bucket         = var.config.lambda_s3_bucket != null ? var.config.lambda_s3_bucket : null
  s3_key            = var.config.lambda_s3_key != null ? var.config.lambda_s3_key : null
  s3_object_version = var.config.lambda_s3_object_version != null ? var.config.lambda_s3_object_version : null
  filename          = var.config.lambda_s3_bucket == null ? local.lambda_zip : null
  source_code_hash  = var.config.lambda_s3_bucket == null ? filebase64sha256(local.lambda_zip) : null
  function_name     = "${var.config.prefix}-webhook"
  role              = aws_iam_role.webhook_lambda.arn
  handler           = "index.directWebhook"
  runtime           = var.config.lambda_runtime
  memory_size       = var.config.lambda_memory_size
  timeout           = var.config.lambda_timeout
  architectures     = [var.config.lambda_architecture]

  environment {
    variables = {
      for k, v in {
        LOG_LEVEL                                = var.config.log_level
        POWERTOOLS_LOGGER_LOG_EVENT              = var.config.log_level == "debug" ? "true" : "false"
        POWERTOOLS_TRACE_ENABLED                 = var.config.tracing_config.mode != null ? true : false
        POWERTOOLS_TRACER_CAPTURE_HTTPS_REQUESTS = var.config.tracing_config.capture_http_requests
        POWERTOOLS_TRACER_CAPTURE_ERROR          = var.config.tracing_config.capture_error
        PARAMETER_GITHUB_APP_WEBHOOK_SECRET      = var.config.github_app_parameters.webhook_secret.name
        REPOSITORY_ALLOW_LIST                    = jsonencode(var.config.repository_white_list)
        SQS_WORKFLOW_JOB_QUEUE                   = try(var.config.sqs_workflow_job_queue.id, null)
        PARAMETER_RUNNER_MATCHER_CONFIG_PATH     = var.config.ssm_parameter_runner_matcher_config.name
      } : k => v if v != null
    }
  }

  dynamic "vpc_config" {
    for_each = var.config.lambda_subnet_ids != null && var.config.lambda_security_group_ids != null ? [true] : []
    content {
      security_group_ids = var.config.lambda_security_group_ids
      subnet_ids         = var.config.lambda_subnet_ids
    }
  }

  tags = merge(var.config.tags, var.config.lambda_tags)

  dynamic "tracing_config" {
    for_each = var.config.tracing_config.mode != null ? [true] : []
    content {
      mode = var.config.tracing_config.mode
    }
  }

  lifecycle {
    replace_triggered_by = [null_resource.ssm_parameter_runner_matcher_config, null_resource.github_app_parameters]
  }
}

resource "aws_cloudwatch_log_group" "webhook" {
  name              = "/aws/lambda/${aws_lambda_function.webhook.function_name}"
  retention_in_days = var.config.logging_retention_in_days
  kms_key_id        = var.config.logging_kms_key_id
  tags              = var.config.tags
}

resource "aws_lambda_permission" "webhook" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = var.config.api_gw_source_arn
  lifecycle {
    replace_triggered_by = [null_resource.ssm_parameter_runner_matcher_config, null_resource.github_app_parameters]
  }
}

resource "null_resource" "github_app_parameters" {
  triggers = {
    github_app_webhook_secret = var.config.github_app_parameters.webhook_secret.name
  }
}

data "aws_iam_policy_document" "lambda_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "webhook_lambda" {
  name                 = "${var.config.prefix}-direct-webhook-lambda-role"
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume_role_policy.json
  path                 = var.config.role_path
  permissions_boundary = var.config.role_permissions_boundary
  tags                 = var.config.tags
}

resource "aws_iam_role_policy" "webhook_logging" {
  name = "logging-policy"
  role = aws_iam_role.webhook_lambda.name
  policy = templatefile("${path.module}/../policies/lambda-cloudwatch.json", {
    log_group_arn = aws_cloudwatch_log_group.webhook.arn
  })
}

resource "aws_iam_role_policy_attachment" "webhook_vpc_execution_role" {
  count      = length(var.config.lambda_subnet_ids) > 0 ? 1 : 0
  role       = aws_iam_role.webhook_lambda.name
  policy_arn = "arn:${var.config.aws_partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "webhook_sqs" {
  name = "publish-sqs-policy"
  role = aws_iam_role.webhook_lambda.name

  policy = templatefile("${path.module}/../policies/lambda-publish-sqs-policy.json", {
    sqs_resource_arns = jsonencode(var.config.sqs_job_queues_arns)
    kms_key_arn       = var.config.kms_key_arn != null ? var.config.kms_key_arn : ""
  })
}

resource "aws_iam_role_policy" "webhook_workflow_job_sqs" {
  count = var.config.sqs_workflow_job_queue != null ? 1 : 0
  name  = "publish-workflow-job-sqs-policy"
  role  = aws_iam_role.webhook_lambda.name

  policy = templatefile("${path.module}/../policies/lambda-publish-sqs-policy.json", {
    sqs_resource_arns = jsonencode([var.config.sqs_workflow_job_queue.arn])
    kms_key_arn       = var.config.kms_key_arn != null ? var.config.kms_key_arn : ""
  })
}

resource "aws_iam_role_policy" "webhook_ssm" {
  name = "publish-ssm-policy"
  role = aws_iam_role.webhook_lambda.name

  policy = templatefile("${path.module}/../policies/lambda-ssm.json", {
    resource_arns = jsonencode([var.config.github_app_parameters.webhook_secret.arn, var.config.ssm_parameter_runner_matcher_config.arn])
  })
}

resource "aws_iam_role_policy" "xray" {
  count  = var.config.tracing_config.mode != null ? 1 : 0
  name   = "xray-policy"
  policy = data.aws_iam_policy_document.lambda_xray[0].json
  role   = aws_iam_role.webhook_lambda.name
}