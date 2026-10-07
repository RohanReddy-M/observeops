variable "project_name" { type = string }
variable "public_base_url" {
  description = "Base URL of the platform (scheme + host, no trailing slash). The outside-in probe requests it the way a user would."
  type        = string
}
variable "common_tags" { type = map(string) }
