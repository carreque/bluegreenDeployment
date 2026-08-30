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

# --- distinct ARNs for the two roles D4 exists to keep apart ------------------
#
# mock_provider fills every aws_iam_role.arn with one shared string, so an
# assertion that the hooks are invoked through hook_invoke and the listener
# rules rewritten by bluegreen would pass even if both slots named the SAME
# role — which is precisely the mistake D4 exists to prevent. These two
# overrides give each role an ARN that says which one it is, so those
# assertions discriminate instead of passing vacuously.
#
# Only this file needs them: it is the only one that asserts on which role
# landed in which slot of the service.
override_resource {
  target = aws_iam_role.bluegreen
  values = {
    arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-prod-bluegreen-role"
  }
}

override_resource {
  target = aws_iam_role.hook_invoke
  values = {
    arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-prod-hook-invoke-role"
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

# --- the four alarms the bake period is gated on -----------------------------

run "there_are_exactly_four_bake_alarms_named_by_convention" {
  command = apply

  assert {
    condition = toset(local.bake_alarm_names) == toset([
      "bgd-us-east-1-prod-target-5xx",
      "bgd-us-east-1-prod-p95-latency",
      "bgd-us-east-1-prod-unhealthy-blue",
      "bgd-us-east-1-prod-unhealthy-green",
    ])
    error_message = "local.bake_alarm_names must name exactly the four alarms this layer builds"
  }

  # Task 8 feeds this list straight into alarms.alarm_names. A missing member is
  # a silent gap in the gate: the deployment still succeeds, the bake still
  # runs, and it simply observes one fewer thing.
  assert {
    condition     = length(local.bake_alarm_names) == 4
    error_message = "a missing alarm name is a silent gap in the bake gate"
  }

  assert {
    condition = toset(local.bake_alarm_names) == toset([
      aws_cloudwatch_metric_alarm.five_xx.alarm_name,
      aws_cloudwatch_metric_alarm.p95_latency.alarm_name,
      aws_cloudwatch_metric_alarm.unhealthy["blue"].alarm_name,
      aws_cloudwatch_metric_alarm.unhealthy["green"].alarm_name,
    ])
    error_message = "the names in local.bake_alarm_names must be the alarms that actually exist, or ECS bakes against alarms that were never created"
  }
}

run "the_user_facing_alarms_measure_the_whole_load_balancer" {
  command = apply

  # LoadBalancer only, deliberately. These two measure what users actually
  # experience, which is the rollback criterion. Scoping them per target group
  # would also trip on the *old* group's errors as it drains, which is not a
  # reason to roll back a promotion that already happened. Plan §D8.
  assert {
    condition = (
      toset(keys(aws_cloudwatch_metric_alarm.five_xx.dimensions)) == toset(["LoadBalancer"]) &&
      toset(keys(aws_cloudwatch_metric_alarm.p95_latency.dimensions)) == toset(["LoadBalancer"])
    )
    error_message = "the 5xx and latency alarms carry only the LoadBalancer dimension; per-group scoping trips on the old colour draining"
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.five_xx.metric_name == "HTTPCode_Target_5XX_Count" &&
      aws_cloudwatch_metric_alarm.p95_latency.metric_name == "TargetResponseTime"
    )
    error_message = "the two user-facing alarms must measure target 5xx responses and target response time"
  }

  # An average hides the tail the design named. p95 is the statistic, and
  # extended_statistic is the only field that can express it — statistic
  # = "Average" would pass every deployment where most requests were fine.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.p95_latency.extended_statistic == "p95" &&
      (aws_cloudwatch_metric_alarm.p95_latency.statistic == null || aws_cloudwatch_metric_alarm.p95_latency.statistic == "")
    )
    error_message = "the latency alarm must use extended_statistic p95; an average hides the tail"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.p95_latency.threshold == var.alarm_p95_seconds
    error_message = "the latency threshold comes from var.alarm_p95_seconds so it can be corrected in one place"
  }
}

