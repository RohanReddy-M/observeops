output "function_url" { value = aws_lambda_function_url.incident_analyzer.function_url }
output "sns_topic_arn" { value = aws_sns_topic.notifications.arn }
output "function_name" { value = aws_lambda_function.incident_analyzer.function_name }
output "dlq_arn" { value = aws_sqs_queue.dlq.arn }
output "webhook_secret_ssm_key" { value = aws_ssm_parameter.webhook_secret.name }
