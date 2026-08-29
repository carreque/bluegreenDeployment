# The environment's entire ingress path, and the largest single departure from
# staging's shape.
#
# Two listeners carry traffic and one redirects. The production listener is :443
# and the test listener is :8443 — the port network's prod ALB security group
# already opens, and the reason that group differs from staging's. Phase 4's D3
# decision to build four security groups rather than two shared ones is what
# makes this layer never have to reopen network.
#
# Both serving listeners carry an aws_lb_listener_rule rather than relying on
# their default action, and that is not a style choice: advanced_configuration
# takes production_listener_rule and test_listener_rule, which are *rule* ARNs
# (Phase 0 A7). A default action cannot be named there, so a listener without a
# rule cannot participate in a blue/green shift at all.
#
# The default actions are therefore a fixed 503. Each rule matches /*, so the
# default is unreachable while the rules exist — which is precisely why it should
# refuse rather than forward. A forwarding default would keep serving from
# whichever target group it named if a rule were ever removed, and the colour it
# named would be the wrong one half the time.

resource "aws_lb" "this" {
  # checkov:skip=CKV_AWS_150:deletion protection would make terraform destroy fail and break make teardown, which is the policy the five-layer split exists to serve (roadmap §1). This environment is destroyed at the end of every session and rebuilt from the same code.
  # checkov:skip=CKV_AWS_91:access logging is off for production too, decided again rather than inherited. Phase 5's D5 deferred this decision to this phase on the grounds that access logs are genuine blue/green evidence here; having looked at what the evidence actually needs to be, they are not. The three exit criteria are met by /version on :443 versus :8443 during a deployment, the ECS deployment-stage transitions, and the hook Lambdas' own log output — all available within seconds. ALB access logs are delivered to S3 on a roughly five-minute lag, which is longer than the deployment they would document. Enabling them also requires either a bucket policy in foundation, a layer this phase is scoped not to touch, or a bucket in prod that make teardown destroys along with every log in it. Plan §D7.
  # checkov:skip=CKV2_AWS_28:a WAF web ACL is a monthly charge plus per-request billing for a demo API with no attack surface worth the spend, and was never part of the design.
  name               = "${local.env_prefix}-alb"
  load_balancer_type = "application"
  internal           = false

  subnets         = local.network.public_subnet_ids
  security_groups = [local.network.alb_security_group_ids[local.environment]]

  # Requests with malformed headers are rejected at the edge rather than being
  # normalised and passed on, which is where request smuggling starts.
  drop_invalid_header_fields = true

  enable_deletion_protection = false
}

# --- two target groups, identical but for their names ------------------------
#
# Which one is "production" is not a property of either group — it is whichever
# one the :443 listener rule currently forwards to, and ECS swaps that during
# every deployment. Nothing in this layer may assume blue is production after
# the first deployment, which is also why the bake alarms in alarms.tf are
# LoadBalancer-scoped rather than per-group wherever CloudWatch allows it.
#
# An asymmetry between these two would mean the colours are not interchangeable,
# and a deployment would behave differently depending on which colour it landed
# on. tests/edge.tftest.hcl asserts every shared attribute matches.

resource "aws_lb_target_group" "blue" {
  # checkov:skip=CKV_AWS_378:HTTP between the ALB and the task, which is the design and not an oversight — TLS terminates at the load balancer, and the hop behind it is inside the VPC, to a private subnet, over a security group that accepts traffic from the ALB's group alone (Phase 4 §D3). Worth recording WHY this fires here and not on staging's identically-configured target group: staging's HTTPS listener forwards to its target group directly, so checkov's graph sees a TLS listener in front of it. This layer's listeners default to a fixed 503 and reach the groups through aws_lb_listener_rule instead — because advanced_configuration takes rule ARNs (Phase 0 A7) — and the check cannot follow that edge. The protocol is the same in both layers; only checkov's visibility differs.
  name        = "${local.env_prefix}-api-blue"
  port        = local.container_port
  protocol    = "HTTP"
  vpc_id      = local.network.vpc_id
  target_type = "ip"

  # The default is 300 seconds. On a blue/green deployment that is 300 seconds
  # held at the end of every shift before the old colour finishes draining.
  # Thirty is long enough to finish in-flight requests for an API whose slowest
  # measured response is a DynamoDB query.
  deregistration_delay = 30

  # /health, not /ready — staging's reason doubled. /health reports only whether
  # the process is alive; /ready checks DynamoDB. Polling /ready here would let
  # a single DynamoDB hiccup deregister every target in BOTH groups at once,
  # mid-shift. /ready belongs in the dark canary, and hooks.tf is what probes it.
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "green" {
  # checkov:skip=CKV_AWS_378:HTTP between the ALB and the task, which is the design and not an oversight — TLS terminates at the load balancer, and the hop behind it is inside the VPC, to a private subnet, over a security group that accepts traffic from the ALB's group alone (Phase 4 §D3). Worth recording WHY this fires here and not on staging's identically-configured target group: staging's HTTPS listener forwards to its target group directly, so checkov's graph sees a TLS listener in front of it. This layer's listeners default to a fixed 503 and reach the groups through aws_lb_listener_rule instead — because advanced_configuration takes rule ARNs (Phase 0 A7) — and the check cannot follow that edge. The protocol is the same in both layers; only checkov's visibility differs.
  name        = "${local.env_prefix}-api-green"
  port        = local.container_port
  protocol    = "HTTP"
  vpc_id      = local.network.vpc_id
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# --- three listeners ---------------------------------------------------------

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # Redirect rather than serve. network's ALB security group opens 80 to the
  # world so a browser typing the hostname reaches something; this is the
  # something, and nothing behind it serves plaintext. No certificate here —
  # one would be a sign someone made :80 serve traffic.
  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"

  # TLS 1.2 floor with 1.3 support. The certificate lives in foundation and
  # outlives every teardown, which is why it is referenced through remote state
  # rather than issued here — a rebuild must not re-validate a certificate.
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = local.foundation.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "no listener rule matched"
      status_code  = "503"
    }
  }
}

# The test listener. Without it there is no dark canary and test_listener_rule
# has nothing to point at.
#
# TLS, on the same foundation certificate, not plain HTTP. The certificate is
# issued for this hostname and a wildcard is not needed for a port change, and
# the dark canary must exercise the same path a user would — a hook that
# validated green over plaintext would not be testing what production serves.
resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.this.arn
  port              = 8443
  protocol          = "HTTPS"

  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = local.foundation.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "no listener rule matched"
      status_code  = "503"
    }
  }
}

# --- the two rules blue/green actually shifts --------------------------------
#
# These are what advanced_configuration names, and what ECS rewrites mid-shift.
# The colours below are the *initial* assignment only: after the first
# deployment, which rule points at which group is ECS's business and Terraform
# must not fight it — which is why ecs.tf takes no lifecycle ignore_changes on
# them, and why nothing else in this layer reads them to decide what is serving.

resource "aws_lb_listener_rule" "production" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

resource "aws_lb_listener_rule" "test" {
  listener_arn = aws_lb_listener.test.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}
