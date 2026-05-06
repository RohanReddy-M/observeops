variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 gives 65,536 addresses."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets. Each must be a subset of vpc_cidr."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets."
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "availability_zones" {
  description = "AZs to deploy subnets into. Use at least 2 for redundancy."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "common_tags" {
  description = "Tags applied to all resources for cost tracking and identification"
  type        = map(string)
  default     = {}
}
