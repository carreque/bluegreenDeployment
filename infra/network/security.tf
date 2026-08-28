# Rules are separate resources rather than inline ingress/egress blocks. Inline
# blocks are authoritative for the whole group, so anything added out of band is
# silently reverted on the next apply and Terraform reports no drift in between.
# The per-rule resources also give each rule its own description, which is what
# the console shows when someone is trying to work out why a packet was dropped.

locals {
  environments = toset(["staging", "prod"])
}

# `description` and `name` are both ForceNew, so changing either replaces the
# group. `create_before_destroy` is deliberately NOT set: with the literal
# name the naming convention requires (not `name_prefix`, which would append a
# random suffix and break the tests asserting exact names), create-before-
# destroy would try to create the replacement alongside the original in the
# same VPC and fail on a duplicate name — there is no clean way to rename in
# place with a fixed name.
#
# Once Phases 5 and 6 attach these groups to an ALB and an ECS service, a
# ForceNew change here requires detaching there first: AWS refuses to delete
# a security group that is still in use, and those layers are different state
# files, so this layer's Terraform cannot sequence the detach for them.
resource "aws_security_group" "alb" {
  # checkov:skip=CKV2_AWS_5:attached by the ALB in Phases 5 and 6, which live in a different state file. checkov reads one directory and cannot see across layers.
  for_each = local.environments

  name        = "${local.name_prefix}-${each.key}-alb-sg"
  description = "Public entry point for the ${each.key} application load balancer"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name        = "${local.name_prefix}-${each.key}-alb-sg"
    environment = each.key
  }
}

resource "aws_security_group" "task" {
  # checkov:skip=CKV2_AWS_5:attached by the ECS service in Phases 5 and 6, which live in a different state file. checkov reads one directory and cannot see across layers.
  for_each = local.environments

  name        = "${local.name_prefix}-${each.key}-task-sg"
  description = "Fargate tasks serving the ${each.key} API"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name        = "${local.name_prefix}-${each.key}-task-sg"
    environment = each.key
  }
}

# --- ALB ingress ------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  # checkov:skip=CKV_AWS_260:the ALB is the internet-facing entry point by design; port 80 must accept 0.0.0.0/0 so a browser can reach the listener that immediately redirects to 443. Nothing behind this port serves plaintext.
  for_each = local.environments

  security_group_id = aws_security_group.alb[each.key].id
  description       = "HTTP from the internet, redirected to HTTPS by the listener"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = local.environments

  security_group_id = aws_security_group.alb[each.key].id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Production only. This is the test listener the blue/green deployment shifts
# traffic to before any user sees the new colour (design §5), and it is the
# reason Phase 6 never has to reopen this layer.
resource "aws_vpc_security_group_ingress_rule" "alb_test" {
  for_each = toset(["prod"])

  security_group_id = aws_security_group.alb[each.key].id
  description       = "Blue/green test listener, production only"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 8443
  to_port           = 8443
  ip_protocol       = "tcp"
}

# --- ALB egress -------------------------------------------------------------

resource "aws_vpc_security_group_egress_rule" "alb_to_task" {
  for_each = local.environments

  security_group_id            = aws_security_group.alb[each.key].id
  description                  = "Container port on this environment's tasks, health checks included"
  referenced_security_group_id = aws_security_group.task[each.key].id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# --- Task ingress -----------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  for_each = local.environments

  security_group_id            = aws_security_group.task[each.key].id
  description                  = "Container port from this environment's ALB only"
  referenced_security_group_id = aws_security_group.alb[each.key].id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# --- Task egress ------------------------------------------------------------
#
# 443 plus DNS, not "all traffic". Everything a Fargate task needs to start and
# run is HTTPS: the ECR auth token, the image layers through the S3 gateway
# endpoint, CloudWatch Logs, DynamoDB through its gateway endpoint, and any
# third-party API the design §3.1 argument turns on. Egress rules apply to the
# VPC resolver too, so DNS needs its own pair.

resource "aws_vpc_security_group_egress_rule" "task_https" {
  for_each = local.environments

  security_group_id = aws_security_group.task[each.key].id
  description       = "HTTPS to AWS service endpoints and third-party APIs"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "task_dns_udp" {
  for_each = local.environments

  security_group_id = aws_security_group.task[each.key].id
  description       = "DNS to the VPC resolver"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "task_dns_tcp" {
  for_each = local.environments

  security_group_id = aws_security_group.task[each.key].id
  description       = "DNS over TCP, for responses too large for a UDP datagram"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
}
