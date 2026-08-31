terraform {
  # Partial configuration: bucket, region and lock table come from backend.hcl,
  # which `bootstrap` generates values for. Keeping them out of version control
  # means this repository does not publish the account ID in the bucket name, and
  # `terraform init -backend=false` still works in CI for fmt and validate.
  #
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key     = "envs/dev/terraform.tfstate"
    encrypt = true
  }
}
