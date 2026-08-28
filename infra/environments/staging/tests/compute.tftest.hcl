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

# The two assertions that matter most here are the Phase 2 inheritances. Both
# fail silently in different ways: an X86_64 task definition cannot start the
# arm64 image at all, and a missing BGD_IMAGE_DIGEST leaves /version reporting
# "unknown" on a live endpoint with nothing else wrong.

# The digest is written as a literal rather than a local. A `locals` block is
# not a valid block type in a .tftest.hcl file — Terraform rejects the file with
# "Blocks of type \"locals\" are not expected here". Module locals ARE readable
# from an assertion; it is only declaring new ones here that is unsupported.

run "the_task_definition_carries_the_phase_2_inheritances" {
  command = apply

  assert {
    condition     = aws_ecs_task_definition.api.runtime_platform[0].cpu_architecture == "ARM64"
    error_message = "Phase 2 builds linux/arm64 only; an X86_64 task definition cannot start this image"
  }

  assert {
    condition = one([
      for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
    ]).image == "590184028094.dkr.ecr.us-east-1.amazonaws.com/bgd-us-east-1-api@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "the container must be pinned to the digest the ECR data source resolved, not to a tag"
  }

  assert {
    condition = one([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e.value if e.name == "BGD_IMAGE_DIGEST"
    ]) == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "BGD_IMAGE_DIGEST must equal the deployed digest, or /version reports a digest that was never deployed"
  }
}

run "the_container_environment_points_at_this_environments_tables" {
  command = apply

  assert {
    condition = one([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e.value if e.name == "BGD_ACCOUNTS_TABLE"
    ]) == "bgd-us-east-1-staging-accounts"
    error_message = "the container must be pointed at the staging accounts table"
  }

  assert {
    condition = one([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e.value if e.name == "BGD_TRANSACTIONS_TABLE"
    ]) == "bgd-us-east-1-staging-transactions"
    error_message = "the container must be pointed at the staging transactions table"
  }

  # BGD_DYNAMODB_ENDPOINT_URL must be absent. Set, it points the client at
  # DynamoDB Local; the settings default of null is what selects real AWS.
  assert {
    condition = length([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e if e.name == "BGD_DYNAMODB_ENDPOINT_URL"
    ]) == 0
    error_message = "BGD_DYNAMODB_ENDPOINT_URL must be unset in AWS; setting it points the client at DynamoDB Local"
  }
}

run "the_container_is_hardened_and_logs_where_terraform_says" {
  command = apply

  # Verified against the real image before this was written: the container
  # starts and serves under a read-only root filesystem, because the image sets
  # PYTHONDONTWRITEBYTECODE and nothing in the request path writes to disk.
  # Plan §F5.
  assert {
    condition = one([
      for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
    ]).readonlyRootFilesystem
    error_message = "the root filesystem must be read-only; measured to work against the real image in plan §F5"
  }

  assert {
    condition = one([
      for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
    ]).logConfiguration.options["awslogs-group"] == "/bgd/us-east-1/staging/api"
    error_message = "logs must go to the group Terraform manages; a mismatched name creates a second, silently empty group"
  }

  assert {
    condition = one([
      for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
    ]).portMappings[0].containerPort == 8080
    error_message = "the container port must match what network's security group rules opened"
  }
}

run "the_cluster_is_named_by_convention_and_insights_is_an_explicit_choice" {
  command = plan

  assert {
    condition     = aws_ecs_cluster.this.name == "bgd-us-east-1-staging-cluster"
    error_message = "cluster name breaks the naming convention"
  }

  assert {
    condition     = one(aws_ecs_cluster.this.setting).value == "disabled"
    error_message = "container insights must be explicitly disabled rather than omitted, so the choice is visible (plan §D7)"
  }
}
