variable "name" {
  description = "Name prefix applied to every resource in this module."
  type        = string
}

variable "vpc_id" {
  description = "VPC the load balancer and target group live in."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the load balancer. At least two, in different AZs."
  type        = list(string)
}

variable "cluster_id" {
  description = "ECS cluster to run the service on."
  type        = string
}

variable "capacity_provider_name" {
  description = "Capacity provider to place tasks with."
  type        = string
}

variable "instance_security_group_id" {
  description = "Security group on the container hosts. The load balancer is granted access to the ephemeral port range on it."
  type        = string
}

variable "container_port" {
  description = "Port the application listens on inside the container."
  type        = number
  default     = 3000
}

variable "image_tag" {
  description = "Tag to deploy from the ECR repository this module creates."
  type        = string
  default     = "latest"
}

variable "desired_count" {
  description = "How many copies of the task to run."
  type        = number
  default     = 1
}

variable "task_cpu" {
  description = "CPU units reserved per task (1024 = one vCPU). A t3.micro has 2048 to hand out."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Hard memory limit in MiB. A t3.micro leaves roughly 700 MiB after the ECS agent."
  type        = number
  default     = 256
}

variable "health_check_path" {
  description = "Path the load balancer polls to decide whether a task is in service."
  type        = string
  default     = "/health"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. Never leave this unset — the default is forever, and it bills forever."
  type        = number
  default     = 14
}

variable "environment" {
  description = "Plain environment variables for the container. Anything secret belongs in Secrets Manager or SSM Parameter Store, referenced through `secrets` instead."
  type        = map(string)
  default     = {}
}

variable "enable_alarms" {
  description = "Create CloudWatch alarms for 5xx rate and unhealthy hosts. The free tier covers ten alarms."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
