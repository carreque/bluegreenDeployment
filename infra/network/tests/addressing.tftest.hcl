# Addressing is asserted before anything is routed through it, because every
# later assertion in this layer is a statement about where traffic goes, and
# "where" is a CIDR. mock_data for the availability zones is mandatory, not
# tidiness: without it the AZ list is empty and locals.tf crashes inside
# slice() before any assertion runs (plan §F2).

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
    }
  }

  # Task 5 (flowlogs.tf) added aws_iam_policy_document, aws_cloudwatch_log_group
  # and aws_iam_role to the root module, so every run in this file now
  # instantiates them too even though nothing here asserts on them. A mocked
  # provider intercepts aws_iam_policy_document and mocks its "json" attribute
  # to "", which aws_iam_role's own schema validation rejects as an assume role
  # policy before apply runs; mocked resources' computed "arn" attributes
  # default to an opaque string rather than an ARN, and aws_flow_log.this feeds
  # those back in as arguments the provider validates client-side as ARNs. Both
  # defaults below exist only to keep validation happy, not to be inspected.
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

run "the_vpc_is_named_and_sized_by_the_convention" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16"
    error_message = "the VPC CIDR must come from var.vpc_cidr"
  }

  assert {
    condition     = aws_vpc.this.tags["Name"] == "bgd-us-east-1-vpc"
    error_message = "convention §3: a VPC is named <project>-<region>-vpc"
  }
}

run "dns_is_on_because_every_aws_endpoint_is_a_hostname" {
  command = plan

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "without VPC DNS, a Fargate task cannot resolve ecr, logs or dynamodb, and the failure looks like a network outage"
  }
}

# apply, not plan: ingress and egress on this resource are sets of objects that
# stay unknown until the apply resolves them, exactly as in §F1.
run "the_default_security_group_permits_nothing" {
  command = apply

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0
    error_message = "an unmanaged default security group allows anything that lands in it to reach anything else (checkov CKV2_AWS_12)"
  }
}

run "subnets_land_one_per_tier_per_availability_zone" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "two AZs means two public and two private subnets"
  }

  assert {
    condition     = aws_subnet.public[0].availability_zone == "us-east-1a" && aws_subnet.private[0].availability_zone == "us-east-1a"
    error_message = "index i of both lists must be the same AZ; Phase 5 pairs them by index"
  }
}

run "the_address_plan_is_the_one_recorded_in_the_layer_readme" {
  command = plan

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.0.0.0/24" && aws_subnet.public[1].cidr_block == "10.0.1.0/24"
    error_message = "public subnets must be the /24s at newbits 8"
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.0.16.0/20" && aws_subnet.private[1].cidr_block == "10.0.32.0/20"
    error_message = "private subnets must be the /20s starting at index 1, which is what keeps them clear of the public /24s"
  }
}

# Deliberately run at az_count = 4 rather than the default 2. Two AZs is the
# case the literal assertions above already cover; the maths is only interesting
# where it has room to go wrong. This assertion was mutation-tested while this
# plan was written: changing the private CIDRs to cidrsubnet(vpc_cidr, 4, i)
# makes it fail, which is the only evidence that it asserts anything at all.
run "no_two_subnets_overlap_even_at_four_availability_zones" {
  command = plan
  variables {
    az_count = 4
  }

  # Two ranges overlap iff startA <= endB and startB <= endA. Offsets are taken
  # within the VPC's /16, so the third and fourth octets are the whole address.
  assert {
    condition = alltrue(flatten([
      for a in concat(aws_subnet.public[*].cidr_block, aws_subnet.private[*].cidr_block) : [
        for b in concat(aws_subnet.public[*].cidr_block, aws_subnet.private[*].cidr_block) :
        a == b ? true : !(
          (tonumber(split(".", cidrhost(a, 0))[2]) * 256 + tonumber(split(".", cidrhost(a, 0))[3])) <=
          (tonumber(split(".", cidrhost(b, 0))[2]) * 256 + tonumber(split(".", cidrhost(b, 0))[3]) + pow(2, 32 - tonumber(split("/", b)[1])) - 1)
          &&
          (tonumber(split(".", cidrhost(b, 0))[2]) * 256 + tonumber(split(".", cidrhost(b, 0))[3])) <=
          (tonumber(split(".", cidrhost(a, 0))[2]) * 256 + tonumber(split(".", cidrhost(a, 0))[3]) + pow(2, 32 - tonumber(split("/", a)[1])) - 1)
        )
      ]
    ]))
    error_message = "public and private address space must not overlap at any az_count"
  }
}

run "private_subnets_never_auto_assign_a_public_address" {
  command = plan

  assert {
    condition     = aws_subnet.public[0].map_public_ip_on_launch && !aws_subnet.private[0].map_public_ip_on_launch
    error_message = "a private subnet that auto-assigns public IPs is not private; a public subnet without them cannot host the NAT gateway"
  }
}
