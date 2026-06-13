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

variable "provisioned_concurrency" {
  description = "Provisioned concurrency on the live alias (0 = disabled). Enabled in prod as the implemented scalability improvement."
  type        = number
  default     = 0
}

locals {
  name       = "${var.project}-${var.env}"
  global     = data.terraform_remote_state.global.outputs
  secret_arn = local.global.secret_arn
}
