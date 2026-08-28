# The interface Phases 6 and 8, the runbook and scripts/smoke.sh all read.
# tests/outputs.tftest.hcl pins every name here, so a rename fails in this
# layer rather than three phases later as a null lookup.

output "api_url" {
  description = "Base URL of this environment. scripts/smoke.sh curls it; the runbook pastes it into a browser."
  value       = "https://${local.foundation.staging_api_domain}"
}

output "alb_dns_name" {
  description = "The load balancer's own hostname, for reaching the environment while the Route 53 record is still propagating."
  value       = aws_lb.this.dns_name
}

output "cluster_name" {
  description = "ECS cluster name. Phase 8's deploy action and every aws ecs CLI call address the service through it."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name, as addressed by Phase 8's deploy action."
  value       = aws_ecs_service.api.name
}

output "task_definition_family" {
  description = "Task definition family. Phase 8 registers new revisions against it; a rollback names a revision of it."
  value       = aws_ecs_task_definition.api.family
}

output "image_digest" {
  description = "The digest actually deployed. scripts/smoke.sh asserts /version reports this exact value."
  value       = data.aws_ecr_image.api.image_digest
}

output "log_group_name" {
  description = "Where the container's stdout goes. The runbook tails it; Phase 9 reads metrics from it."
  value       = aws_cloudwatch_log_group.api.name
}

output "accounts_table_name" {
  description = "Staging accounts table, for seeding and inspecting data by hand."
  value       = aws_dynamodb_table.accounts.name
}

output "transactions_table_name" {
  description = "Staging transactions table, for seeding and inspecting data by hand."
  value       = aws_dynamodb_table.transactions.name
}
