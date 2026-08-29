# The edge. Staging's assertions carry over — the /health health check path, the
# 80-to-443 redirect, the foundation certificate, the TLS 1.3 policy, the
# 32-character names — plus everything blue/green needs that staging has no
# equivalent of: a second target group, a :8443 test listener, and a listener
# *rule* on each of the two serving listeners.
#
# The rules are not a style choice. advanced_configuration takes
# production_listener_rule and test_listener_rule, which are rule ARNs (Phase 0
# A7). A default action cannot be named there, so a listener without a rule
# cannot participate in a blue/green shift at all.

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

run "the_load_balancer_is_public_and_uses_prods_security_group" {
  command = apply

  assert {
    condition     = aws_lb.this.name == "bgd-us-east-1-prod-alb" && length(aws_lb.this.name) <= 32
    error_message = "ALB name breaks the convention or the 32-character cap"
  }

  assert {
    condition     = !aws_lb.this.internal
    error_message = "the production ALB is internet-facing by design"
  }

  assert {
    condition     = aws_lb.this.subnets == toset(["subnet-0mockpuba", "subnet-0mockpubb"])
    error_message = "the ALB belongs in the public subnets"
  }

  # prod's group, not staging's. network deliberately created four groups so the
  # two environments' tasks cannot reach each other, and only prod's ALB group
  # opens :8443 — picking the wrong key here would quietly undo both. Phase 4 §D3.
  assert {
    condition     = aws_lb.this.security_groups == toset(["sg-0mockalbprod"])
    error_message = "the ALB must use the prod ALB security group; staging's does not open :8443"
  }

  assert {
    condition     = !aws_lb.this.enable_deletion_protection
    error_message = "deletion protection would break make teardown"
  }

  assert {
    condition     = aws_lb.this.drop_invalid_header_fields
    error_message = "malformed headers should be dropped at the edge rather than reaching the application"
  }
}

run "the_two_target_groups_are_symmetric_and_health_check_liveness_only" {
  command = apply

  assert {
    condition = (
      aws_lb_target_group.blue.name == "bgd-us-east-1-prod-api-blue" &&
      aws_lb_target_group.green.name == "bgd-us-east-1-prod-api-green"
    )
    error_message = "target group names break the convention"
  }

  # bgd-us-east-1-prod-api-green at 28 is the longest name the whole project
  # produces, and it is the name the convention's §1 worked the bgd prefix out
  # from. If this ever exceeds 32 the prefix itself is wrong, not this line.
  assert {
    condition = alltrue([
      length(aws_lb_target_group.blue.name) <= 32,
      length(aws_lb_target_group.green.name) <= 32,
    ])
    error_message = "target group names are capped at 32 characters"
  }

  # Identical but for the name. An asymmetry between them means the two colours
  # are not interchangeable, and blue/green stops being a swap: a deployment
  # would behave differently depending on which colour it happened to land on.
  assert {
    condition = (
      aws_lb_target_group.blue.port == aws_lb_target_group.green.port &&
      aws_lb_target_group.blue.protocol == aws_lb_target_group.green.protocol &&
      aws_lb_target_group.blue.target_type == aws_lb_target_group.green.target_type &&
      aws_lb_target_group.blue.vpc_id == aws_lb_target_group.green.vpc_id &&
      aws_lb_target_group.blue.deregistration_delay == aws_lb_target_group.green.deregistration_delay
    )
    error_message = "the two target groups must be identical but for their names, or the colours are not interchangeable"
  }

  assert {
    condition = (
      one(aws_lb_target_group.blue.health_check).path == one(aws_lb_target_group.green.health_check).path &&
      one(aws_lb_target_group.blue.health_check).interval == one(aws_lb_target_group.green.health_check).interval &&
      one(aws_lb_target_group.blue.health_check).healthy_threshold == one(aws_lb_target_group.green.health_check).healthy_threshold &&
      one(aws_lb_target_group.blue.health_check).unhealthy_threshold == one(aws_lb_target_group.green.health_check).unhealthy_threshold
    )
    error_message = "the two target groups must health check identically"
  }

  # /health, never /ready — staging's reason doubled. /health reports only
  # whether the process is alive; health-checking /ready would let one DynamoDB
  # hiccup deregister every target in BOTH groups at once, mid-shift. The dark
  # canary is where /ready belongs, and the post-test hook is what probes it.
  assert {
    condition = (
      one(aws_lb_target_group.blue.health_check).path == "/health" &&
      one(aws_lb_target_group.green.health_check).path == "/health"
    )
    error_message = "both target groups must poll /health; /ready would deregister every target in both groups on a DynamoDB hiccup"
  }

  # ip, not instance: awsvpc network mode gives each Fargate task its own ENI
  # and there is no instance to register.
  assert {
    condition = (
      aws_lb_target_group.blue.target_type == "ip" &&
      aws_lb_target_group.blue.port == 8080
    )
    error_message = "Fargate tasks register by IP on the container port network opened"
  }
}

