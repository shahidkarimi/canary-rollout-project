variable "region" {
  description = "AWS region for all stacks"
  type        = string
  default     = "eu-north-1"
}

variable "project" {
  description = "Project prefix for resource names"
  type        = string
  default     = "canary"
}

variable "github_repo" {
  description = "GitHub org/repo allowed to assume the CI roles via OIDC"
  type        = string
  default     = "shahidkarimi/canary-rollout-project"
}

variable "alarm_email" {
  description = "Optional email for SNS alarm subscription (empty = none)"
  type        = string
  default     = ""
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # Token format issued by the rotation function; the CloudWatch Logs data
  # protection policy masks anything matching this shape.
  token_regex = "dkyd_[A-Za-z0-9]{32}"
}
