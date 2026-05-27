output "function_url"       { value = aws_lambda_function_url.incident_analyzer.function_url }
output "sns_topic_arn"      { value = aws_sns_topic.notifications.arn }
output "function_name"      { value = aws_lambda_function.incident_analyzer.function_name }
