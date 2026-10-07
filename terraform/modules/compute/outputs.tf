output "app_server_private_ip" { value = aws_instance.app.private_ip }
output "obs_server_private_ip" { value = aws_instance.observability.private_ip }
output "app_instance_id" { value = aws_instance.app.id }
output "obs_instance_id" { value = aws_instance.observability.id }
output "grafana_admin_password_parameter" { value = aws_ssm_parameter.grafana_admin_password.name }
