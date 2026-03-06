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

variable "public_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}