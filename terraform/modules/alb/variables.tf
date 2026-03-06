variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "app_instance_id" {
  type = string
}

variable "common_tags" {
  type    = map(string)
  default = {}
}