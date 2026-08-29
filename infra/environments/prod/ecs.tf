resource "aws_cloudwatch_log_group" "api" {
  # checkov:skip=CKV_AWS_338:fourteen-day retention is deliberate on an environment that make teardown destroys at the end of every session. Retention is the entirety of what a log group costs, and the blue/green evidence this phase produces is read within minutes of the deployment that produced it, not weeks later.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. A customer-managed key bills per API call on a log stream that carries application stdout and no credential, token or customer record.
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}
