# The interface Phases 8, 9 and 11, the runbook and scripts/smoke.sh all read.
# tests/outputs.tftest.hcl pins every name here, so a rename fails in this layer
# rather than three phases later as a null lookup.

output "api_url" {
  description = "Base URL of this environment. scripts/smoke.sh curls it; the runbook pastes it into a browser."
  value       = "https://${local.foundation.api_domain}"
}

output "test_url" {
  description = <<-EOT
    The :8443 test listener. Not consumed by scripts/smoke.sh — this is for the
    runbook and for Phase 11's evidence.

    During the window between the test traffic shift and the production traffic
    shift, curling /version here and on api_url returns two different git_sha
    values. That pair is the direct proof of which colour serves whom, and it is
    this phase's second exit criterion. The window is minutes wide, so the
    runbook says to have both commands ready before the deployment starts.
  EOT
  value       = "https://${local.foundation.api_domain}:8443"
}

output "alb_dns_name" {
  description = "The load balancer's own hostname, for reaching the environment while the Route 53 record is still propagating."
  value       = aws_lb.this.dns_name
}

output "cluster_name" {
  description = "ECS cluster name. The runbook's aws ecs list-service-deployments and Phase 8's deploy action both address the service through it."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name, as addressed by the runbook's CLI observation steps and Phase 8's deploy action."
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

output "blue_target_group_arn" {
  description = "The target group the :443 rule forwards to at creation. Which colour is production after that is ECS's business — read the listener rule, not this output, to find out."
  value       = aws_lb_target_group.blue.arn
}

output "green_target_group_arn" {
  description = "The target group the :8443 rule forwards to at creation. Published alongside blue because a traffic shift is only observable if you can name both colours."
  value       = aws_lb_target_group.green.arn
}

output "hook_function_names" {
  description = <<-EOT
    The three lifecycle hook functions, so the runbook can tail
    /aws/lambda/<name> for each without deriving the names by hand — and so its
    step 14 sets BGD_EXPECT_DIGEST on the right one.

    Deriving these in a runbook step is how a step ends up pointed at a function
    that does not exist, and reports silence as success.
  EOT
  value       = values(local.hook_function_names)
}

output "bake_alarm_names" {
  description = <<-EOT
    The four alarms the bake period is gated on.

    Published for two consumers. The runbook reads their states to confirm all
    four leave INSUFFICIENT_DATA once traffic exists, which is what retires plan
    F3. And Phase 9 attaches SNS actions to these same alarms rather than
    creating parallel ones — which is the whole reason this layer creates them
    with no actions (plan D9).
  EOT
  value       = local.bake_alarm_names
}

output "accounts_table_name" {
  description = "Production accounts table, for seeding and inspecting data by hand."
  value       = aws_dynamodb_table.accounts.name
}

output "transactions_table_name" {
  description = "Production transactions table, for seeding and inspecting data by hand."
  value       = aws_dynamodb_table.transactions.name
}
