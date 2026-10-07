variable "project_name" { type = string }
variable "public_base_url" {
  description = "Base URL of the platform (scheme + host, no trailing slash). The incident analyzer calls RAGService through it."
  type        = string
}
variable "common_tags" { type = map(string) }
