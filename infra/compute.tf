############ Authentication ############
resource "aws_cognito_user_pool" "main" {
  name                     = "${local.name}-users"
  auto_verified_attributes = ["email"]
  username_attributes      = ["email"]
  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }
}
resource "aws_cognito_user_group" "roles" {
  for_each     = toset(["student", "tutor", "admin"])
  name         = each.key
  user_pool_id = aws_cognito_user_pool.main.id
}
resource "aws_cognito_user_pool_client" "web" {
  name                          = "${local.name}-web"
  user_pool_id                  = aws_cognito_user_pool.main.id
  generate_secret               = false
  explicit_auth_flows           = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  id_token_validity             = 4
  access_token_validity         = 4
  token_validity_units {
    id_token     = "hours"
    access_token = "hours"
  }
}

############ Lambda code + IAM ############
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../build/lambda" # produced by scripts/build.sh
  output_path = "${path.module}/../build/lambda.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${local.name}-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}
resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}
resource "aws_iam_role_policy" "lambda" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject"], Resource = "${aws_s3_bucket.uploads.arn}/*" },
      { Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"], Resource = aws_kms_key.main.arn },
      { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = aws_rds_cluster.db.master_user_secret[0].secret_arn },
      { Effect = "Allow", Action = "sqs:SendMessage", Resource = [aws_sqs_queue.marking.arn, aws_sqs_queue.notify.arn] },
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = [aws_sqs_queue.marking.arn, aws_sqs_queue.notify.arn] },
      { Effect = "Allow", Action = "ses:SendEmail", Resource = "*" }
    ]
  })
}

locals {
  lambda_env = {
    DB_HOST          = aws_db_proxy.db.endpoint
    DB_NAME          = "exams"
    DB_USER          = "examadmin"
    DB_SECRET_ARN    = aws_rds_cluster.db.master_user_secret[0].secret_arn
    UPLOAD_BUCKET    = aws_s3_bucket.uploads.id
    MARKING_QUEUE_URL = aws_sqs_queue.marking.url
    NOTIFY_QUEUE_URL = aws_sqs_queue.notify.url
    SES_SENDER       = var.ses_sender
    TUTOR_EMAIL      = var.tutor_email
  }
  functions = {
    api      = { handler = "api.handler", timeout = 15, memory = 512 }
    marker   = { handler = "marker.handler", timeout = 30, memory = 256 }
    notifier = { handler = "notifier.handler", timeout = 30, memory = 256 }
  }
}

resource "aws_cloudwatch_log_group" "fn" {
  for_each          = local.functions
  name              = "/aws/lambda/${local.name}-${each.key}"
  retention_in_days = 30
}

resource "aws_lambda_function" "fn" {
  for_each         = local.functions
  function_name    = "${local.name}-${each.key}"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = each.value.handler
  timeout          = each.value.timeout
  memory_size      = each.value.memory
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.app[*].id # both AZs
    security_group_ids = [aws_security_group.lambda.id]
  }
  tracing_config { mode = "Active" }
  environment { variables = local.lambda_env }

  depends_on = [aws_cloudwatch_log_group.fn, aws_iam_role_policy_attachment.lambda_vpc, aws_db_proxy_target.db]
}

resource "aws_lambda_event_source_mapping" "marker" {
  event_source_arn        = aws_sqs_queue.marking.arn
  function_name           = aws_lambda_function.fn["marker"].arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
  scaling_config { maximum_concurrency = 20 } # cap DB pressure from the workers
}
resource "aws_lambda_event_source_mapping" "notifier" {
  event_source_arn        = aws_sqs_queue.notify.arn
  function_name           = aws_lambda_function.fn["notifier"].arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
  scaling_config { maximum_concurrency = 5 }
}

############ API Gateway (HTTP API, JWT authorizer) ############
resource "aws_apigatewayv2_api" "api" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"
}
resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.api.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  jwt_configuration {
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
    audience = [aws_cognito_user_pool_client.web.id]
  }
}
resource "aws_apigatewayv2_integration" "api" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.fn["api"].invoke_arn
  payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "protected" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "ANY /api/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}
resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /api/health"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_burst_limit = 5000
    throttling_rate_limit  = 2500
  }
}
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["api"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}
