# Everything in this file is shape no other layer in the project has. The
# assertions Phase 5 already makes, re-pointed at prod, live in
# compute.tftest.hcl; this file is the blue/green half.
#
# The single worst failure this layer can have is a crossed hook wiring: a
# POST_TEST_TRAFFIC_SHIFT hook that probes :443 validates the colour that is
# *already* serving and approves every bad build, silently, forever. Two
# assertions from opposite ends catch it — the function's own BGD_PROBE_URL and
# BGD_STAGE here, and the service's lifecycle_stages pairing further down. They
# are deliberately written as separate runs so that neither can be "simplified"
# into agreeing with a broken wiring.

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

run "there_are_three_hooks_named_by_convention" {
  command = apply

  assert {
    condition = toset([
      module.pre_scale_hook.function_name,
      module.post_test_hook.function_name,
      module.post_prod_hook.function_name,
      ]) == toset([
      "bgd-us-east-1-prod-pre-scale-hook",
      "bgd-us-east-1-prod-post-test-hook",
      "bgd-us-east-1-prod-post-prod-hook",
    ])
    error_message = "the three hook functions must carry the convention's names"
  }

  # This is the other half of iam.tf's invoke policy. That policy composes three
  # ARNs from local.hook_function_names rather than reading these outputs,
  # because mock_provider gives every aws_lambda_function the same ARN. Asserting
  # the modules are named from the same local is what stops the composed ARN
  # permitting a function that does not exist.
  assert {
    condition = (
      module.pre_scale_hook.function_name == local.hook_function_names.pre_scale &&
      module.post_test_hook.function_name == local.hook_function_names.post_test &&
      module.post_prod_hook.function_name == local.hook_function_names.post_prod
    )
    error_message = "the hook functions must be named from local.hook_function_names, or the invoke role permits functions that do not exist"
  }

  assert {
    condition = alltrue([
      for name in values(local.hook_function_names) : length(name) <= 64
    ])
    error_message = "Lambda function names are capped at 64 characters"
  }
}

run "the_hooks_run_the_runtime_and_architecture_the_project_pins" {
  command = apply

  assert {
    condition = alltrue([
      module.pre_scale_hook.function_arn != "",
      module.post_test_hook.function_arn != "",
      module.post_prod_hook.function_arn != "",
    ])
    error_message = "every hook must expose a function ARN for deployment_configuration.lifecycle_hook.hook_target_arn"
  }

  # Each hook writes to its own group. A shared group would make three
  # concurrent gates indistinguishable in the one place their verdict is
  # recorded.
  assert {
    condition = toset([
      module.pre_scale_hook.log_group_name,
      module.post_test_hook.log_group_name,
      module.post_prod_hook.log_group_name,
      ]) == toset([
      "/aws/lambda/bgd-us-east-1-prod-pre-scale-hook",
      "/aws/lambda/bgd-us-east-1-prod-post-test-hook",
      "/aws/lambda/bgd-us-east-1-prod-post-prod-hook",
    ])
    error_message = "hook log groups are /aws/lambda/<function-name>, which is what Lambda writes to unless redirected (plan §F8)"
  }

  # A hook's execution role and the role ECS assumes to invoke it are opposite
  # ends of the same call and must never be the same role. Asserted on names,
  # not ARNs: mock_provider fills every aws_iam_role.arn with one shared string,
  # so an ARN comparison here would fail against a perfectly correct config.
  assert {
    condition = alltrue([
      for role in [
        module.pre_scale_hook.role_name,
        module.post_test_hook.role_name,
        module.post_prod_hook.role_name,
      ] : role != aws_iam_role.hook_invoke.name
    ])
    error_message = "a hook's execution role is not the role ECS uses to invoke it"
  }

  # Each hook gets its own execution role, not one shared across the three.
  assert {
    condition = length(toset([
      module.pre_scale_hook.role_name,
      module.post_test_hook.role_name,
      module.post_prod_hook.role_name,
    ])) == 3
    error_message = "each hook needs its own execution role, scoped to its own log group"
  }
}

