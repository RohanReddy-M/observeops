data "archive_file" "incident_analyzer" {
  type        = "zip"
  source_dir  = "${path.root}/../apps/lambda/incident_analyzer"
  output_path = "${path.module}/incident_analyzer.zip"
}

resource "aws_iam_role" "incident_analyzer" {
  name = "${var.project_name}-incident-analyzer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.incident_analyzer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "sns_publish" {
  name = "sns-publish"
  role = aws_iam_role.incident_analyzer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = [aws_sns_topic.notifications.arn]
    }]
  })
}

resource "aws_lambda_function" "incident_analyzer" {
  filename         = data.archive_file.incident_analyzer.output_path
  function_name    = "${var.project_name}-incident-analyzer"
  role             = aws_iam_role.incident_analyzer.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.incident_analyzer.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      RAGSERVICE_URL         = "https://${var.domain_name}/ai/query"
      NOTIFICATION_TOPIC_ARN = aws_sns_topic.notifications.arn
    }
  }

  tags = var.common_tags
}

# Public HTTPS endpoint — AlertManager posts here directly, no API Gateway needed
resource "aws_lambda_function_url" "incident_analyzer" {
  function_name      = aws_lambda_function.incident_analyzer.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["https://${var.domain_name}"]
    allow_methods = ["POST"]
  }
}

# Scheduled health check every 5 minutes via EventBridge
resource "aws_cloudwatch_event_rule" "health_check" {
  name                = "${var.project_name}-health-check"
  schedule_expression = "rate(5 minutes)"
  tags                = var.common_tags
}

resource "aws_cloudwatch_event_target" "health_check" {
  rule      = aws_cloudwatch_event_rule.health_check.name
  target_id = "IncidentAnalyzer"
  arn       = aws_lambda_function.incident_analyzer.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.incident_analyzer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.health_check.arn
}

# SNS topic — receives alert analyses, can fan out to email/Slack/PagerDuty
resource "aws_sns_topic" "notifications" {
  name = "${var.project_name}-notifications"
  tags = var.common_tags
}

# Store Lambda URL in SSM so deploy.sh can inject it into AlertManager config
resource "aws_ssm_parameter" "lambda_url" {
  name  = "/${var.project_name}/production/lambda_incident_url"
  type  = "String"
  value = aws_lambda_function_url.incident_analyzer.function_url
  tags  = var.common_tags
}
