# The LSI is the assertion that matters most in this file. A local secondary
# index must be created with its table and cannot be added afterwards, so
# getting it wrong here is not a fix, it is a destroy and recreate. The shape
# is fixed by app/src/bgd/repository/schema.py, which the application, the
# local bootstrap and the tests all read.

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
      staging_api_domain = "staging-api.carloscloudengineer.com"
      ecr_repository_url = "590184028094.dkr.ecr.us-east-1.amazonaws.com/bgd-us-east-1-api"
      ecr_repository_arn = "arn:aws:ecr:us-east-1:590184028094:repository/bgd-us-east-1-api"
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

run "the_tables_match_the_application_schema" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.accounts.name == "bgd-us-east-1-staging-accounts"
    error_message = "accounts table name breaks the naming convention"
  }

  assert {
    condition     = aws_dynamodb_table.accounts.hash_key == "account_id"
    error_message = "accounts is keyed on account_id in schema.py"
  }

  assert {
    condition = (
      aws_dynamodb_table.transactions.hash_key == "account_id" &&
      aws_dynamodb_table.transactions.range_key == "transaction_id"
    )
    error_message = "transactions is keyed (account_id, transaction_id) in schema.py"
  }

  assert {
    condition     = one(aws_dynamodb_table.transactions.local_secondary_index).name == "created_at-index"
    error_message = "the created_at-index LSI is missing; it cannot be added after the table is created"
  }

  assert {
    condition = (
      one(aws_dynamodb_table.transactions.local_secondary_index).range_key == "created_at" &&
      one(aws_dynamodb_table.transactions.local_secondary_index).projection_type == "ALL"
    )
    error_message = "the LSI must sort on created_at and project ALL, per schema.py"
  }

  assert {
    condition = alltrue([
      aws_dynamodb_table.accounts.billing_mode == "PAY_PER_REQUEST",
      aws_dynamodb_table.transactions.billing_mode == "PAY_PER_REQUEST",
    ])
    error_message = "on-demand billing is what makes an idle staging environment cost nothing"
  }

  assert {
    condition = alltrue([
      !aws_dynamodb_table.accounts.deletion_protection_enabled,
      !aws_dynamodb_table.transactions.deletion_protection_enabled,
    ])
    error_message = "deletion protection would make terraform destroy fail and break make teardown"
  }
}
