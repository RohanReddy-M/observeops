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

variable "admin_cidr" {
  description = "YOUR IP address in CIDR format for SSH. Run: curl ifconfig.me"
  type        = string
  # No default - you MUST set this. Prevents accidental open SSH access.

  # This variable gates ingress to Grafana (3000), Prometheus (9090), Loki (3100)
  # and Tempo's OTel ports in the observability security group (see
  # modules/security/main.tf) — nothing in the security-group rules themselves
  # stops this from being set to 0.0.0.0/0, which would open all of those to the
  # entire internet with no error from Terraform. Enforce the /32 here instead.
  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && length(split("/", var.admin_cidr)) == 2 && split("/", var.admin_cidr)[1] == "32"
    error_message = "admin_cidr must be a single IP address in /32 CIDR notation (e.g. 203.0.113.10/32), not a broader range."
  }
}

variable "public_key_path" {
  description = "Path to your SSH public key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
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
