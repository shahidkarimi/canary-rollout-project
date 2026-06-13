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

variable "provisioned_concurrency" {
  description = "Provisioned concurrency on the live alias (0 = disabled). Enabled in prod as the implemented scalability improvement."
  type        = number
  default     = 0
}

data "aws_caller_identity" "current" {}

locals {
  name         = "${var.project}-${var.env}"
  global       = data.terraform_remote_state.global.outputs
  secret_arn   = local.global.secret_arn
  state_bucket = "canary-rollout-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
}
