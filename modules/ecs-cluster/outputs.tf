output "cluster_id" {
  description = "ECS cluster ID."
  value       = aws_ecs_cluster.this.id
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "capacity_provider_name" {
  description = "Capacity provider backing the cluster, for a service's capacity_provider_strategy."
  value       = aws_ecs_capacity_provider.this.name

  # A service can only use the provider once it is attached to the cluster.
  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

output "instance_security_group_id" {
  description = "Security group attached to container hosts. The service module opens the ephemeral port range on it to the load balancer."
  value       = aws_security_group.instance.id
}

output "instance_role_arn" {
  description = "IAM role assumed by container hosts."
  value       = aws_iam_role.instance.arn
}

output "autoscaling_group_name" {
  description = "Name of the autoscaling group holding the container hosts."
  value       = aws_autoscaling_group.this.name
}
