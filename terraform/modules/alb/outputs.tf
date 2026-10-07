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

output "route53_name_servers" {
  description = "NS records for the hosted zone (empty when no domain is configured). They must be set at the domain registrar whenever the zone is created."
  value       = flatten(aws_route53_zone.main[*].name_servers)
}

output "public_url" {
  description = "Base URL the platform is reachable on: https://<domain> when a domain is configured, otherwise http://<ALB DNS name>."
  value       = local.has_domain ? "https://${var.domain_name}" : "http://${aws_lb.main.dns_name}"
}
