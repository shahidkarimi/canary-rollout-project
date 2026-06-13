terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket         = "canary-rollout-tfstate-767911972289-us-east-1"
    key            = "observability/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "canary-rollout-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "canary-rollout"
      ManagedBy = "terraform"
      Stack     = "observability"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "canary"
}

variable "envs" {
  description = "Environments included in the dashboard"
  type        = list(string)
  default     = ["dev"]
}

data "terraform_remote_state" "lambda" {
  for_each = toset(var.envs)
  backend  = "s3"
  config = {
    bucket = "canary-rollout-tfstate-767911972289-us-east-1"
    key    = "lambda/${each.value}/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "ec2" {
  for_each = toset(var.envs)
  backend  = "s3"
  config = {
    bucket = "canary-rollout-tfstate-767911972289-us-east-1"
    key    = "ec2/${each.value}/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  # One row of widgets per environment; y offsets keep envs stacked.
  env_widgets = flatten([
    for idx, env in var.envs : [
      {
        type   = "text"
        x      = 0
        y      = idx * 16
        width  = 24
        height = 1
        properties = {
          markdown = "## ${upper(env)} — API GW + Lambda (left) | ALB + EC2 (right)"
        }
      },
      # --- canary split: the live shift indicators -------------------------
      {
        type   = "metric"
        x      = 0
        y      = idx * 16 + 1
        width  = 12
        height = 5
        properties = {
          title  = "${env} Lambda canary: invocations by executed version"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            [{ expression = "SEARCH('{AWS/Lambda,FunctionName,Resource,ExecutedVersion} \"${data.terraform_remote_state.lambda[env].outputs.function_name}\"', 'Sum', 60)", label = "by version", id = "e1" }]
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = idx * 16 + 1
        width  = 12
        height = 5
        properties = {
          title  = "${env} EC2 canary: requests per target group (blue vs green)"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", data.terraform_remote_state.ec2[env].outputs.blue_tg_arn_suffix, "LoadBalancer", data.terraform_remote_state.ec2[env].outputs.alb_arn_suffix, { label = "blue", color = "#1f77b4" }],
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", data.terraform_remote_state.ec2[env].outputs.green_tg_arn_suffix, "LoadBalancer", data.terraform_remote_state.ec2[env].outputs.alb_arn_suffix, { label = "green", color = "#2ca02c" }],
          ]
          view = "timeSeries"
        }
      },
      # --- API GW -----------------------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = idx * 16 + 6
        width  = 6
        height = 5
        properties = {
          title  = "${env} API GW: requests & 5xx"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", data.terraform_remote_state.lambda[env].outputs.api_id, { stat = "Sum", label = "requests" }],
            ["AWS/ApiGateway", "5xx", "ApiId", data.terraform_remote_state.lambda[env].outputs.api_id, { stat = "Sum", label = "5xx", color = "#d62728" }],
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = idx * 16 + 6
        width  = 6
        height = 5
        properties = {
          title  = "${env} API GW latency p50/p90/p99 (ms)"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", data.terraform_remote_state.lambda[env].outputs.api_id, { stat = "p50", label = "p50" }],
            ["...", { stat = "p90", label = "p90" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
          view = "timeSeries"
        }
      },
      # --- Lambda -------------------------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = idx * 16 + 11
        width  = 6
        height = 5
        properties = {
          title  = "${env} Lambda duration p50/p99 (ms)"
          region = var.region
          period = 60
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", data.terraform_remote_state.lambda[env].outputs.function_name, { stat = "p50", label = "p50" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = idx * 16 + 11
        width  = 6
        height = 5
        properties = {
          title  = "${env} Lambda errors & throttles"
          region = var.region
          period = 60
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", data.terraform_remote_state.lambda[env].outputs.function_name, { stat = "Sum", color = "#d62728" }],
            ["AWS/Lambda", "Throttles", "FunctionName", data.terraform_remote_state.lambda[env].outputs.function_name, { stat = "Sum", color = "#ff7f0e" }],
          ]
          view = "timeSeries"
        }
      },
      # --- ALB ------------------------------------------------------------------
      {
        type   = "metric"
        x      = 12
        y      = idx * 16 + 6
        width  = 6
        height = 5
        properties = {
          title  = "${env} ALB: requests & target 5xx"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", data.terraform_remote_state.ec2[env].outputs.alb_arn_suffix, { stat = "Sum", label = "requests" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", data.terraform_remote_state.ec2[env].outputs.alb_arn_suffix, { stat = "Sum", label = "target 5xx", color = "#d62728" }],
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = idx * 16 + 6
        width  = 6
        height = 5
        properties = {
          title  = "${env} ALB target response time p50/p99 (s)"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", data.terraform_remote_state.ec2[env].outputs.alb_arn_suffix, { stat = "p50", label = "p50" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
          view = "timeSeries"
        }
      },
      # --- EC2 hosts ---------------------------------------------------------------
      {
        type   = "metric"
        x      = 12
        y      = idx * 16 + 11
        width  = 6
        height = 5
        properties = {
          title  = "${env} EC2 CPU (%)"
          region = var.region
          period = 60
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", data.terraform_remote_state.ec2[env].outputs.asg_name, { stat = "Average" }],
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = idx * 16 + 11
        width  = 6
        height = 5
        properties = {
          title  = "${env} EC2 memory (%)"
          region = var.region
          period = 60
          metrics = [
            ["CWAgent", "mem_used_percent", "AutoScalingGroupName", data.terraform_remote_state.ec2[env].outputs.asg_name, { stat = "Average" }],
          ]
          view = "timeSeries"
        }
      },
    ]
  ])
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-rollout"
  dashboard_body = jsonencode({ widgets = local.env_widgets })
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
