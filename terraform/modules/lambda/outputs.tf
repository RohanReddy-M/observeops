output "external_probe_function_name" { value = aws_lambda_function.external_probe.function_name }
output "external_probe_rule_name" { value = aws_cloudwatch_event_rule.external_probe.name }
output "audit_alerter_function_name" { value = aws_lambda_function.audit_alerter.function_name }
output "audit_alerter_dlq_arn" { value = aws_sqs_queue.audit_alerter_dlq.arn }
