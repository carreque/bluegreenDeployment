resource "aws_cloudwatch_log_group" "api" {
  # checkov:skip=CKV_AWS_338:fourteen-day retention is deliberate on an environment that is destroyed when idle. Retention is the entirety of what a log group costs. Same reasoning as network's flow logs.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. These are application logs from a staging environment carrying no production data.
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}
