# The LSI is the assertion that matters most in this file. A local secondary
# index must be created with its table and cannot be added afterwards, so
# getting it wrong here is not a fix, it is a destroy and recreate. The shape
# is fixed by app/src/bgd/repository/schema.py, which the application, the
# local bootstrap and the tests all read.

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

run "the_tables_match_the_application_schema" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.accounts.name == "bgd-us-east-1-staging-accounts"
    error_message = "accounts table name breaks the naming convention"
  }

  assert {
    condition     = aws_dynamodb_table.accounts.hash_key == "account_id"
    error_message = "accounts is keyed on account_id in schema.py"
  }

  assert {
    condition = (
      aws_dynamodb_table.transactions.hash_key == "account_id" &&
      aws_dynamodb_table.transactions.range_key == "transaction_id"
    )
    error_message = "transactions is keyed (account_id, transaction_id) in schema.py"
  }

  assert {
    condition     = one(aws_dynamodb_table.transactions.local_secondary_index).name == "created_at-index"
    error_message = "the created_at-index LSI is missing; it cannot be added after the table is created"
  }

  assert {
    condition = (
      one(aws_dynamodb_table.transactions.local_secondary_index).range_key == "created_at" &&
      one(aws_dynamodb_table.transactions.local_secondary_index).projection_type == "ALL"
    )
    error_message = "the LSI must sort on created_at and project ALL, per schema.py"
  }

  assert {
    condition = alltrue([
      aws_dynamodb_table.accounts.billing_mode == "PAY_PER_REQUEST",
      aws_dynamodb_table.transactions.billing_mode == "PAY_PER_REQUEST",
    ])
    error_message = "on-demand billing is what makes an idle staging environment cost nothing"
  }

  assert {
    condition = alltrue([
      !aws_dynamodb_table.accounts.deletion_protection_enabled,
      !aws_dynamodb_table.transactions.deletion_protection_enabled,
    ])
    error_message = "deletion protection would make terraform destroy fail and break make teardown"
  }
}

# These assertions are only possible because the policies are built with
# jsonencode rather than aws_iam_policy_document. mock_provider mocks that data
# source — it is the AWS provider's, despite being a pure local computation —
# and returns a random string, so a policy built through it asserts nothing
# under test. See the plan's F1 and D9.

run "the_task_role_grants_exactly_what_the_application_calls" {
  command = apply

  # dynamodb.py calls get_item, put_item, scan and query directly, plus
  # transact_write_items from post_transaction, which bundles a Put on
  # transactions with an Update on accounts. update_item is granted for that
  # Update; deliberately no delete_item, and no describe_table because ping()
  # uses a data-plane read instead. Plan §F6 undercounted this action set.
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.task.policy).Statement[0].Action) == toset([
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:TransactWriteItems",
      "dynamodb:UpdateItem",
    ])
    error_message = "the task role grants a different action set than app/src/bgd/repository/dynamodb.py calls"
  }

  # post_transaction's Update targets the accounts table, so UpdateItem must be
  # granted on it. Asserted separately because this is the action the plan's F6
  # missed entirely.
  assert {
    condition = contains(
      jsondecode(aws_iam_role_policy.task.policy).Statement[0].Action,
      "dynamodb:UpdateItem"
    )
    error_message = "UpdateItem is missing; POST /api/transactions fails AccessDenied at runtime"
  }

  # The trap this asserts against: an IAM index is a distinct ARN. Grant only
  # the two table ARNs and every endpoint works except GET /api/transactions,
  # which fails AccessDenied at runtime — invisible to plan, apply and the ALB
  # health check. Plan §F6.
  assert {
    condition = contains(
      jsondecode(aws_iam_role_policy.task.policy).Statement[0].Resource,
      "${aws_dynamodb_table.transactions.arn}/index/created_at-index"
    )
    error_message = "the LSI index ARN is missing; listing transactions would fail AccessDenied at runtime"
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.task.policy).Statement) == 1
    error_message = "the task role should grant one statement; anything else is scope creep"
  }
}

run "the_execution_role_can_pull_only_this_projects_registry" {
  command = apply

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.task_exec.policy).Statement :
      s.Resource if s.Sid == "EcrPullThisRepositoryOnly"
    ], "arn:aws:ecr:us-east-1:590184028094:repository/bgd-us-east-1-api")
    error_message = "the image pull must be scoped to the project's repository, not to every repository in the account"
  }

  # GetAuthorizationToken is the one action that genuinely cannot be scoped —
  # it grants a registry-wide token and AWS defines no resource for it. It is
  # isolated in its own statement so that the wildcard is visibly attached to
  # that action alone rather than to the pull actions as well.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.task_exec.policy).Statement :
      s if s.Resource == "*"
    ]) == 1
    error_message = "exactly one statement may use a wildcard resource, and it must be the ECR auth token"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.task_exec.policy).Statement :
      s.Sid == "EcrAuthToken" && s.Resource == "*"
    ])
    error_message = "the wildcard statement must be the ECR auth token and nothing else"
  }
}

run "both_roles_are_assumable_only_by_ecs_tasks_in_this_account" {
  command = plan

  assert {
    condition = alltrue([
      jsondecode(aws_iam_role.task.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com",
      jsondecode(aws_iam_role.task_exec.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com",
    ])
    error_message = "only the ECS tasks service principal may assume these roles"
  }

  # Without the account condition these trust policies are confused-deputy
  # shaped: any ECS task anywhere could assume them if it obtained the ARN.
  assert {
    condition = jsondecode(
      aws_iam_role.task.assume_role_policy
    ).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "590184028094"
    error_message = "the trust policy must be conditioned on this account"
  }
}
