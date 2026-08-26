# One topic for every alert the project raises: pipeline failure, deployment
# failure and rollback (design §8).
#
# Unencrypted, deliberately. An AWS-managed key's policy cannot be edited, and
# CloudWatch cannot publish to a topic encrypted with one — which would break
# Phase 6's automatic-rollback alarms and Phase 9's failure alerts. Doing it
# properly needs a customer-managed key with its own policy, rotation and
# monthly charge, for a payload that says "a deployment failed".
# See the Phase 3 plan §D5.

resource "aws_sns_topic" "alerts" {
  # checkov:skip=CKV_AWS_26:Encrypting with the AWS-managed key breaks CloudWatch publishing, because that key's policy cannot be edited to allow it — which would silently disable Phase 6's automatic rollback alarms and Phase 9's failure alerts. A customer-managed key would work but costs a monthly charge and its own policy for a payload that says "a deployment failed". Phase 3 plan §D5.
  name = "${local.name_prefix}-alerts"
}

# Created in PendingConfirmation state. AWS emails a confirmation link and the
# subscription does nothing until it is clicked — Terraform reports success,
# plan stays clean, and no error is ever raised. This is the third of the
# project's three manual steps; the Phase 3 runbook has the verification command.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
