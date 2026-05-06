output "alb_dns_name" {
  description = "ALB DNS name — use this to verify the load balancer is reachable before DNS propagates"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ALB ARN — needed to attach WAF rules or access logs in future"
  value       = aws_lb.main.arn
}

output "target_group_arn" {
  description = "Target group ARN — used if you add auto-scaling later"
  value       = aws_lb_target_group.app.arn
}
