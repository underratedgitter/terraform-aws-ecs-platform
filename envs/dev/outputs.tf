output "url" {
  description = "Public URL of the deployed service."
  value       = module.service.url
}

output "ecr_repository_url" {
  description = "Push builds here."
  value       = module.service.ecr_repository_url
}

output "cluster_name" {
  description = "ECS cluster name, for `aws ecs update-service`."
  value       = module.cluster.cluster_name
}

output "service_name" {
  description = "ECS service name, for `aws ecs update-service`."
  value       = module.service.service_name
}

output "task_definition_family" {
  description = "Task definition family CI registers new revisions against."
  value       = module.service.task_definition_family
}

output "log_group_name" {
  description = "Where container logs land."
  value       = module.service.log_group_name
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}
