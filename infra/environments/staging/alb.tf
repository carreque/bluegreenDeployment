# The environment's entire ingress path. One listener pair — 80 redirecting to
# 443 — and one target group. Production's shape in Phase 6 differs by a second
# target group and the :8443 test listener; everything in this file is the part
# that blue/green does not change, which is why staging is built first.

resource "aws_lb" "this" {
  # checkov:skip=CKV_AWS_150:deletion protection would make terraform destroy fail and break make teardown, which is the policy the five-layer split exists to serve (roadmap §1).
  # checkov:skip=CKV_AWS_91:access logging is deliberately off for staging, which carries no production data; the ALB's CloudWatch metrics and Phase 4's VPC flow logs answer the questions it would. Enabling it means either a bucket policy in foundation or a bucket in this disposable layer. Phase 6 decides separately for production, where access logs are genuine blue/green evidence. Plan §D5.
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

resource "aws_lb_target_group" "api" {
  name        = "${local.env_prefix}-api"
  port        = local.container_port
  protocol    = "HTTP"
  vpc_id      = local.network.vpc_id
  target_type = "ip"

  # The default is 300 seconds. With one task, every rolling deployment would
  # then hold the old task draining for five minutes before the deployment
  # completed. Thirty is long enough to finish in-flight requests for an API
  # whose slowest measured response is a DynamoDB query.
  deregistration_delay = 30

  # /health, not /ready — and this is the whole reason the application has two
  # endpoints. /health reports only whether the process is alive; /ready checks
  # DynamoDB. Polling /ready here would let a single DynamoDB hiccup deregister
  # every healthy task at once. See app/src/bgd/api/routers/health.py.
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # Redirect rather than serve. network's ALB security group opens 80 to the
  # world so a browser typing the hostname reaches something; this is the
  # something, and nothing behind it serves plaintext.
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

  # A default action, not a listener rule. Phase 6's production listener needs
  # an aws_lb_listener_rule because advanced_configuration takes a rule ARN
  # (design §5, amended in Phase 0); staging shifts no traffic and needs none.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
