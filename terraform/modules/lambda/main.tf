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

resource "aws_iam_role_policy" "incident_analyzer_ssm" {
  name = "ssm-read-webhook-secret"
  role = aws_iam_role.incident_analyzer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = [aws_ssm_parameter.webhook_secret.arn]
    }]
  })
}

# Random shared secret injected into AlertManager config and validated by Lambda.
# Prevents anyone who discovers the Function URL from triggering analysis.
resource "random_password" "webhook_secret" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "webhook_secret" {
  name  = "/${var.project_name}/production/lambda_webhook_secret"
  type  = "SecureString"
  value = random_password.webhook_secret.result
  tags  = var.common_tags
}

# Dead-letter queue: if Lambda fails processing an alert, the event lands here
# so it can be retried or inspected — nothing is silently lost.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project_name}-incident-analyzer-dlq"
  message_retention_seconds = 1209600 # 14 days
  tags                      = var.common_tags
}

resource "aws_iam_role_policy" "sqs_dlq" {
  name = "sqs-dlq"
  role = aws_iam_role.incident_analyzer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [aws_sqs_queue.dlq.arn]
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

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  environment {
    variables = {
      RAGSERVICE_URL         = "https://${var.domain_name}/ai/query"
      NOTIFICATION_TOPIC_ARN = aws_sns_topic.notifications.arn
      # Pass the SSM parameter NAME, not the secret value.
      # Lambda reads the actual secret from SSM at cold-start so it never
      # appears in CloudTrail env-var logs or the Lambda console.
      WEBHOOK_SECRET_PARAM = aws_ssm_parameter.webhook_secret.name
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

# ─── Audit Alerter ────────────────────────────────────────────────────────────
# Triggered by EventBridge when CloudTrail records a dangerous AWS API call.
# Posts to Slack immediately: who did it, what, when, from where.
# No external dependencies — pure stdlib + boto3.

data "archive_file" "audit_alerter" {
  type        = "zip"
  source_dir  = "${path.root}/../apps/lambda/audit_alerter"
  output_path = "${path.module}/audit_alerter.zip"
}

resource "aws_iam_role" "audit_alerter" {
  name = "${var.project_name}-audit-alerter"

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

resource "aws_iam_role_policy_attachment" "audit_alerter_logs" {
  role       = aws_iam_role.audit_alerter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "audit_alerter_ssm" {
  name = "ssm-read-slack-webhook"
  role = aws_iam_role.audit_alerter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/observeops/production/slack_webhook_critical"]
    }]
  })
}

resource "aws_sqs_queue" "audit_alerter_dlq" {
  name                      = "${var.project_name}-audit-alerter-dlq"
  message_retention_seconds = 1209600 # 14 days
  tags                      = var.common_tags
}

resource "aws_iam_role_policy" "audit_alerter_dlq" {
  name = "sqs-dlq"
  role = aws_iam_role.audit_alerter.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [aws_sqs_queue.audit_alerter_dlq.arn]
    }]
  })
}

resource "aws_lambda_function" "audit_alerter" {
  filename         = data.archive_file.audit_alerter.output_path
  function_name    = "${var.project_name}-audit-alerter"
  role             = aws_iam_role.audit_alerter.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.audit_alerter.output_base64sha256
  timeout          = 30

  dead_letter_config {
    target_arn = aws_sqs_queue.audit_alerter_dlq.arn
  }

  tags = var.common_tags
}

# EventBridge rule — fires on destructive or suspicious CloudTrail events.
# CloudTrail management events flow into EventBridge automatically via the default event bus.
# No extra CloudTrail setup required.
resource "aws_cloudwatch_event_rule" "audit_alerts" {
  name        = "${var.project_name}-audit-alerts"
  description = "Fire on destructive or suspicious AWS API calls recorded by CloudTrail"

  event_pattern = jsonencode({
    source      = ["aws.ec2", "aws.dynamodb", "aws.iam", "aws.s3"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = [
        # Database
        "DeleteTable",
        # Compute
        "TerminateInstances", "StopInstances", "RunInstances",
        # Networking
        "DeleteSecurityGroup", "AuthorizeSecurityGroupIngress", "RevokeSecurityGroupIngress",
        # IAM — highest risk category
        "CreateAccessKey", "DeleteAccessKey",
        "AttachUserPolicy", "AttachRolePolicy", "DetachRolePolicy", "CreateRole",
        # Storage
        "DeleteBucket", "PutBucketPolicy"
      ]
    }
  })

  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "audit_alerter" {
  rule      = aws_cloudwatch_event_rule.audit_alerts.name
  target_id = "AuditAlerter"
  arn       = aws_lambda_function.audit_alerter.arn
}

resource "aws_lambda_permission" "audit_eventbridge" {
  statement_id  = "AllowAuditEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.audit_alerter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.audit_alerts.arn
}
