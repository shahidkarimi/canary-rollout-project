variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "canary"
}

variable "env" {
  description = "Environment name (dev|prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env must be dev or prod"
  }
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

locals {
  name   = "${var.project}-${var.env}"
  global = data.terraform_remote_state.global.outputs

  blue_port  = 9898
  green_port = 9899

  docker_log_group = "/${var.project}/${var.env}/ec2/docker"
}
