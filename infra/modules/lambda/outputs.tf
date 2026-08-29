output "function_arn" {
  description = "Function ARN. The calling layer names it in deployment_configuration.lifecycle_hook.hook_target_arn and in the invoke role's resource list."
  value       = aws_lambda_function.this.arn
}

output "function_name" {
  description = "Function name, as the runbook addresses it with `aws lambda update-function-configuration` and `aws logs tail`."
  value       = aws_lambda_function.this.function_name
}

output "log_group_name" {
  description = "Where this function's output goes. The runbook tails it to read what a hook decided and why."
  value       = aws_cloudwatch_log_group.this.name
}

output "role_arn" {
  description = "The function's execution role. Exposed so a caller can assert it is scoped to this function's log group and nothing else."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = <<-EOT
    The execution role's name. Exposed alongside role_arn because mock_provider
    fills every aws_iam_role.arn with the same string, so an assertion that two
    roles differ can only be written against their names.
  EOT
  value       = aws_iam_role.this.name
}

# --- exposed so the calling layer can assert on them -------------------------
#
# A module's resources are not reachable from a .tftest.hcl file; only its
# outputs are. These four exist so that prod/tests/bluegreen.tftest.hcl can
# assert what the three real instantiations actually resolved to — the runtime,
# the architecture, the timeout, and above all which listener each hook probes.
# That last one is the dark canary's identity and the worst thing in this layer
# to get wrong, so it is asserted against the function's own resolved
# configuration rather than against the local it was built from.

output "runtime" {
  description = "The function's resolved runtime, so a caller can assert the project's pinned version."
  value       = aws_lambda_function.this.runtime
}

output "architectures" {
  description = "The function's resolved architecture list, so a caller can assert Graviton parity with the container."
  value       = aws_lambda_function.this.architectures
}

output "timeout_seconds" {
  description = "The function's resolved timeout. On a synchronous deployment gate this is how long a stage can hang."
  value       = aws_lambda_function.this.timeout
}

output "environment_variables" {
  description = "The function's resolved environment. The whole of a hook's per-instance configuration, and what a caller asserts the probe URL and stage from."
  value       = try(one(aws_lambda_function.this.environment).variables, {})
}
