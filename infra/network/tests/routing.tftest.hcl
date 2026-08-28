# Every assertion here is a relationship between two computed ids, so every run
# block uses command = apply. Against a mocked provider that creates nothing and
# needs no credentials — but unlike command = plan it resolves the ids, which is
# the only way "this route points at that gateway" can be asserted at all.
# See the plan's §F1.

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

run "the_nat_gateway_sits_in_a_public_subnet" {
  command = apply

  # A NAT Gateway in a private subnet is created without complaint and then
  # routes nothing, because it has no path to the internet gateway itself.
  # It is the single most expensive way to misconfigure this layer.
  assert {
    condition     = contains(aws_subnet.public[*].id, aws_nat_gateway.this.subnet_id)
    error_message = "the NAT gateway must live in a public subnet or it has no route out itself"
  }

  assert {
    condition     = aws_nat_gateway.this.allocation_id == aws_eip.nat.id
    error_message = "the NAT gateway must use the Elastic IP this layer allocates, so verify-network.sh has a stable address to assert against"
  }
}

run "public_traffic_leaves_through_the_internet_gateway" {
  command = apply

  assert {
    condition     = aws_route.public_internet.gateway_id == aws_internet_gateway.this.id
    error_message = "the public default route must target the internet gateway"
  }

  assert {
    condition     = aws_route.public_internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "the public route table needs a default route, not a route to something specific"
  }

  assert {
    condition     = length(aws_route_table_association.public) == 2
    error_message = "both public subnets must be associated with the public route table; an unassociated subnet silently falls back to the main route table"
  }
}

run "private_traffic_leaves_through_the_nat_gateway" {
  command = apply

  # This is the cost-model guarantee, not a style assertion. A second NAT is
  # another ~$33/month, and the roadmap's cost model assumes one. Pinning
  # every private default route to the single aws_nat_gateway.this means a
  # second NAT that is actually wired up to carry traffic gets caught here —
  # if AZ redundancy is ever wanted, this is the assertion that has to change
  # deliberately.
  assert {
    condition = alltrue([
      for r in aws_route.private_nat : r.nat_gateway_id == aws_nat_gateway.this.id
    ])
    error_message = "every private default route must target the one NAT gateway"
  }

  assert {
    condition     = length(aws_route_table.private) == 2
    error_message = "one private route table per AZ, so a second NAT is a one-line change rather than a restructure"
  }

  assert {
    condition     = length(aws_route_table_association.private) == 2
    error_message = "both private subnets must be associated, or their tasks have no egress at all"
  }

  assert {
    condition = alltrue([
      for i, assoc in aws_route_table_association.private :
      assoc.route_table_id == aws_route_table.private[i].id && assoc.subnet_id == aws_subnet.private[i].id
    ])
    error_message = "private subnet i must be associated with private route table i; associating both subnets to one table strands an AZ on the main route table, with no error and no drift"
  }
}

run "the_free_gateway_endpoints_keep_bulk_traffic_off_the_nat_meter" {
  command = apply

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && aws_vpc_endpoint.dynamodb.vpc_endpoint_type == "Gateway"
    error_message = "these must be Gateway endpoints; an Interface endpoint costs ~$7.30 per AZ per month and design §3.1 priced them out"
  }

  assert {
    condition     = aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-1.s3"
    error_message = "the S3 endpoint is what keeps ECR layer pulls off the NAT's data-processing charge, since ECR stores layers in S3"
  }

  assert {
    condition = alltrue([
      for rt in aws_route_table.private[*].id :
      contains(tolist(aws_vpc_endpoint.s3.route_table_ids), rt)
    ])
    error_message = "an endpoint associated with only some private route tables sends the other AZ's traffic through the NAT, and nothing reports it"
  }

  assert {
    condition = alltrue([
      for rt in aws_route_table.private[*].id :
      contains(tolist(aws_vpc_endpoint.dynamodb.route_table_ids), rt)
    ])
    error_message = "DynamoDB is the application's entire data path; both AZs must reach it without leaving AWS"
  }
}

run "flow_logs_capture_both_accepted_and_rejected_traffic" {
  command = apply

  # REJECT-only is the tempting economy and the wrong one: the question this
  # layer will actually be asked is "did the task's request reach DynamoDB",
  # and an accepted flow is the only evidence that answers it.
  assert {
    condition     = aws_flow_log.this.traffic_type == "ALL"
    error_message = "flow logs must capture ACCEPT as well as REJECT to be useful for Phase 5 and 6 debugging"
  }

  assert {
    condition     = aws_flow_log.this.vpc_id == aws_vpc.this.id
    error_message = "the flow log must be attached at VPC scope, so subnets added later are covered without an edit"
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs.name == "/bgd/us-east-1/shared/vpc-flow"
    error_message = "convention §3: log groups are /<project>/<region>/<env>/<service>, with slashes rather than hyphens"
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs.retention_in_days == 7
    error_message = "retention must come from var.flow_log_retention_days; an unset retention means never expire, and never expire is what makes flow logs expensive"
  }

  # Asserted against the data source's configured "resources" input, not its
  # mocked "json" output: mock_data applies per data-source TYPE, so
  # flow_logs_assume and flow_logs would otherwise render identically and this
  # could never catch a future widen-to-"*" regression on the layer's only
  # IAM policy.
  assert {
    condition = alltrue([
      for r in data.aws_iam_policy_document.flow_logs.statement[0].resources :
      startswith(r, aws_cloudwatch_log_group.flow_logs.arn)
    ])
    error_message = "the flow-logs policy must be scoped to this log group and its streams; a wildcard here would let the only IAM role in this layer write anywhere in CloudWatch Logs"
  }
}
