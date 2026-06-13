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

  # bucket supplied at init by scripts/tf.sh (derived from the caller's account)
  backend "s3" {
    key            = "global/terraform.tfstate"
    region         = "eu-north-1"
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