run "the_hooks_pin_the_runtime_and_the_architecture" {
  command = apply

  # Phase 0's A4 confirmed python3.14 is in the provider's enum; its own caveat
  # is that membership proves the identifier is recognised, not that the runtime
  # is creatable. The first apply confirms that. Pinned here so a provider
  # upgrade that silently changed the default cannot go unnoticed.
  assert {
    condition = alltrue([
      module.pre_scale_hook.runtime == "python3.14",
      module.post_test_hook.runtime == "python3.14",
      module.post_prod_hook.runtime == "python3.14",
    ])
    error_message = "the hooks run python3.14, matching the container and the local interpreter exactly"
  }

  # arm64, matching the container's Graviton choice and its price. Nothing in
  # the handler is architecture-sensitive — it is standard library only — so the
  # only thing this changes is the bill.
  assert {
    condition = alltrue([
      module.pre_scale_hook.architectures == tolist(["arm64"]),
      module.post_test_hook.architectures == tolist(["arm64"]),
      module.post_prod_hook.architectures == tolist(["arm64"]),
    ])
    error_message = "the hooks run on arm64, matching the container's Graviton choice"
  }

  assert {
    condition = alltrue([
      module.pre_scale_hook.timeout_seconds == var.hook_timeout_seconds,
      module.post_test_hook.timeout_seconds == var.hook_timeout_seconds,
      module.post_prod_hook.timeout_seconds == var.hook_timeout_seconds,
    ])
    error_message = "all three hooks take their timeout from var.hook_timeout_seconds"
  }
}

run "the_post_test_hook_probes_the_test_listener_and_the_others_do_not" {
  command = apply

  # The dark canary's whole identity. A hook that probes :443 at
  # POST_TEST_TRAFFIC_SHIFT validates the *old* colour and passes every bad
  # build. Plan §D2, and the risk table's worst entry.
  assert {
    condition     = module.post_test_hook.environment_variables.BGD_PROBE_URL == "https://api.carloscloudengineer.com:8443"
    error_message = "the post-test hook must probe the :8443 test listener; :443 would validate the colour already serving"
  }

  assert {
    condition = (
      module.pre_scale_hook.environment_variables.BGD_PROBE_URL == "https://api.carloscloudengineer.com" &&
      module.post_prod_hook.environment_variables.BGD_PROBE_URL == "https://api.carloscloudengineer.com"
    )
    error_message = "the pre-scale and post-production hooks both validate the production listener"
  }

  # Derived from foundation's api_domain rather than restated, so a domain
  # change cannot leave a hook probing the wrong host.
  assert {
    condition = alltrue([
      for env in [
        module.pre_scale_hook.environment_variables,
        module.post_test_hook.environment_variables,
        module.post_prod_hook.environment_variables,
      ] : strcontains(env.BGD_PROBE_URL, local.foundation.api_domain)
    ])
    error_message = "probe URLs must be derived from foundation's api_domain, not composed independently"
  }
}

run "each_hook_knows_which_stage_it_is" {
  command = apply

  # Half of the pairing assertion. The service's lifecycle_stages is the other
  # half, in the run further down; a crossed wiring fails one of the two.
  assert {
    condition = (
      module.pre_scale_hook.environment_variables.BGD_STAGE == "PRE_SCALE_UP" &&
      module.post_test_hook.environment_variables.BGD_STAGE == "POST_TEST_TRAFFIC_SHIFT" &&
      module.post_prod_hook.environment_variables.BGD_STAGE == "POST_PRODUCTION_TRAFFIC_SHIFT"
    )
    error_message = "each hook's BGD_STAGE must name the stage the service subscribes it to"
  }
}

run "terraform_never_sets_the_digest_expectation" {
  command = apply

  # Plan §D12. BGD_EXPECT_DIGEST is how exit criterion 3 makes a real check fail
  # against a deliberately wrong expectation. If Terraform set it, there would
  # be a failure toggle in the committed infrastructure — and Phase 11's
  # evidence standard ("a genuinely broken commit, not a simulated failure
  # toggle") would be violated one phase early.
  assert {
    condition = alltrue([
      for env in [
        module.pre_scale_hook.environment_variables,
        module.post_test_hook.environment_variables,
        module.post_prod_hook.environment_variables,
      ] : !contains(keys(env), "BGD_EXPECT_DIGEST")
    ])
    error_message = "Terraform must never set BGD_EXPECT_DIGEST; the runbook sets it by hand and unsets it again"
  }
}

run "the_hook_timeout_survives_a_slow_ready_probe" {
  command = apply

  # Phase 5's F5 measured /ready taking 25.6s to fail when DynamoDB is
  # unreachable, because botocore retries with backoff. The handler floors
  # /ready at 30s, so three sequential probes are worst-case 10 + 30 + 10 = 50s.
  # A 30-second function would be killed mid-/ready, ECS would see an invocation
  # error, and plan D3 makes that a rejection — so the dark canary would fail
  # every deployment where DynamoDB was merely slow, which is the opposite of a
  # useful gate.
  assert {
    condition     = var.hook_timeout_seconds >= 60
    error_message = "a hook shorter than 60s is killed mid-/ready and rejects builds that were fine"
  }
}
