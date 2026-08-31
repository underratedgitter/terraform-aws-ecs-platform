output "state_bucket" {
  description = "Bucket name to put in envs/*/backend.tf."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "DynamoDB table name to put in envs/*/backend.tf."
  value       = aws_dynamodb_table.locks.id
}

output "region" {
  description = "Region the backend lives in."
  value       = var.region
}

output "ci_role_arn" {
  description = "Role ARN for the AWS_ROLE_ARN repository variable in GitHub Actions."
  value       = local.create_ci ? aws_iam_role.ci_plan[0].arn : null
}

output "backend_block" {
  description = "Paste this into envs/<env>/backend.tf."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.id}"
        key            = "envs/dev/terraform.tfstate"
        region         = "${var.region}"
        dynamodb_table = "${aws_dynamodb_table.locks.id}"
        encrypt        = true
      }
    }
  EOT
}
