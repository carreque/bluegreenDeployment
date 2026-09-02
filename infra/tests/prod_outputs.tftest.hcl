# Every name another phase depends on by string, pinned here, so a rename fails
# in this layer rather than three phases later as a null lookup.
#
# Two of these exist for the runbook rather than for a later layer:
# hook_function_names, so it can tail the right log groups and set
# BGD_EXPECT_DIGEST on the right function without deriving names by hand, and
# bake_alarm_names, so it can read the right alarm states — and so Phase 9
# attaches SNS actions to these alarms rather than creating parallel ones.

variables {
  image_tag = "0.0.0-test"

  # This suite exercises the PRODUCTION shape. Both are set explicitly
  # rather than relying on defaults, which are staging's: a file that
  # forgot them would silently assert production's properties against a
  # staging plan and fail with a message about a missing resource.
  environment = "prod"
  enable_prod = true

  # Mirrors environments/prod.tfvars, which terraform test cannot read: -var-file
  # applies to every file in a run, and this directory holds both suites. The two
  # places that state prod's shape are therefore this line and that file, and
  # prod_compute.tftest.hcl asserts the service actually runs two tasks — so a
  # drift between them fails here rather than in a production apply.
  desired_count = 2
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

run "the_consumed_surface_is_present_and_correctly_shaped" {
  command = apply

  # scripts/smoke.sh reads api_url and image_digest and nothing else. They are
  # the contract that makes the smoke test a deployment check rather than a
  # liveness check: one says where to look, the other says what must be running.
  assert {
    condition     = output.api_url == "https://api.carloscloudengineer.com"
    error_message = "api_url is what scripts/smoke.sh curls; it must be the full https URL"
  }

  # New in this layer, and not consumed by smoke.sh. The runbook curls it during
  # the window between the test shift and the production shift — that pair of
  # responses is the direct proof of which colour serves whom, and it is the
  # phase's second exit criterion.
  assert {
    condition     = output.test_url == "https://api.carloscloudengineer.com:8443"
    error_message = "test_url is the :8443 listener the runbook curls for exit criterion 2"
  }

  assert {
    condition     = output.image_digest == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "image_digest is what the smoke test compares /version against"
  }

  assert {
    condition = (
      output.cluster_name == "bgd-us-east-1-prod-cluster" &&
      output.service_name == "bgd-us-east-1-prod-api"
    )
    error_message = "the runbook and Phase 8's deploy action address the service by cluster and service name"
  }

  assert {
    condition     = output.task_definition_family == "bgd-us-east-1-prod-api"
    error_message = "task_definition_family is what later phases register revisions against and roll back by"
  }

  assert {
    condition     = output.log_group_name == "/bgd/us-east-1/prod/api"
    error_message = "the runbook and Phase 9 both read logs by this name"
  }

  assert {
    condition = (
      output.accounts_table_name == "bgd-us-east-1-prod-accounts" &&
      output.transactions_table_name == "bgd-us-east-1-prod-transactions"
    )
    error_message = "the table names are how the runbook seeds and inspects production data"
  }

  assert {
    condition     = output.alb_dns_name == "mock-alb-123.us-east-1.elb.amazonaws.com"
    error_message = "alb_dns_name is what the runbook curls to bypass DNS while a record propagates"
  }
}

run "the_blue_green_surface_later_phases_and_the_runbook_consume" {
  command = apply

  # Phase 11's rollback evidence names the two groups, and the runbook reads
  # their health during a shift to see which colour is registering.
  assert {
    condition = (
      output.blue_target_group_arn == aws_lb_target_group.blue.arn &&
      output.green_target_group_arn == aws_lb_target_group.green[0].arn
    )
    error_message = "both target group ARNs are published; a shift is only observable if you can name both colours"
  }

  # The runbook tails /aws/lambda/<name> for each of these, and sets
  # BGD_EXPECT_DIGEST on exactly one of them for exit criterion 3. Deriving the
  # names by hand in a runbook step is how a step ends up pointed at a function
  # that does not exist.
  assert {
    condition = toset(output.hook_function_names) == toset([
      "bgd-us-east-1-prod-pre-scale-hook",
      "bgd-us-east-1-prod-post-test-hook",
      "bgd-us-east-1-prod-post-prod-hook",
    ])
    error_message = "hook_function_names is how the runbook tails the right log groups and sets BGD_EXPECT_DIGEST on the right function"
  }

  # Phase 9 attaches SNS actions to these same alarms rather than creating
  # parallel ones, which is the whole reason this layer creates them without
  # actions (plan §D9).
  assert {
    condition     = toset(output.bake_alarm_names) == toset(local.bake_alarm_names)
    error_message = "bake_alarm_names is what Phase 9 attaches notification to, and what the runbook reads states from"
  }

  assert {
    condition     = length(output.bake_alarm_names) == 4
    error_message = "four alarms gate the bake; publishing fewer would hide a gap in the gate from Phase 9"
  }
}
