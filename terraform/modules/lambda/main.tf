# ─── Lambda functions ─────────────────────────────────────────────────────────
# Two small functions, both about seeing what the stack cannot see about itself:
#
#   external_probe   asks, from OUTSIDE the VPC, whether the public URL answers.
#   audit_alerter    reports AWS changes that were not made by Terraform.
#
# Both post to the critical Slack channel, reading its webhook from SSM at run
# time so the secret is never in the function's configuration.
#
# An earlier "incident analyzer" function lived here. Nothing called its URL, its
# SNS topic had no subscriber, and its five-minute schedule made one LLM call per
# run to write an answer nobody read. It duplicated the alert autopilot and is
# replaced by the probe, which does the one job nothing else here did.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  slack_param_name = "/${var.project_name}/production/slack_webhook_critical"
  slack_param_arn  = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.slack_param_name}"

  lambda_assume_role = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ─── Outside-in probe ─────────────────────────────────────────────────────────
data "archive_file" "external_probe" {
  type        = "zip"
  source_dir  = "${path.root}/../apps/lambda/external_probe"
  output_path = "${path.module}/external_probe.zip"
}

# The log group is created here, with a retention period, instead of letting
# Lambda create it on first run. A group Lambda creates never expires and is not
# in Terraform state, so `terraform destroy` leaves it behind: the previous
# function's group was found months later holding 11 MB that nothing would ever
# have deleted.
resource "aws_cloudwatch_log_group" "external_probe" {
  name              = "/aws/lambda/${var.project_name}-external-probe"
  retention_in_days = 14
  tags              = var.common_tags
}

resource "aws_iam_role" "external_probe" {
  name               = "${var.project_name}-external-probe"
  assume_role_policy = local.lambda_assume_role
  tags               = var.common_tags
}

resource "aws_iam_role_policy" "external_probe" {
  name = "logs-and-slack-webhook"
  role = aws_iam_role.external_probe.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Write to its own log group and nothing else. The AWS managed
        # "basic execution" policy allows writing to any group in the account.
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.external_probe.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [local.slack_param_arn]
      }
    ]
  })
}

