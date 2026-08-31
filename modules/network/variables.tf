variable "name" {
  description = "Name prefix applied to every resource in this module."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be large enough for az_count public and az_count private /24s."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid CIDR of /20 or larger (the module carves /24s out of it)."
  }
}

variable "az_count" {
  description = "How many availability zones to spread subnets across. Two is the minimum an ALB will accept."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Provision a NAT gateway so private subnets get outbound internet.

    Left false by default on purpose: a NAT gateway is not in the AWS free tier and
    runs about $32/month per gateway plus data processing, which is more than the
    rest of this stack combined. With it false, workloads run in the public subnets
    with a public IP and are protected by security groups rather than by not being
    routable. Flip it to true for anything real.
  EOT
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch Logs. Off by default because ingestion is billed beyond the free 5 GB/month."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "Retention for the VPC flow log group."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
