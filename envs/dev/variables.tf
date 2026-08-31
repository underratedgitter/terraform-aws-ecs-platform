variable "project" {
  description = "Project name. Prefixes every resource name."
  type        = string
  default     = "ecs-platform"
}

variable "environment" {
  description = "Environment name. Part of every resource name, so dev and prod can share an account without colliding."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "enable_nat_gateway" {
  description = "See modules/network. False keeps this inside roughly the free tier; true is what production wants."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "Container host instance type."
  type        = string
  default     = "t3.micro"
}

variable "container_port" {
  description = "Port the application listens on."
  type        = number
  default     = 3000
}

variable "image_tag" {
  description = "Image tag to deploy on the next apply. CI deploys by registering a new task revision, so this is the bootstrap value only."
  type        = string
  default     = "latest"
}

variable "desired_count" {
  description = "Number of tasks to run."
  type        = number
  default     = 1
}

variable "health_check_path" {
  description = "Load balancer health check path."
  type        = string
  default     = "/health"
}
