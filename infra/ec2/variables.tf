variable "region" {
  type    = string
  default = "eu-north-1"
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

variable "enable_autoscaling" {
  description = "Implemented scalability improvement: ALB-request target-tracking. When false the ASG stays at exactly 2; when true it keeps a baseline of 2 and surges to max_instances under load. Enabled in prod."
  type        = bool
  default     = false
}

variable "max_instances" {
  description = "ASG ceiling when autoscaling is enabled (baseline stays 2)"
  type        = number
  default     = 4
}

variable "alb_requests_per_target_target" {
  description = "Target-tracking setpoint: average ALB requests per target per minute"
  type        = number
  default     = 60
}

data "aws_caller_identity" "current" {}

locals {
  name         = "${var.project}-${var.env}"
  global       = data.terraform_remote_state.global.outputs
  state_bucket = "canary-rollout-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"

  blue_port  = 9898
  green_port = 9899

  docker_log_group = "/${var.project}/${var.env}/ec2/docker"
}
