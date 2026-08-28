# The asymmetry between staging and prod is the point of this file. Phase 6's
# dark canary needs :8443 on production only; if staging quietly carried it too,
# the least-privilege claim in the design would be decoration.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
    }
  }

  # Every run block applies the whole root module, including the flow-logs
  # resources from Task 5. A mocked provider intercepts aws_iam_policy_document
  # and mocks its "json" attribute to "", which aws_iam_role's own schema
  # validation rejects as an assume role policy before apply runs; mocked
  # resources' computed "arn" attributes default to an opaque string rather
  # than an ARN, and aws_flow_log.this feeds those back in as arguments the
  # provider validates client-side as ARNs. Both defaults below exist only to
  # keep validation happy, not to be inspected by any assertion here.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = jsonencode({
        Version   = "2012-10-17"
        Statement = []
      })
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:590184028094:log-group:/bgd/us-east-1/shared/vpc-flow"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-shared-flow-logs-role"
    }
  }
}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
}

run "there_is_one_pair_of_groups_per_environment" {
  command = plan

  assert {
    condition     = aws_security_group.alb["prod"].name == "bgd-us-east-1-prod-alb-sg"
    error_message = "convention §3: security groups are <project>-<region>-<env>-<role>-sg"
  }

  assert {
    condition     = aws_security_group.task["staging"].name == "bgd-us-east-1-staging-task-sg"
    error_message = "convention §3: security groups are <project>-<region>-<env>-<role>-sg"
  }

  assert {
    condition     = aws_security_group.task["prod"].tags["environment"] == "prod"
    error_message = "plan §D6: per-environment groups override the environment tag, which is the documented exception for zero-cost resources"
  }
}

run "only_production_exposes_the_blue_green_test_listener" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_test["prod"].to_port == 8443
    error_message = "Phase 6's dark canary needs :8443 reachable on the production ALB"
  }

  assert {
    condition     = !contains(keys(aws_vpc_security_group_ingress_rule.alb_test), "staging")
    error_message = "staging has no test listener; opening :8443 there widens the surface for nothing"
  }
}

run "tasks_accept_traffic_only_from_their_own_environments_load_balancer" {
  command = apply

  assert {
    condition = alltrue([
      for env in ["staging", "prod"] :
      aws_vpc_security_group_ingress_rule.task_from_alb[env].referenced_security_group_id == aws_security_group.alb[env].id
    ])
    error_message = "a task group whose source is the other environment's ALB, or a CIDR, breaks the isolation the per-env split exists for"
  }

  assert {
    condition = alltrue([
      for env in ["staging", "prod"] :
      aws_vpc_security_group_ingress_rule.task_from_alb[env].to_port == 8080
    ])
    error_message = "the container port is 8080, fixed by app/Dockerfile"
  }
}

# This run block asserts that the three known task-egress rules are exactly
# https (443/tcp) and DNS (53/tcp, 53/udp), each pinned to protocol AND port
# so mutating one of those three rules into an all-traffic rule fails here.
# What it CANNOT catch: an ADDED fourth rule (e.g. ip_protocol = "-1" to
# 0.0.0.0/0) alongside the three known ones. `terraform test` can only assert
# against resource instances that exist in the plan/state it is given; it has
# no "and nothing else" assertion over a for_each map, so a wide rule added
# next to these three passes both this test and checkov, whose open-egress
# checks fire on aws_security_group inline blocks, not on these standalone
# aws_vpc_security_group_egress_rule resources. See the "Carried forward"
# table in docs/phases/phase4/2026-08-26-local-verification.md.
run "the_known_task_egress_rules_are_https_and_dns_only" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_egress_rule.task_https["prod"].ip_protocol == "tcp" && aws_vpc_security_group_egress_rule.task_https["prod"].from_port == 443 && aws_vpc_security_group_egress_rule.task_https["prod"].to_port == 443 && aws_vpc_security_group_egress_rule.task_https["prod"].cidr_ipv4 == "0.0.0.0/0"
    error_message = "tasks reach ECR, CloudWatch, DynamoDB and any third-party API over 443/tcp; that is the only port they need outbound"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.task_dns_udp["prod"].ip_protocol == "udp" && aws_vpc_security_group_egress_rule.task_dns_udp["prod"].from_port == 53 && aws_vpc_security_group_egress_rule.task_dns_udp["prod"].to_port == 53 && aws_vpc_security_group_egress_rule.task_dns_udp["prod"].cidr_ipv4 == "10.0.0.0/16"
    error_message = "DNS over UDP goes to the VPC resolver inside the VPC, not to the internet"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.task_dns_tcp["prod"].ip_protocol == "tcp" && aws_vpc_security_group_egress_rule.task_dns_tcp["prod"].from_port == 53 && aws_vpc_security_group_egress_rule.task_dns_tcp["prod"].to_port == 53 && aws_vpc_security_group_egress_rule.task_dns_tcp["prod"].cidr_ipv4 == "10.0.0.0/16"
    error_message = "DNS over TCP goes to the VPC resolver inside the VPC, not to the internet"
  }
}
