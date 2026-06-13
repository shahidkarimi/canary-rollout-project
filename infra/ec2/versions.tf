terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # bucket + key supplied at init by scripts/tf.sh (key: ec2/<env>/terraform.tfstate)
  backend "s3" {
    region         = "eu-north-1"
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
      Stack       = "ec2"
      Environment = var.env
    }
  }
}

data "terraform_remote_state" "global" {
  backend = "s3"
  config = {
    bucket = local.state_bucket
    key    = "global/terraform.tfstate"
    region = "eu-north-1"
  }
}
