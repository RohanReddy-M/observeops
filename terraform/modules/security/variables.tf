variable "project_name" { type = string }
variable "vpc_id" { type = string }

variable "enable_https" {
  description = "Open 443 on the load balancer. True only when a domain (and so a certificate and an HTTPS listener) is configured."
  type        = bool
  default     = false
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
