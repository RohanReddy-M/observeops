variable "project_name" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "ubuntu_ami" {
  type = string
}

variable "app_instance_type" {
  type    = string
  default = "t3.small"
}

variable "obs_instance_type" {
  type    = string
  default = "t3.small"
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "app_sg_id" {
  type = string
}

variable "observability_sg_id" {
  type = string
}


variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "ecr_repository_arns" {
  description = "ARNs of this project's ECR repositories. The app server's role may pull from these and no others."
  type        = list(string)
}

variable "dynamodb_table_arn" {
  description = "ARN of the table SecureShip stores ships in. The app server's role is scoped to exactly this table."
  type        = string
}

variable "public_base_url" {
  description = "Base URL the platform is served on. Written to .env on the observability server so Prometheus and Grafana generate correct external links."
  type        = string
  default     = "http://localhost"
}
