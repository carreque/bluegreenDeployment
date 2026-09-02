# What staging does NOT build.
#
# The one test file with no counterpart before the 2026-09-02 environments
# merge, and the file that exists because of it.
#
# staging and prod are one root module now, and every production-only resource
# is present in the configuration and switched off by
# `count = var.enable_prod ? 1 : 0`. The other suites assert what staging DOES
# build, and every one of them would still pass if a gate were dropped — an
# extra target group, a third listener or four alarms in staging breaks no
# assertion about the ALB's name or the service's subnets.
#
# So the failure this merge introduces has no other detector: a resource that
# should be gated and is not. It is not loud. Staging would apply cleanly, cost
# more, and grow a :8443 listener and three Lambda functions nobody asked for;
# the first symptom would be a bill, or a surprised reader.
#
# Every resource named here is one that variables.tf documents enable_prod as
# gating. If that list grows, this file grows with it.

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

run "staging_builds_no_second_colour" {
  command = apply

  assert {
    condition     = length(aws_lb_target_group.green) == 0
    error_message = "staging must build ONE target group; a green group means enable_prod is not gating alb.tf"
  }

  # The blue group keeps staging's historical name. Renaming it to -api-blue
  # would be a rename this refactor has no reason to make, and the suffix is
  # conditional in alb.tf for exactly that reason.
  assert {
    condition     = aws_lb_target_group.blue.name == "bgd-us-east-1-staging-api"
    error_message = "staging's single target group keeps its Phase 5 name, not production's -api-blue"
  }
}

run "staging_builds_no_test_listener_and_no_rules" {
  command = apply

  assert {
    condition     = length(aws_lb_listener.test) == 0
    error_message = "the :8443 test listener is the dark canary's entry point; staging has no canary"
  }

  # Both rules, not just the production one. advanced_configuration takes RULE
  # arns (Phase 0 A7), so a rule in staging would be a rule nothing references.
  assert {
    condition     = length(aws_lb_listener_rule.production) == 0 && length(aws_lb_listener_rule.test) == 0
    error_message = "listener rules exist to be rewritten by ECS mid-shift; staging shifts nothing"
  }

  # And the :443 listener must therefore FORWARD rather than refuse. Production
  # defaults to a fixed 503 because its rules carry the traffic; in staging the
  # default action IS the route, so a 503 here would serve nothing at all.
  assert {
    condition     = one(aws_lb_listener.https.default_action).type == "forward"
    error_message = "staging has no listener rules, so the :443 default action must forward — a fixed-response default would serve 503 to every request"
  }
}

run "staging_builds_no_hooks_and_no_bake_alarms" {
  command = apply

  assert {
    condition     = length(module.pre_scale_hook) == 0 && length(module.post_test_hook) == 0 && length(module.post_prod_hook) == 0
    error_message = "the three lifecycle hooks are invoked by a blue/green deployment; staging runs ROLLING"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.five_xx) == 0 && length(aws_cloudwatch_metric_alarm.p95_latency) == 0
    error_message = "the bake alarms gate a bake; staging has none"
  }

  # for_each over an empty map rather than count, so this is the assertion that
  # local.target_groups is gated and not merely the alarms that read it.
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.unhealthy) == 0
    error_message = "the per-colour unhealthy alarms follow local.target_groups, which must be empty in staging"
  }

  assert {
    condition     = length(local.bake_alarm_names) == 0
    error_message = "bake_alarm_names must resolve to the empty list, or ecs.tf's alarms block would declare a gate over nothing"
  }
}

run "staging_builds_neither_control_plane_role" {
  command = apply

  # Two roles, two required slots, two different permission sets (Phase 6 §D4).
  # Both are meaningless without a traffic shift to authorise.
  assert {
    condition     = length(aws_iam_role.bluegreen) == 0 && length(aws_iam_role.hook_invoke) == 0
    error_message = "the bluegreen and hook_invoke roles exist to serve a traffic shift; a role nobody can explain is not a smaller blast radius"
  }

  assert {
    condition     = length(aws_iam_role_policy.hook_invoke) == 0 && length(aws_iam_role_policy_attachment.bluegreen) == 0
    error_message = "the roles' policies must be gated with them, or terraform would attach a policy to a role that does not exist"
  }

  # The two task roles are NOT gated: every environment runs tasks that pull an
  # image and write logs. Asserted here so the gating reads as a decision about
  # blue/green rather than about IAM in general.
  assert {
    condition     = aws_iam_role.task_exec.name == "bgd-us-east-1-staging-task-exec-role" && aws_iam_role.task.name == "bgd-us-east-1-staging-task-role"
    error_message = "the execution and task roles are unconditional; only the two control-plane roles gate on enable_prod"
  }
}

run "staging_deploys_rolling_with_a_circuit_breaker" {
  command = apply

  assert {
    condition     = one(aws_ecs_service.api.deployment_configuration).strategy == "ROLLING"
    error_message = "staging deploys ROLLING; BLUE_GREEN here would mean enable_prod is not gating ecs.tf"
  }

  assert {
    condition     = length(one(aws_ecs_service.api.deployment_configuration).lifecycle_hook) == 0
    error_message = "no hooks under ROLLING — the dynamic block must emit nothing when local.lifecycle_hooks is empty"
  }

  # The inverse of production's deliberate omission. Staging's circuit breaker
  # IS its rollback mechanism (Phase 5 §D8); production's is the bake.
  assert {
    condition     = one(aws_ecs_service.api.deployment_circuit_breaker).enable && one(aws_ecs_service.api.deployment_circuit_breaker).rollback
    error_message = "staging's circuit breaker is its only rollback mechanism and must be present and rolling back"
  }

  assert {
    condition     = length(one(aws_ecs_service.api.load_balancer).advanced_configuration) == 0
    error_message = "advanced_configuration names two colours and two rules; staging has one colour and no rules"
  }

  assert {
    condition     = length(aws_ecs_service.api.alarms) == 0
    error_message = "an alarms block over an empty name list would declare a gate that gates nothing, and the apply would accept it in silence"
  }

  assert {
    condition     = aws_ecs_service.api.desired_count == 1
    error_message = "staging runs one task: it exists to fail fast, not to be available"
  }
}

run "staging_publishes_the_blue_green_outputs_as_empty_rather_than_absent" {
  command = apply

  # Terraform has no conditional output, and `terraform output -raw name` on an
  # output that does not exist fails with "Unsupported attribute" rather than
  # returning empty. scripts/smoke.sh and the pipeline read these by name from
  # whichever environment they were pointed at, so a missing name is a red
  # stage; a null is a value a caller can test.
  assert {
    condition     = output.test_url == null && output.green_target_group_arn == null
    error_message = "the two scalar blue/green outputs must be null in staging, not absent"
  }

  assert {
    condition     = length(output.hook_function_names) == 0 && length(output.bake_alarm_names) == 0
    error_message = "the two list outputs must be empty in staging, not absent"
  }

  # And the hostname must be staging's, which is var.environment's job rather
  # than enable_prod's — the two are independent, and this is where that shows.
  assert {
    condition     = output.api_url == "https://staging-api.carloscloudengineer.com"
    error_message = "api_url follows var.environment; staging must resolve foundation's staging_api_domain"
  }
}