resource "aws_lambda_function" "external_probe" {
  filename         = data.archive_file.external_probe.output_path
  function_name    = "${var.project_name}-external-probe"
  role             = aws_iam_role.external_probe.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.13"
  source_code_hash = data.archive_file.external_probe.output_base64sha256

  # Worst case is three checks timing out twice with a pause between:
  # (3 x 5 s) + 20 s + (3 x 5 s) = 50 s.
  timeout = 60

  environment {
    variables = {
      PUBLIC_BASE_URL     = var.public_base_url
      SLACK_WEBHOOK_PARAM = local.slack_param_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.external_probe, aws_iam_role_policy.external_probe]

  tags = var.common_tags
}

# A scheduled invocation is asynchronous, and Lambda retries a failed async
# invocation twice by default. A failed probe is a result, not a fault to retry:
# the next scheduled run is the retry.
resource "aws_lambda_function_event_invoke_config" "external_probe" {
  function_name          = aws_lambda_function.external_probe.function_name
  maximum_retry_attempts = 0
}

# Created DISABLED. During `terraform apply` the site does not exist yet, so an
# armed probe would spend the first fifteen minutes reporting an outage that is
# simply a build in progress, and an alarm that cries during every planned change
# teaches people to ignore it. scripts/infra-up.sh enables the rule after the
# first deploy has passed its smoke tests.
resource "aws_cloudwatch_event_rule" "external_probe" {
  name                = "${var.project_name}-external-probe"
  description         = "Probe the public URL from outside the VPC every five minutes"
  schedule_expression = "rate(5 minutes)"
  state               = "DISABLED"
  tags                = var.common_tags

  lifecycle {
    ignore_changes = [state] # armed and disarmed outside Terraform, on purpose
  }
}

resource "aws_cloudwatch_event_target" "external_probe" {
  rule      = aws_cloudwatch_event_rule.external_probe.name
  target_id = "ExternalProbe"
  arn       = aws_lambda_function.external_probe.arn
}

resource "aws_lambda_permission" "external_probe" {
  statement_id  = "AllowEventBridgeSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.external_probe.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.external_probe.arn
}

# ─── Audit alerter ────────────────────────────────────────────────────────────
# Infrastructure here is supposed to change through Terraform. This function
# tells Slack when it changes any other way: who, what, when, from which address.
#
# Three things about how it works that are easy to get wrong (this module got
# all three wrong for five months, during which the function was never invoked
# once; its log group did not even exist):
#
#   1. EventBridge only receives "AWS API Call via CloudTrail" events if the
#      account has a CloudTrail TRAIL. The 90-day event history that every
#      account gets for free is not enough. The trail is account-level and
#      long-lived, so it is created by scripts/bootstrap-aws-account.sh, not here.
#
#   2. IAM is a global service. Its API calls are recorded in us-east-1 and reach
#      EventBridge only there, so a rule in this region never sees them. The IAM
#      event names are kept in the pattern and in the handler for when a
#      forwarding rule exists in us-east-1; today they are inert. See the README.
#
#   3. Terraform itself makes these calls on every apply and destroy. Reporting
#      them buries the one event that matters, so calls made by Terraform's AWS
#      provider are excluded by user agent. A user agent is chosen by the caller
#      and can be forged; the stronger form is to run Terraform under its own
#      role and exclude that role's ARN.

data "archive_file" "audit_alerter" {
  type        = "zip"
  source_dir  = "${path.root}/../apps/lambda/audit_alerter"
  output_path = "${path.module}/audit_alerter.zip"
}

resource "aws_cloudwatch_log_group" "audit_alerter" {
  name              = "/aws/lambda/${var.project_name}-audit-alerter"
  retention_in_days = 30
  tags              = var.common_tags
}

resource "aws_iam_role" "audit_alerter" {
  name               = "${var.project_name}-audit-alerter"
  assume_role_policy = local.lambda_assume_role
  tags               = var.common_tags
}

# If the function fails (Slack down, parameter missing) the event is kept here
# for 14 days instead of being dropped after Lambda's retries.
resource "aws_sqs_queue" "audit_alerter_dlq" {
  name                      = "${var.project_name}-audit-alerter-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.common_tags
}

resource "aws_iam_role_policy" "audit_alerter" {
  name = "logs-slack-webhook-dlq"
  role = aws_iam_role.audit_alerter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.audit_alerter.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [local.slack_param_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.audit_alerter_dlq.arn]
      }
    ]
  })
}

resource "aws_lambda_function" "audit_alerter" {
  filename         = data.archive_file.audit_alerter.output_path
  function_name    = "${var.project_name}-audit-alerter"
  role             = aws_iam_role.audit_alerter.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.13"
  source_code_hash = data.archive_file.audit_alerter.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      SLACK_WEBHOOK_PARAM = local.slack_param_name
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.audit_alerter_dlq.arn
  }

  depends_on = [aws_cloudwatch_log_group.audit_alerter, aws_iam_role_policy.audit_alerter]

  tags = var.common_tags
}

resource "aws_cloudwatch_event_rule" "audit_alerts" {
  name        = "${var.project_name}-audit-alerts"
  description = "Destructive or sensitive AWS API calls that were not made by Terraform"

  event_pattern = jsonencode({
    source      = ["aws.ec2", "aws.dynamodb", "aws.s3", "aws.iam"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = [
        # Database
        "DeleteTable",
        # Compute
        "TerminateInstances", "StopInstances", "RunInstances",
        # Network: a new inbound rule is how a private service becomes public
        "DeleteSecurityGroup", "AuthorizeSecurityGroupIngress", "RevokeSecurityGroupIngress",
        # Storage
        "DeleteBucket", "PutBucketPolicy",
        # IAM (inert in this region today, see point 2 above)
        "CreateAccessKey", "DeleteAccessKey",
        "AttachUserPolicy", "AttachRolePolicy", "DetachRolePolicy", "CreateRole",
      ]
      # Point 3 above: leave out what Terraform's AWS provider did.
      userAgent = [{ "anything-but" = { prefix = "APN/1.0 HashiCorp" } }]
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
