variables {
  image_tag = "0.0.0-test"

  # This suite exercises the STAGING shape. Stated explicitly even though
  # both match the variable defaults, so the file says what it tests
  # rather than depending on a default staying put.
  environment = "staging"
  enable_prod = false
}

mock_provider "aws" {
  source = "./tests/mocks"
}

# Without these two overrides the tests reach the real S3 backend and fail on
# credentials rather than silently asserting against null. Measured — plan F3.
override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      certificate_arn    = "arn:aws:acm:us-east-1:590184028094:certificate/mock"
      zone_id            = "Z0MOCKZONEID000"
      api_domain         = "api.carloscloudengineer.com"
      staging_api_domain = "staging-api.carloscloudengineer.com"
      ecr_repository_url = "590184028094.dkr.ecr.us-east-1.amazonaws.com/bgd-us-east-1-api"
      ecr_repository_arn = "arn:aws:ecr:us-east-1:590184028094:repository/bgd-us-east-1-api"
      alerts_topic_arn   = "arn:aws:sns:us-east-1:590184028094:bgd-us-east-1-alerts"
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

run "the_service_runs_private_tasks_with_attributable_tags" {
  command = apply

  assert {
    condition     = aws_ecs_service.api.name == "bgd-us-east-1-staging-api"
    error_message = "service name breaks the naming convention"
  }

  # Not decoration. propagate_tags is optional and NOT computed in the provider
  # schema, so omitting it sends nothing, the ECS default of no propagation
  # applies, every running task is untagged, and terraform plan stays clean.
  # Fargate is the largest cost line after the ALBs and NAT. Convention §6.1.
  assert {
    condition     = aws_ecs_service.api.propagate_tags == "SERVICE"
    error_message = "without propagate_tags every running task is untagged and Fargate cost cannot be attributed"
  }

  assert {
    condition     = one(aws_ecs_service.api.network_configuration).subnets == toset(["subnet-0mockprva", "subnet-0mockprvb"])
    error_message = "tasks belong in the private subnets, reaching the internet through the NAT"
  }

  assert {
    condition     = !one(aws_ecs_service.api.network_configuration).assign_public_ip
    error_message = "a public IP on a private-subnet task both costs money and defeats the point of the subnet"
  }

  assert {
    condition     = one(aws_ecs_service.api.network_configuration).security_groups == toset(["sg-0mocktaskstaging"])
    error_message = "the service must use the staging task security group, not prod's"
  }
}

run "the_apply_does_not_return_before_the_rollout_is_done" {
  command = plan

  # Found 2026-08-31, when Phase 8's Smoke action failed against a healthy
  # deployment. Without this the apply returns while the rolling replacement is
  # still in flight, and scripts/smoke.sh reads the PREVIOUS task's /version —
  # its fourth assertion compares the digest being served against the digest
  # Terraform deployed, so it reports a mismatch on a deployment that finished
  # correctly moments later.
  #
  # It fails closed rather than open, which is why nothing bad shipped: a pass
  # requires the intended image to actually be serving. The cost is randomly red
  # pipelines on good deployments, which is how people learn to re-run without
  # reading.
  assert {
    condition     = aws_ecs_service.api.wait_for_steady_state == true
    error_message = "the apply must not return before the rollout stabilises; the Smoke action runs immediately after it and reads /version"
  }
}

run "the_service_deploys_by_rolling_and_rolls_itself_back" {
  command = apply

  # ROLLING is also the API default, so this line changes nothing on its own.
  # It is written because the single word is the visible difference between this
  # layer and Phase 6's, where it becomes BLUE_GREEN.
  assert {
    condition     = one(aws_ecs_service.api.deployment_configuration).strategy == "ROLLING"
    error_message = "staging deploys by rolling update; blue/green is Phase 6 and production only"
  }

  # Staging's job in the roadmap is to fail fast. Without the circuit breaker a
  # task that never becomes healthy is retried indefinitely, consuming Fargate
  # capacity, and the failure is visible only to someone reading service events.
  assert {
    condition = (
      one(aws_ecs_service.api.deployment_circuit_breaker).enable &&
      one(aws_ecs_service.api.deployment_circuit_breaker).rollback
    )
    error_message = "the circuit breaker must be enabled with rollback (plan §D8)"
  }

  assert {
    condition     = one(aws_ecs_service.api.load_balancer).container_name == "api"
    error_message = "the load_balancer block's container_name must match the task definition's container name"
  }

  assert {
    condition     = aws_ecs_service.api.desired_count == 1
    error_message = "staging runs one task by design"
  }
}
