output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "app_server_private_ip" {
  description = "Private IP of app server (SSH via bastion or SSM)"
  value       = module.compute.app_server_private_ip
}

output "obs_server_private_ip" {
  description = "Private IP of observability server"
  value       = module.compute.obs_server_private_ip
}

output "ecr_secureship_url" {
  description = "ECR URL for SecureShip - use this in CI/CD pipeline"
  value       = aws_ecr_repository.secureship.repository_url
}

output "ecr_statusservice_url" {
  description = "ECR URL for StatusService"
  value       = aws_ecr_repository.statusservice.repository_url
}

output "ecr_ragservice_url" {
  description = "ECR URL for RAGService"
  value       = aws_ecr_repository.ragservice.repository_url
}

output "ecr_llm_alert_autopilot_url" {
  description = "ECR URL for LLM Alert Autopilot"
  value       = aws_ecr_repository.llm_alert_autopilot.repository_url
}

output "alb_dns_name" {
  description = "ALB DNS name — hit this directly to test before DNS propagates"
  value       = module.alb.alb_dns_name
}

output "live_url" {
  description = "Public URL of the application"
  value       = "https://secureship.click"
}

output "route53_name_servers" {
  description = "NS records — infra-up.sh syncs these to the domain registrar automatically"
  value       = module.alb.route53_name_servers
}
