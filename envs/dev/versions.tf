terraform {
  required_version = ">= 1.17.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}

provider "aws" {
  region = var.region

  # Applied to everything the provider creates, so a forgotten `tags` block on a
  # single resource cannot produce an untagged, unattributable bill.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "underratedgitter/terraform-aws-ecs-platform"
    }
  }
}
