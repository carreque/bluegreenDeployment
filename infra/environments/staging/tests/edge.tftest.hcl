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

run "the_load_balancer_is_public_and_uses_this_environments_security_group" {
  command = apply

  assert {
    condition     = aws_lb.this.name == "bgd-us-east-1-staging-alb" && length(aws_lb.this.name) <= 32
    error_message = "ALB name breaks the convention or the 32-character cap"
  }

  assert {
    condition     = !aws_lb.this.internal
    error_message = "the staging ALB is internet-facing by design"
  }

  assert {
    condition     = aws_lb.this.subnets == toset(["subnet-0mockpuba", "subnet-0mockpubb"])
    error_message = "the ALB belongs in the public subnets"
  }

  # The staging group, not prod's. network deliberately created four groups so
  # the two environments' tasks cannot reach each other — picking the wrong key
  # here would quietly undo that. Phase 4 §D3.
  assert {
    condition     = aws_lb.this.security_groups == toset(["sg-0mockalbstaging"])
    error_message = "the ALB must use the staging ALB security group, not prod's"
  }

  # Deletion protection is off deliberately, and it is not an oversight: enabled,
  # it makes terraform destroy fail and breaks make teardown.
  assert {
    condition     = !aws_lb.this.enable_deletion_protection
    error_message = "deletion protection would break make teardown"
  }

  assert {
    condition     = aws_lb.this.drop_invalid_header_fields
    error_message = "malformed headers should be dropped at the edge rather than reaching the application"
  }
}

run "the_target_group_health_checks_liveness_only" {
  command = apply

  assert {
    condition     = aws_lb_target_group.api.name == "bgd-us-east-1-staging-api" && length(aws_lb_target_group.api.name) <= 32
    error_message = "target group name breaks the convention or the 32-character cap"
  }

  # ip, not instance: awsvpc network mode gives each Fargate task its own ENI
  # and there is no instance to register.
  assert {
    condition     = aws_lb_target_group.api.target_type == "ip"
    error_message = "Fargate tasks register by IP; an instance target type cannot work with awsvpc"
  }

  # /health, never /ready. /health reports only whether the process is alive.
  # Health-checking /ready would let one DynamoDB hiccup deregister every task
  # at once — the reason the two endpoints are separate at all. See the
  # docstring in app/src/bgd/api/routers/health.py.
  assert {
    condition     = one(aws_lb_target_group.api.health_check).path == "/health"
    error_message = "the health check must poll /health; /ready would deregister every task on a DynamoDB hiccup"
  }

  assert {
    condition     = aws_lb_target_group.api.port == 8080
    error_message = "the target group port must match the container port network opened"
  }

  # 300 seconds is the default and far too slow for a rolling deployment of one
  # task: every deploy would hold the old task draining for five minutes.
  assert {
    condition     = aws_lb_target_group.api.deregistration_delay == "30"
    error_message = "the default 300s deregistration delay makes every rolling deployment take five minutes"
  }
}

run "http_redirects_and_https_terminates_with_the_foundation_certificate" {
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
    condition     = aws_lb_listener.https.certificate_arn == "arn:aws:acm:us-east-1:590184028094:certificate/mock"
    error_message = "the HTTPS listener must use the certificate foundation issued, read through remote state"
  }

  assert {
    condition     = aws_lb_listener.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "the TLS policy must be the TLS 1.2 floor with 1.3 support"
  }

  # Staging has exactly one listener beyond the redirect. Production adds :8443
  # in Phase 6, and network already opened that port on prod's group alone.
  assert {
    condition     = aws_lb_listener.https.port == 443
    error_message = "staging serves on 443 only; the 8443 test listener is Phase 6 and production-only"
  }
}
