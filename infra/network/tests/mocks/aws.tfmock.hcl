# The mocks every run in this layer needs, in one place.
#
# Loaded by `mock_provider "aws" { source = "./tests/mocks" }` in each
# .tftest.hcl. The path is relative to the ROOT MODULE, not to the test file.
#
# Hoisted on 2026-09-03. This block was byte-identical in all four test files,
# including the comments below explaining why each entry exists — so the
# explanations were maintained in quadruplicate and the mocks could drift from
# each other silently.
#
# What is NOT here: `variables` and `override_data`. Both are test-file scoped.
# Terraform parses an override_data inside a .tfmock.hcl without complaint and
# then ignores it, so the tests reach the real S3 backend and fail on
# credentials — measured, not assumed. They stay in each file.

mock_data "aws_availability_zones" {
  defaults = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  }
}

# Task 5 (flowlogs.tf) added aws_iam_policy_document, aws_cloudwatch_log_group
# and aws_iam_role to the root module, so every run in this file now
# instantiates them too even though nothing here asserts on them. A mocked
# provider intercepts aws_iam_policy_document and mocks its "json" attribute
# to "", which aws_iam_role's own schema validation rejects as an assume role
# policy before apply runs; mocked resources' computed "arn" attributes
# default to an opaque string rather than an ARN, and aws_flow_log.this feeds
# those back in as arguments the provider validates client-side as ARNs. Both
# defaults below exist only to keep validation happy, not to be inspected.
mock_data "aws_iam_policy_document" {
  defaults = {
    json = jsonencode({
      Version   = "2012-10-17"
      Statement = []
    })
  }
}

mock_resource "aws_cloudwatch_log_group" {
  defaults = {
    arn = "arn:aws:logs:us-east-1:590184028094:log-group:/bgd/us-east-1/shared/vpc-flow"
  }
}

mock_resource "aws_iam_role" {
  defaults = {
    arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-shared-flow-logs-role"
  }
}
