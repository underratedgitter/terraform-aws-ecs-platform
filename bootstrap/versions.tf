terraform {
  required_version = ">= 1.17.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }

  # Deliberately local state. This configuration creates the bucket that every
  # other configuration stores state in, so it cannot store its own state there.
  # The resulting terraform.tfstate is gitignored; losing it costs an import, not
  # the bucket.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Component = "tf-backend"
    }
  }
}
