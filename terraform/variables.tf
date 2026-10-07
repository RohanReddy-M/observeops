variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "observeops"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Environment name (production, staging)"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging"], var.environment)
    error_message = "environment must be either \"production\" or \"staging\" — a typo here would silently apply with the wrong tags and no error."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "availability_zones" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b"]
}

variable "domain_name" {
  description = <<-EOT
    Public domain for the platform, e.g. "example.com". Leave empty (the default)
    to run without one: the ALB serves plain HTTP on its own AWS DNS name and no
    Route 53 zone or ACM certificate is created. Setting it requires the domain's
    registrar to delegate to the hosted zone this creates; see the README.
  EOT
  type        = string
  default     = ""
}

variable "app_instance_type" {
  description = "EC2 instance type for the application server"
  type        = string
  default     = "t3.small"
}

variable "obs_instance_type" {
  description = "EC2 instance type for the observability server (Prometheus/Grafana)"
  type        = string
  default     = "t3.small"
}

variable "alert_email" {
  description = "Email address to receive AWS Budget alerts"
  type        = string
  default     = "machireddy23@gmail.com"
}
