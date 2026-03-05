output "alb_sg_id"           { value = aws_security_group.alb.id }
output "app_sg_id"           { value = aws_security_group.app.id }
output "observability_sg_id" { value = aws_security_group.observability.id }
