output "url" {
  description = "Public URL of the service."
  value       = "http://${aws_lb.this.dns_name}"
}

output "alb_dns_name" {
  description = "DNS name of the load balancer, for a CNAME or Route 53 alias."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the load balancer, needed for a Route 53 alias record."
  value       = aws_lb.this.zone_id
}

output "ecr_repository_url" {
  description = "Push builds here. This is what the CI pipeline needs."
  value       = aws_ecr_repository.this.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the ECR repository, for scoping a CI push policy."
  value       = aws_ecr_repository.this.arn
}

output "service_name" {
  description = "ECS service name, for `aws ecs update-service` from CI."
  value       = aws_ecs_service.this.name
}

output "task_definition_family" {
  description = "Task definition family. CI registers new revisions against this."
  value       = aws_ecs_task_definition.this.family
}

output "log_group_name" {
  description = "CloudWatch log group carrying container output."
  value       = aws_cloudwatch_log_group.this.name
}
