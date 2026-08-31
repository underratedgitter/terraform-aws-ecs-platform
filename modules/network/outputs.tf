output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered by availability zone."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered by availability zone."
  value       = aws_subnet.private[*].id
}

output "workload_subnet_ids" {
  description = <<-EOT
    Where compute should run. Private subnets when a NAT gateway exists to give
    them outbound access, public subnets otherwise — container hosts need to reach
    ECR and the ECS control plane, and a private subnet with no NAT cannot.
  EOT
  value       = var.enable_nat_gateway ? aws_subnet.private[*].id : aws_subnet.public[*].id
}

output "workload_needs_public_ip" {
  description = "True when compute runs in public subnets and therefore needs a public IP to reach AWS APIs."
  value       = !var.enable_nat_gateway
}

output "availability_zones" {
  description = "Availability zones the subnets were placed in."
  value       = local.azs
}
