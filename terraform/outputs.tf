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
