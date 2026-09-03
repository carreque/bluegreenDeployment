# The mocks every run in this layer needs, in one place.
#
# Loaded by `mock_provider "aws" { source = "./tests/mocks" }` in each
# .tftest.hcl. The path is relative to the ROOT MODULE, not to the test file.
#
# Hoisted on 2026-09-03, when the environments merge had just made the problem
# twice as bad: twelve test files carried this block, in two variants, along
# with the comments below explaining why each entry exists. The explanations
# were maintained in duplicate at best and the two variants could drift.
#
# ONE file serves both environments, and it is PRODUCTION's set — a strict
# superset of staging's, verified rather than assumed. Staging therefore loads
# three mocks it has no instances of (aws_lb_listener, aws_lb_listener_rule and
# aws_lambda_function, all gated behind enable_prod), which is inert: a
# mock_resource declares what a resource WOULD return, so one with no instances
# returns it to nobody. The alternative, a second mocks directory differing by
# three blocks, would reintroduce exactly the drift this removes.
#
# What is NOT here, and cannot be:
#
#   variables       test-file scoped, and each suite states its own environment
#                   and enable_prod — which is the point of having two suites.
#
#   override_data   the two terraform_remote_state reads. Terraform parses an
#                   override_data inside a .tfmock.hcl WITHOUT COMPLAINT and
#                   then ignores it: the tests reach the real S3 backend and
#                   fail on credentials. Measured on 2026-09-03, not assumed.
#                   It fails loudly, but it fails, so those blocks stay in each
#                   test file. That is ~23 lines x 12 files this cannot remove.
#
#   override_resource   prod_bluegreen.tftest.hcl gives the two control-plane
#                   roles ARNs that say which one they are, so its assertions
#                   about which role landed in which slot discriminate instead
#                   of passing vacuously. Specific to that file, by design.

mock_resource "aws_iam_role" {
  defaults = { arn = "arn:aws:iam::590184028094:role/mock" }
}

mock_resource "aws_dynamodb_table" {
  defaults = { arn = "arn:aws:dynamodb:us-east-1:590184028094:table/mock" }
}

mock_resource "aws_cloudwatch_log_group" {
  defaults = { arn = "arn:aws:logs:us-east-1:590184028094:log-group:mock" }
}

mock_resource "aws_lb" {
  defaults = {
    arn      = "arn:aws:elasticloadbalancing:us-east-1:590184028094:loadbalancer/app/mock/0123456789abcdef"
    dns_name = "mock-alb-123.us-east-1.elb.amazonaws.com"
    zone_id  = "Z35SXDOTRQ7X7K"
  }
}

mock_resource "aws_lb_target_group" {
  defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:590184028094:targetgroup/mock/0123456789abcdef" }
}

mock_resource "aws_ecs_task_definition" {
  defaults = { arn = "arn:aws:ecs:us-east-1:590184028094:task-definition/mock:1" }
}

# Added because omitting it produced a hard error, not because it looked tidy:
# aws_lb_listener_rule validates its listener_arn client-side, and
# mock_provider's random eight-character string is not an ARN.
mock_resource "aws_lb_listener" {
  defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:590184028094:listener/app/mock/0123456789abcdef/aaaaaaaaaaaaaaaa" }
}

# Added because omitting it produced a hard error: the ECS service validates
# advanced_configuration's production_listener_rule and test_listener_rule
# client-side, and they are rule ARNs rather than listener ARNs (Phase 0 A7),
# so the aws_lb_listener mock above does not cover them.
mock_resource "aws_lb_listener_rule" {
  defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:590184028094:listener-rule/app/mock/0123456789abcdef/aaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbb" }
}

# Added because omitting it produced a hard error: the ECS service validates
# every lifecycle_hook's hook_target_arn client-side.
#
# All three functions therefore share one ARN under test, which is why iam.tf
# composes the invoke role's resource list from local.hook_function_names
# instead — three identical mocked ARNs cannot show that a wildcard has not
# crept in.
mock_resource "aws_lambda_function" {
  defaults = { arn = "arn:aws:lambda:us-east-1:590184028094:function:mock" }
}

mock_data "aws_ecr_image" {
  defaults = { image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
}
