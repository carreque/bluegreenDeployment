# The reference copy of this layer's mocks. Terraform's test framework has no
# shared-setup construct for mock_provider, so every other test file in this
# directory repeats these three blocks verbatim; this file is what a reviewer
# diffs the copies against.
#
# Each mock_resource default below exists because omitting it produced a hard
# error before any assertion ran, not because it looked tidy. mock_provider
# fills computed attributes with a random eight-character string, and several
# resources validate ARN shape client-side. See Phase 5 plan §F2, and the Phase 6
# local verification record for which of this layer's additions were genuinely
# needed.
#
# What is deliberately NOT mocked: the archive provider. mock_provider mocks one
# provider, so data.archive_file in ../../modules/lambda executes for real during
# terraform test and builds an actual zip from lambdas/lifecycle_hook/handler.py.
# That is the point — the offline gate proves the packaging works rather than
# mocking away the step most likely to be misconfigured. Plan §F4.

variables {
  image_tag = "0.0.0-test"
}

mock_provider "aws" {
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
}

# Without these two overrides the tests reach the real S3 backend and fail on
# credentials rather than silently asserting against null. Measured — Phase 5
# plan F3.
override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      certificate_arn    = "arn:aws:acm:us-east-1:590184028094:certificate/mock"
      zone_id            = "Z0MOCKZONEID000"
      api_domain         = "api.carloscloudengineer.com"
      ecr_repository_url = "590184028094.dkr.ecr.us-east-1.amazonaws.com/bgd-us-east-1-api"
      ecr_repository_arn = "arn:aws:ecr:us-east-1:590184028094:repository/bgd-us-east-1-api"
      alerts_topic_arn   = "arn:aws:sns:us-east-1:590184028094:bgd-us-east-1-alerts"
    }
  }
}

override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      vpc_id                  = "vpc-0mockvpc"
      public_subnet_ids       = ["subnet-0mockpuba", "subnet-0mockpubb"]
      private_subnet_ids      = ["subnet-0mockprva", "subnet-0mockprvb"]
      alb_security_group_ids  = { staging = "sg-0mockalbstaging", prod = "sg-0mockalbprod" }
      task_security_group_ids = { staging = "sg-0mocktaskstaging", prod = "sg-0mocktaskprod" }
      container_port          = 8080
    }
  }
}

run "the_mock_reference_resolves" {
  command = apply

  assert {
    condition     = local.container_port == 8080
    error_message = "the network remote-state override did not reach locals"
  }

  assert {
    condition     = local.env_prefix == "bgd-us-east-1-prod"
    error_message = "this layer's prefix must be prod's, not staging's"
  }

  assert {
    condition     = local.foundation.api_domain == "api.carloscloudengineer.com"
    error_message = "the foundation override must expose api_domain; prod uses it, not staging_api_domain"
  }
}