run "the_unhealthy_host_alarms_are_per_target_group_because_they_must_be" {
  command = apply

  # UnHealthyHostCount has no LoadBalancer-only form — CloudWatch publishes it
  # per target group, because "unhealthy" is a property of a target's
  # registration in a group rather than of the load balancer. So it takes two
  # alarms, one per colour, both listed in alarm_names. Plan §F3.
  assert {
    condition = alltrue([
      for colour in ["blue", "green"] :
      toset(keys(aws_cloudwatch_metric_alarm.unhealthy[colour].dimensions)) == toset(["LoadBalancer", "TargetGroup"])
    ])
    error_message = "UnHealthyHostCount is published per target group; both dimensions are required (plan §F3)"
  }

  assert {
    condition = alltrue([
      for colour in ["blue", "green"] :
      aws_cloudwatch_metric_alarm.unhealthy[colour].metric_name == "UnHealthyHostCount"
    ])
    error_message = "both colour alarms must measure UnHealthyHostCount"
  }

  # for_each over the two groups, so they cannot drift apart. If one colour's
  # alarm were ever configured differently from the other's, deployments would
  # be gated more strictly in one direction than the other.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.unhealthy["blue"].threshold == aws_cloudwatch_metric_alarm.unhealthy["green"].threshold &&
      aws_cloudwatch_metric_alarm.unhealthy["blue"].period == aws_cloudwatch_metric_alarm.unhealthy["green"].period &&
      aws_cloudwatch_metric_alarm.unhealthy["blue"].evaluation_periods == aws_cloudwatch_metric_alarm.unhealthy["green"].evaluation_periods
    )
    error_message = "the two colour alarms must be identical, or deployments are gated more strictly in one direction"
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.unhealthy["blue"].dimensions["TargetGroup"] != aws_cloudwatch_metric_alarm.unhealthy["green"].dimensions["TargetGroup"]
    )
    error_message = "the two colour alarms must watch different target groups, or one colour is unmonitored"
  }
}

run "every_alarm_can_evaluate_inside_a_five_minute_bake" {
  command = apply

  # Forced, not a matter of taste: a five-minute bake cannot be gated by an
  # alarm that needs five minutes to evaluate.
  assert {
    condition = alltrue([
      for alarm in [
        aws_cloudwatch_metric_alarm.five_xx,
        aws_cloudwatch_metric_alarm.p95_latency,
        aws_cloudwatch_metric_alarm.unhealthy["blue"],
        aws_cloudwatch_metric_alarm.unhealthy["green"],
      ] : alarm.period == 60 && alarm.evaluation_periods <= 2
    ])
    error_message = "60-second periods and at most two datapoints; a slower alarm cannot fire inside the bake it gates"
  }

  # Load-bearing rather than cosmetic. The idle target group publishes no
  # UnHealthyHostCount at all, so the CloudWatch default would park that alarm
  # permanently in INSUFFICIENT_DATA — and whether ECS treats INSUFFICIENT_DATA
  # as breaching is not something to find out during a production shift.
  assert {
    condition = alltrue([
      for alarm in [
        aws_cloudwatch_metric_alarm.five_xx,
        aws_cloudwatch_metric_alarm.p95_latency,
        aws_cloudwatch_metric_alarm.unhealthy["blue"],
        aws_cloudwatch_metric_alarm.unhealthy["green"],
      ] : alarm.treat_missing_data == "notBreaching"
    ])
    error_message = "the idle target group publishes nothing; without notBreaching its alarm never leaves INSUFFICIENT_DATA"
  }

  # Plan §D9 created these with no actions, so that Phase 9 could attach to the
  # same alarms rather than create parallel ones. Phase 9 (D12) did. The
  # assertion is inverted rather than deleted, because the property worth
  # protecting is still there — it just moved from "nobody is notified" to
  # "notification goes to the one topic this project owns, read from
  # foundation's output rather than written out by hand".
  #
  # ok_actions stays empty: an alarm returning to OK during a bake is the normal
  # end of every successful deployment, and mailing that would train the
  # recipient to filter the topic. Phase 9 §D16.
  assert {
    condition = alltrue([
      for alarm in [
        aws_cloudwatch_metric_alarm.five_xx,
        aws_cloudwatch_metric_alarm.p95_latency,
        aws_cloudwatch_metric_alarm.unhealthy["blue"],
        aws_cloudwatch_metric_alarm.unhealthy["green"],
      ] : alarm.alarm_actions == toset([local.foundation.alerts_topic_arn]) && coalesce(try(length(alarm.ok_actions), 0), 0) == 0
    ])
    error_message = "every bake alarm notifies the alert topic and none carries ok_actions (Phase 9 §D12, §D16)"
  }
}

