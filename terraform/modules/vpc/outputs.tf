# VPC Outputs - values other modules need to reference
output "vpc_id" {
  description = "VPC ID - needed by subnets, security groups, and other resources"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of public subnets - ALB goes here"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of private subnets - EC2 instances go here"
  value       = aws_subnet.private[*].id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}
