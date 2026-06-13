terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }

  # key supplied per env by scripts/tf.sh: lambda/<env>/terraform.tfstate
  backend "s3" {
    bucket         = "canary-rollout-tfstate-767911972289-us-east-1"
    region         = "us-east-1"
    dynamodb_table = "canary-rollout-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "canary-rollout"
      ManagedBy   = "terraform"
      Stack       = "lambda"
      Environment = var.env
    }
  }
}

data "terraform_remote_state" "global" {
  backend = "s3"
  config = {
    bucket = "canary-rollout-tfstate-767911972289-us-east-1"
    key    = "global/terraform.tfstate"
    region = "us-east-1"
  }
}
