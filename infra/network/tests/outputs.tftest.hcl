# This file exists to make a rename in this layer fail here rather than in
# Phase 5, where it would surface as a remote-state lookup returning null and
# an ECS service placed in no subnets. Outputs are an interface; interfaces get
# tests.
#
# Every run block in this root module applies flowlogs.tf too, so this file
# needs the same mock_provider block as routing.tftest.hcl: four AZ names plus
# mocks for aws_iam_policy_document / aws_cloudwatch_log_group / aws_iam_role.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
    }
  }

  # aws_iam_policy_document is computed locally rather than over the network,
  # but a mocked provider still intercepts it: without a default its "json"
  # attribute mocks to "", and the aws_iam_role resource's own schema
  # validation rejects an empty string as an assume role policy before this
  # ever reaches apply. No assertion here inspects policy content, so a
  # minimal valid document is enough to unblock validation.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = jsonencode({
        Version   = "2012-10-17"
        Statement = []
      })
    }
  }

  # Likewise, a mocked resource's computed "arn" defaults to an opaque random
  # string rather than an ARN. aws_flow_log.this feeds both of these back in as
  # iam_role_arn / log_destination, and the provider validates the ARN shape
  # client-side before apply ever runs, so the mocks must at least look real.
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

run "the_consumed_surface_is_complete_and_correctly_shaped" {
  command = apply

  assert {
    condition     = length(output.private_subnet_ids) == 2 && length(output.public_subnet_ids) == 2
    error_message = "both environment layers place their ALBs and tasks from these two lists"
  }

  assert {
    condition     = output.vpc_cidr == "10.0.0.0/16"
    error_message = "Phase 5 and 6 scope their own rules against the VPC CIDR"
  }

  assert {
    condition     = output.vpc_id == aws_vpc.this.id
    error_message = "vpc_id is the most-consumed output in Phases 5 and 6; a rename here must fail in this layer, not as a null remote-state lookup in the next one"
  }

  assert {
    condition     = output.nat_gateway_public_ip == aws_eip.nat.public_ip
    error_message = "scripts/verify-network.sh dereferences this output by name to compare the probe's observed egress address against the NAT's Elastic IP"
  }

  assert {
    condition = alltrue([
      for env in ["staging", "prod"] :
      output.alb_security_group_ids[env] != null && output.task_security_group_ids[env] != null
    ])
    error_message = "both environments must find both of their security groups by name in these maps"
  }

  assert {
    condition     = output.container_port == 8080
    error_message = "the environment layers read the container port from here rather than restating 8080 in three places"
  }

  assert {
    condition     = output.availability_zones[0] == "us-east-1a"
    error_message = "the AZ list is ordered and index-aligned with the subnet lists"
  }
}
