variable "project_name" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "alb_sg_id" { type = string }
variable "app_instance_id" { type = string }
variable "domain_name" {
  description = "Public domain, or empty to serve HTTP on the ALB's own DNS name with no Route 53 zone or certificate."
  type        = string
  default     = ""
}
variable "common_tags" { type = map(string) }
