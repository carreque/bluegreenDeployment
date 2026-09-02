variables {
  image_tag = "0.0.0-test"

  # This suite exercises the STAGING shape. Stated explicitly even though
  # both match the variable defaults, so the file says what it tests
  # rather than depending on a default staying put.
  environment = "staging"
  enable_prod = false
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

  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  }
}

# Without these two overrides the tests reach the real S3 backend and fail on
# credentials rather than silently asserting against null. Measured — plan F3.
override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      certificate_arn    = "arn:aws:acm:us-east-1:590184028094:certificate/mock"
      zone_id            = "Z0MOCKZONEID000"
      api_domain         = "api.carloscloudengineer.com"
      staging_api_domain = "staging-api.carloscloudengineer.com"
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

# This file exists to make a rename in this layer fail here rather than in
# Phase 8, where it would surface as a smoke test reading an empty URL, or in
# Phase 6, where it would surface as a copied module referencing an output that
# no longer exists. Outputs are an interface; interfaces get tests.

run "the_consumed_surface_is_present_and_correctly_shaped" {
  command = apply

  # scripts/smoke.sh reads these two and nothing else. They are the contract
  # that makes the smoke test a deployment check rather than a liveness check:
  # one says where to look, the other says what must be running there.
  assert {
    condition     = output.api_url == "https://staging-api.carloscloudengineer.com"
    error_message = "api_url is what scripts/smoke.sh curls; it must be the full https URL"
  }

  assert {
    condition     = output.image_digest == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "image_digest is what the smoke test compares /version against"
  }

  # Phase 8's ECS deploy action addresses the service by cluster and name.
  assert {
    condition = (
      output.cluster_name == "bgd-us-east-1-staging-cluster" &&
      output.service_name == "bgd-us-east-1-staging-api"
    )
    error_message = "Phase 8's deploy action addresses the service by cluster and service name"
  }

  # A later phase registers new task definition revisions against this family,
  # and a manual rollback names a revision of it. Asserted for the same reason
  # as the two above: this is a name another phase depends on by string.
  assert {
    condition     = output.task_definition_family == "bgd-us-east-1-staging-api"
    error_message = "task_definition_family is what later phases register revisions against and roll back by"
  }

  assert {
    condition     = output.log_group_name == "/bgd/us-east-1/staging/api"
    error_message = "the runbook and Phase 9 both read logs by this name"
  }

  assert {
    condition = (
      output.accounts_table_name == "bgd-us-east-1-staging-accounts" &&
      output.transactions_table_name == "bgd-us-east-1-staging-transactions"
    )
    error_message = "the table names are how the runbook seeds and inspects staging data"
  }

  assert {
    condition     = output.alb_dns_name == "mock-alb-123.us-east-1.elb.amazonaws.com"
    error_message = "alb_dns_name is what the runbook curls to bypass DNS while a record propagates"
  }
}
