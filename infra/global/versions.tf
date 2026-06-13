terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }

  backend "s3" {
    bucket         = "canary-rollout-tfstate-767911972289-us-east-1"
    key            = "global/terraform.tfstate"
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
      Stack     = "global"
    }
  }
}
