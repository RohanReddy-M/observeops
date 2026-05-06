variable "project_name" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "admin_cidr" {
  description = "Your IP in CIDR format for SSH access. Get yours: curl ifconfig.me then add /32"
  type        = string
  # /32 means exactly one IP address
  # Example: "203.0.113.10/32"
}
variable "common_tags" { type = map(string); default = {} }
