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
