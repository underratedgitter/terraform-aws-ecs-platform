variable "name" {
  description = "Name prefix applied to every resource in this module."
  type        = string
}

variable "vpc_id" {
  description = "VPC the container hosts join."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets the autoscaling group launches instances into."
  type        = list(string)
}

variable "associate_public_ip" {
  description = "Give instances a public IP. Required when they run in public subnets, since they must reach ECR and the ECS control plane."
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "Instance type for container hosts. t3.micro is what the 12-month free tier covers (750 hours/month)."
  type        = string
  default     = "t3.micro"
}

variable "min_size" {
  description = "Minimum number of container hosts."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of container hosts."
  type        = number
  default     = 2
}

variable "desired_capacity" {
  description = "Starting number of container hosts. Ignored after creation so managed scaling can move it."
  type        = number
  default     = 1
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. The free tier covers 30 GiB of gp2/gp3 in total."
  type        = number
  default     = 30
}

variable "container_insights" {
  description = "Enable CloudWatch Container Insights. Off by default — it is billed as custom metrics, not free tier."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
