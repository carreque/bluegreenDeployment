# Everything Phase 5 already asserts, re-pointed at this layer. Nothing here is
# about deployment strategy — that is bluegreen.tftest.hcl. The split is
# deliberate: a reviewer comparing the two environments should be able to see at
# a glance which assertions are the same in both and which exist only because
# this one deploys blue/green.

variables {
  image_tag = "0.0.0-test"

  # This suite exercises the PRODUCTION shape. Both are set explicitly
  # rather than relying on defaults, which are staging's: a file that
  # forgot them would silently assert production's properties against a
  # staging plan and fail with a message about a missing resource.
  environment = "prod"
  enable_prod = true

  # Mirrors environments/prod.tfvars, which terraform test cannot read: -var-file
  # applies to every file in a run, and this directory holds both suites. The two
  # places that state prod's shape are therefore this line and that file, and
  # prod_compute.tftest.hcl asserts the service actually runs two tasks — so a
  # drift between them fails here rather than in a production apply.
  desired_count = 2
}

mock_provider "aws" {
  source = "./tests/mocks"
}

# Without these two overrides the tests reach the real S3 backend and fail on
# credentials rather than silently asserting against null. Measured — Phase 5
# plan F3.
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

run "the_task_definition_carries_the_phase_2_inheritances" {
  command = apply

  # Phase 2 builds linux/arm64 only, because it runs on Graviton, which is
  # cheaper. An X86_64 task definition fails at task start with an exec format
  # error — and in a blue/green deployment green then never becomes healthy, the
  # deployment stalls, and wait_for_steady_state eventually times the apply out.
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

  # It matters more here than in staging: /version is the blue/green evidence
  # surface, and this phase's second exit criterion is read directly off it.
  # Without this the endpoint reports "unknown" and the criterion is unprovable.
  assert {
    condition = one([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e.value if e.name == "BGD_IMAGE_DIGEST"
    ]) == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "BGD_IMAGE_DIGEST must equal the deployed digest, or /version reports a digest that was never deployed"
  }
}

run "the_container_environment_points_at_prods_own_tables" {
  command = apply

  assert {
    condition = one([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e.value if e.name == "BGD_ACCOUNTS_TABLE"
    ]) == "bgd-us-east-1-prod-accounts"
    error_message = "the container must be pointed at the prod accounts table, not staging's"
  }

  assert {
    condition = one([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e.value if e.name == "BGD_TRANSACTIONS_TABLE"
    ]) == "bgd-us-east-1-prod-transactions"
    error_message = "the container must be pointed at the prod transactions table, not staging's"
  }

  assert {
    condition = one([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e.value if e.name == "BGD_ENVIRONMENT"
    ]) == "prod"
    error_message = "BGD_ENVIRONMENT is what /version and the structured logs report; it must say prod"
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

  assert {
    condition = one([
      for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
    ]).readonlyRootFilesystem
    error_message = "the root filesystem must be read-only; measured to work against the real image in Phase 5 §F5"
  }

  assert {
    condition = one([
      for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
    ]).logConfiguration.options["awslogs-group"] == "/bgd/us-east-1/prod/api"
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
    condition     = aws_ecs_cluster.this.name == "bgd-us-east-1-prod-cluster"
    error_message = "cluster name breaks the naming convention"
  }

  assert {
    condition     = one(aws_ecs_cluster.this.setting).value == "disabled"
    error_message = "container insights must be explicitly disabled rather than omitted, so the choice is visible (Phase 5 §D7)"
  }
}

run "the_service_runs_private_tasks_with_attributable_tags" {
  command = apply

  assert {
    condition     = aws_ecs_service.api.name == "bgd-us-east-1-prod-api"
    error_message = "service name breaks the naming convention"
  }

  # Mandatory, not decoration, and it matters twice as much here: propagate_tags
  # is optional and NOT computed in the provider schema, so omitting it sends
  # nothing, the ECS default of no propagation applies, and every running task is
  # untagged while terraform plan stays clean. Production runs two tasks, plus a
  # whole green task set during every deployment. Convention §6.1.
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

  # prod's group, not staging's. Phase 4 built four security groups so the two
  # environments' tasks cannot reach each other.
  assert {
    condition     = one(aws_ecs_service.api.network_configuration).security_groups == toset(["sg-0mocktaskprod"])
    error_message = "the service must use the prod task security group, not staging's"
  }
}