# --- the service: the centre of the phase ------------------------------------

run "the_service_deploys_blue_green_and_bakes" {
  command = apply

  # The one word that is the entire difference from staging, which writes
  # ROLLING in the same slot.
  assert {
    condition     = one(aws_ecs_service.api.deployment_configuration).strategy == "BLUE_GREEN"
    error_message = "this layer's whole purpose is strategy = BLUE_GREEN"
  }

  # A STRING, not a number. bake_time_in_minutes is typed string in the provider
  # schema (plan §F1) and the number form fails terraform validate. Asserting
  # the string keeps it that way through a future refactor.
  assert {
    condition     = one(aws_ecs_service.api.deployment_configuration).bake_time_in_minutes == "5"
    error_message = "bake_time_in_minutes is a string in the provider schema; the number form fails validate"
  }

  # Plan §D11. Without it terraform apply returns success the moment ECS accepts
  # the deployment, and every part of blue/green that matters — the hooks, the
  # shift, the bake, an alarm rollback — happens after Terraform has already
  # reported success. A rolled-back deployment would leave a green plan over a
  # red service. On the one layer whose purpose is deployment safety, an apply
  # that cannot fail when the deployment fails is the wrong default.
  assert {
    condition     = aws_ecs_service.api.wait_for_steady_state
    error_message = "without wait_for_steady_state a rolled-back deployment still reports a successful apply (plan §D11)"
  }

  # Deliberately absent, and asserted so the omission reads as a decision rather
  # than a gap. The bake period with alarms IS this environment's rollback
  # mechanism; whether the two interact, and in what order they would each try
  # to revert, is not documented in the schema and not something to discover
  # during a production shift. Staging sets it; this layer does not.
  assert {
    condition     = length(aws_ecs_service.api.deployment_circuit_breaker) == 0
    error_message = "no circuit breaker here: one rollback mechanism, chosen on purpose (plan Task 8)"
  }

  assert {
    condition     = aws_ecs_service.api.desired_count == 2
    error_message = "production runs two tasks across two AZs (plan §D13)"
  }
}

run "the_bake_is_gated_on_exactly_the_four_alarms" {
  command = apply

  # Omitting the alarms block entirely means the five-minute bake observes
  # nothing and rolls back on nothing. The deployment still succeeds, so the gap
  # is silent — which is why this is asserted rather than trusted.
  assert {
    condition     = toset(one(aws_ecs_service.api.alarms).alarm_names) == toset(local.bake_alarm_names)
    error_message = "the bake must be wired to the four alarms alarms.tf built, not to an empty set"
  }

  assert {
    condition = (
      one(aws_ecs_service.api.alarms).enable &&
      one(aws_ecs_service.api.alarms).rollback
    )
    error_message = "alarms.enable and alarms.rollback are both required booleans; there is no just-list-them form"
  }
}

