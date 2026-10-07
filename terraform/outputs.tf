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
  value       = module.alb.public_url
}

output "route53_name_servers" {
  description = "NS records of the hosted zone (empty without a domain). Set these at the registrar when the zone is first created."
  value       = module.alb.route53_name_servers
}

output "app_instance_id" {
  description = "Instance ID of the app server. infra-up.sh waits for its bootstrap and stores it as the EC2_INSTANCE_ID secret."
  value       = module.compute.app_instance_id
}

output "obs_instance_id" {
  description = "Instance ID of the observability server"
  value       = module.compute.obs_instance_id
}