run "there_are_three_listeners_and_only_two_serve" {
  command = apply

  assert {
    condition     = one(aws_lb_listener.http.default_action).type == "redirect"
    error_message = "port 80 must redirect rather than serve"
  }

  assert {
    condition = (
      one(one(aws_lb_listener.http.default_action).redirect).port == "443" &&
      one(one(aws_lb_listener.http.default_action).redirect).status_code == "HTTP_301"
    )
    error_message = "the redirect must be a permanent redirect to 443"
  }

  assert {
    condition = (
      aws_lb_listener.https.port == 443 &&
      aws_lb_listener.test.port == 8443
    )
    error_message = "production serves on 443 and the test listener on 8443, the port network's prod ALB group opens"
  }

  # Without a :8443 listener there is no dark canary, and test_listener_rule has
  # nothing to point at.
  assert {
    condition = (
      aws_lb_listener.https.certificate_arn == "arn:aws:acm:us-east-1:590184028094:certificate/mock" &&
      aws_lb_listener.test.certificate_arn == "arn:aws:acm:us-east-1:590184028094:certificate/mock"
    )
    error_message = "both serving listeners must use the certificate foundation issued; the test listener is TLS too"
  }

  # A certificate on the redirect listener would be a sign someone made :80
  # serve traffic.
  assert {
    condition     = aws_lb_listener.http.certificate_arn == null || aws_lb_listener.http.certificate_arn == ""
    error_message = "the redirect listener must not carry a certificate; it serves nothing"
  }

  assert {
    condition = (
      aws_lb_listener.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06" &&
      aws_lb_listener.test.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    )
    error_message = "both TLS listeners must use the TLS 1.2 floor with 1.3 support"
  }

  # The rules carry /*, so a default action is unreachable in normal operation —
  # which is exactly why it should refuse rather than forward. A forwarding
  # default would keep serving from whichever target group it named if a rule
  # were ever deleted, and the colour it named would be the wrong one half the
  # time.
  assert {
    condition = (
      one(aws_lb_listener.https.default_action).type == "fixed-response" &&
      one(aws_lb_listener.test.default_action).type == "fixed-response"
    )
    error_message = "both serving listeners must default to a fixed response, not a forward to a stale target group"
  }

  assert {
    condition = (
      one(one(aws_lb_listener.https.default_action).fixed_response).status_code == "503" &&
      one(one(aws_lb_listener.test.default_action).fixed_response).status_code == "503"
    )
    error_message = "the unreachable default must be a 503, so a missing rule fails loudly"
  }
}

run "each_serving_listener_carries_a_rule_and_they_start_on_opposite_colours" {
  command = apply

  # The initial assignment. ECS swaps them from here, which is why nothing else
  # in this layer may assume blue is production after the first deployment.
  assert {
    condition     = one(aws_lb_listener_rule.production.action).target_group_arn == aws_lb_target_group.blue.arn
    error_message = "the :443 rule forwards to blue at creation; ECS swaps it from there"
  }

  assert {
    condition     = one(aws_lb_listener_rule.test.action).target_group_arn == aws_lb_target_group.green.arn
    error_message = "the :8443 rule forwards to green at creation, so the test listener starts on the idle colour"
  }

  assert {
    condition = (
      aws_lb_listener_rule.production.listener_arn == aws_lb_listener.https.arn &&
      aws_lb_listener_rule.test.listener_arn == aws_lb_listener.test.arn
    )
    error_message = "each rule must belong to its own listener"
  }

  # A rule without a condition is invalid; two rules without priorities collide.
  assert {
    condition = (
      one(one(aws_lb_listener_rule.production.condition).path_pattern).values == toset(["/*"]) &&
      one(one(aws_lb_listener_rule.test.condition).path_pattern).values == toset(["/*"])
    )
    error_message = "both rules need a /* path condition; a rule without a condition is invalid"
  }

  assert {
    condition = (
      aws_lb_listener_rule.production.priority != null &&
      aws_lb_listener_rule.test.priority != null
    )
    error_message = "both rules need an explicit priority"
  }
}

run "the_hostname_aliases_this_environments_load_balancer" {
  command = apply

  # api., not staging-api. Read from foundation rather than composed here, so
  # this layer and foundation cannot disagree about the hostname.
  assert {
    condition     = aws_route53_record.api.name == "api.carloscloudengineer.com"
    error_message = "the record must use the api hostname foundation derives, not one composed here"
  }

  assert {
    condition     = aws_route53_record.api.zone_id == "Z0MOCKZONEID000"
    error_message = "the record belongs in the hosted zone foundation owns"
  }

  assert {
    condition     = aws_route53_record.api.type == "A"
    error_message = "an alias A record is what fronts an ALB; a CNAME would not work at an apex and costs a lookup"
  }

  assert {
    condition     = one(aws_route53_record.api.alias).name == "mock-alb-123.us-east-1.elb.amazonaws.com"
    error_message = "the alias must target this layer's own load balancer"
  }

  # Load-bearing here rather than merely a good default: during a blue/green
  # shift, health is the signal that a colour is serving.
  assert {
    condition     = one(aws_route53_record.api.alias).evaluate_target_health
    error_message = "evaluate_target_health is how Route 53 stops answering with an ALB that has no healthy targets"
  }
}