run "there_are_three_lifecycle_hooks_one_per_stage" {
  command = apply

  # A missing hook is a missing gate, and lifecycle_hook is a SET — it gives no
  # ordering to notice an absence by. Counting is the only way.
  assert {
    condition     = length(one(aws_ecs_service.api.deployment_configuration).lifecycle_hook) == 3
    error_message = "three hooks, one per stage; a set gives no ordering to notice a missing one by"
  }

  # One stage each, and exactly these three. A hook subscribed to two stages
  # would run the same probe at two different moments and report the same
  # answer, which reads as a passing gate that tested nothing.
  assert {
    condition = toset(flatten([
      for hook in one(aws_ecs_service.api.deployment_configuration).lifecycle_hook :
      hook.lifecycle_stages
      ])) == toset([
      "PRE_SCALE_UP",
      "POST_TEST_TRAFFIC_SHIFT",
      "POST_PRODUCTION_TRAFFIC_SHIFT",
    ])
    error_message = "the three hooks must cover exactly the three stages"
  }

  assert {
    condition = alltrue([
      for hook in one(aws_ecs_service.api.deployment_configuration).lifecycle_hook :
      length(hook.lifecycle_stages) == 1
    ])
    error_message = "each hook subscribes to exactly one stage"
  }

  # THE PAIRING ASSERTION. Task 5 asserted the function half — that the
  # post-test hook's BGD_PROBE_URL is :8443 and its BGD_STAGE says
  # POST_TEST_TRAFFIC_SHIFT. This is the other half: that the function ECS
  # invokes at POST_TEST_TRAFFIC_SHIFT is that same function.
  #
  # Crossed, the dark canary would run against the production listener and
  # approve every bad build — silently, forever, with a green deployment each
  # time. The two halves are in different runs on purpose so neither can be
  # "simplified" into agreeing with a broken wiring.
  assert {
    condition = alltrue([
      for hook in one(aws_ecs_service.api.deployment_configuration).lifecycle_hook :
      hook.hook_target_arn == lookup({
        PRE_SCALE_UP                  = module.pre_scale_hook.function_arn
        POST_TEST_TRAFFIC_SHIFT       = module.post_test_hook.function_arn
        POST_PRODUCTION_TRAFFIC_SHIFT = module.post_prod_hook.function_arn
      }, hook.lifecycle_stages[0], "no such stage")
    ])
    error_message = "each stage must invoke the function built for it; a crossed wiring makes the dark canary validate the old colour"
  }

  # Plan §D4, one direction. Every hook is invoked through hook_invoke, never
  # through the role that rewrites listener rules.
  assert {
    condition = alltrue([
      for hook in one(aws_ecs_service.api.deployment_configuration).lifecycle_hook :
      hook.role_arn == aws_iam_role.hook_invoke.arn && hook.role_arn != aws_iam_role.bluegreen.arn
    ])
    error_message = "the hooks are invoked through hook_invoke, never through the blue/green controller role"
  }
}

run "the_load_balancer_block_names_both_colours_and_both_rules" {
  command = apply

  # ONE load_balancer block, not two. Two is the shape people expect and the
  # provider does not accept: one target group goes in target_group_arn and the
  # other in advanced_configuration.alternate_target_group_arn. Plan §F1.
  assert {
    condition     = length(aws_ecs_service.api.load_balancer) == 1
    error_message = "blue/green is one load_balancer block with an alternate group, not two blocks"
  }

  assert {
    condition = (
      one(aws_ecs_service.api.load_balancer).target_group_arn == aws_lb_target_group.blue.arn &&
      one(one(aws_ecs_service.api.load_balancer).advanced_configuration).alternate_target_group_arn == aws_lb_target_group.green.arn
    )
    error_message = "the service must name blue as the initial production group and green as the alternate"
  }

  # RULE ARNs, not listener ARNs. Passing a listener ARN is an apply-time
  # failure with a message that names the attribute but not the reason. Phase 0
  # A7 is the finding; alb.tf's two rules exist for this line alone.
  assert {
    condition = (
      one(one(aws_ecs_service.api.load_balancer).advanced_configuration).production_listener_rule == aws_lb_listener_rule.production.arn &&
      one(one(aws_ecs_service.api.load_balancer).advanced_configuration).test_listener_rule == aws_lb_listener_rule.test.arn
    )
    error_message = "advanced_configuration takes listener RULE arns; a listener arn fails at apply with a message that names the attribute, not the reason"
  }

  # Plan §D4, the other direction. The rule-rewriter is bluegreen, never the
  # role that can invoke Lambdas.
  assert {
    condition = (
      one(one(aws_ecs_service.api.load_balancer).advanced_configuration).role_arn == aws_iam_role.bluegreen.arn &&
      one(one(aws_ecs_service.api.load_balancer).advanced_configuration).role_arn != aws_iam_role.hook_invoke.arn
    )
    error_message = "the listener rules are rewritten by the bluegreen role, never by the hook invoker"
  }

  assert {
    condition = (
      one(aws_ecs_service.api.load_balancer).container_name == "api" &&
      one(aws_ecs_service.api.load_balancer).container_port == 8080
    )
    error_message = "the load_balancer block's container name and port must match the task definition's"
  }
}
