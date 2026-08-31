variable "project" {
  description = "Project name, used as a prefix for the backend resources."
  type        = string
  default     = "ecs-platform"
}

variable "region" {
  description = "Region to create the state bucket and lock table in."
  type        = string
  default     = "ap-south-1"
}

variable "state_bucket_name" {
  description = "Globally unique name for the state bucket. Leave empty to append the account ID to the project name."
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI role via OIDC. Leave empty to skip creating the role."
  type        = string
  default     = ""
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one — it is account-wide and there can only be one."
  type        = bool
  default     = true
}
