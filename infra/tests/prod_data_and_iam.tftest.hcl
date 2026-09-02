# The LSI is the assertion that matters most in this file. A local secondary
# index must be created with its table and cannot be added afterwards, so
# getting it wrong here is not a fix, it is a destroy and recreate. The shape
# is fixed by app/src/bgd/repository/schema.py, which the application, the
# local bootstrap and the tests all read.
#
# The IAM half asserts on five roles rather than staging's two. Three of them
# exist only because this layer deploys blue/green: the controller role ECS
# assumes to rewrite listener rules, the role it assumes to invoke the hooks,
# and — created three times by the lambda module — the hooks' own execution
# role. Plan §D4.

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

  # Added because omitting it produced a hard error, not because it looked tidy:
  # aws_lb_listener_rule validates its listener_arn client-side, and
  # mock_provider's random eight-character string is not an ARN.
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:590184028094:listener/app/mock/0123456789abcdef/aaaaaaaaaaaaaaaa" }
  }

  # Added because omitting it produced a hard error: the ECS service validates
  # advanced_configuration's production_listener_rule and test_listener_rule
  # client-side, and they are rule ARNs rather than listener ARNs (Phase 0 A7),
  # so the aws_lb_listener mock above does not cover them.
  mock_resource "aws_lb_listener_rule" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:590184028094:listener-rule/app/mock/0123456789abcdef/aaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbb" }
  }

  # Added because omitting it produced a hard error: the ECS service validates
  # every lifecycle_hook's hook_target_arn client-side.
  #
  # All three functions therefore share one ARN under test, which is why iam.tf
  # composes the invoke role's resource list from local.hook_function_names
  # instead — three identical mocked ARNs cannot show that a wildcard has not
  # crept in.
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-east-1:590184028094:function:mock" }
  }

  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  }
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

run "the_tables_match_the_application_schema" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.accounts.name == "bgd-us-east-1-prod-accounts"
    error_message = "accounts table name breaks the naming convention"
  }

  assert {
    condition     = aws_dynamodb_table.accounts.hash_key == "account_id"
    error_message = "accounts is keyed on account_id in schema.py"
  }

  assert {
    condition = (
      aws_dynamodb_table.transactions.name == "bgd-us-east-1-prod-transactions" &&
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
    error_message = "on-demand billing is what makes an idle environment cost nothing"
  }

  assert {
    condition = alltrue([
      !aws_dynamodb_table.accounts.deletion_protection_enabled,
      !aws_dynamodb_table.transactions.deletion_protection_enabled,
    ])
    error_message = "deletion protection would make terraform destroy fail and break make teardown"
  }

  # These tables are prod's own, not staging's. Sharing them would make the two
  # environments one environment with two front doors. Plan §D13.
  assert {
    condition = alltrue([
      !strcontains(aws_dynamodb_table.accounts.name, "staging"),
      !strcontains(aws_dynamodb_table.transactions.name, "staging"),
    ])
    error_message = "prod must not point at staging's tables; separate data is the point of separate environments"
  }
}

# These assertions are only possible because the policies are built with
# jsonencode rather than aws_iam_policy_document. mock_provider mocks that data
# source — it is the AWS provider's, despite being a pure local computation —
# and returns a random string, so a policy built through it asserts nothing
# under test. See Phase 5 plan §F1 and §D9.

run "the_task_role_grants_exactly_what_the_application_calls" {
  command = apply

  # dynamodb.py calls get_item, put_item, scan and query directly, plus
  # transact_write_items from post_transaction, which bundles a Put on
  # transactions with an Update on accounts. update_item is granted for that
  # Update; deliberately no delete_item, and no describe_table because ping()
  # uses a data-plane read instead.
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

  # The trap this asserts against: an IAM index is a distinct ARN. Grant only
  # the two table ARNs and every endpoint works except GET /api/transactions,
  # which fails AccessDenied at runtime — invisible to plan, apply and the ALB
  # health check, and invisible to the hooks too, since none of them calls it.
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

run "both_task_roles_are_assumable_only_by_ecs_tasks_in_this_account" {
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

# --- the three roles that exist only because this layer deploys blue/green ---

run "the_bluegreen_controller_role_uses_the_managed_policy_deliberately" {
  command = apply

  assert {
    condition     = aws_iam_role.bluegreen[0].name == "bgd-us-east-1-prod-bluegreen-role"
    error_message = "the blue/green controller role breaks the naming convention"
  }

  # ecs.amazonaws.com, not ecs-tasks. This role is assumed by the ECS control
  # plane to rewrite listener rules, not by a running task.
  assert {
    condition     = jsondecode(aws_iam_role.bluegreen[0].assume_role_policy).Statement[0].Principal.Service == "ecs.amazonaws.com"
    error_message = "the deployment controller is ecs.amazonaws.com; ecs-tasks would make the role unassumable"
  }

  assert {
    condition = jsondecode(
      aws_iam_role.bluegreen[0].assume_role_policy
    ).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "590184028094"
    error_message = "without the account condition this trust policy is confused-deputy shaped"
  }

  # Plan §D5. This is the one place in the project where the AWS-managed policy
  # is the *stricter* choice: the action set ECS uses to rewrite listener rules
  # mid-shift is not in the provider schema and cannot be read offline, and a
  # hand-rolled policy that is slightly too narrow does not fail at apply — it
  # fails halfway through a production traffic shift. A future "tighten this"
  # change has to argue with this assertion.
  assert {
    condition     = aws_iam_role_policy_attachment.bluegreen[0].policy_arn == "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
    error_message = "the blue/green controller role must attach the AWS-managed load balancer policy (plan §D5)"
  }
}

run "the_hook_invoke_role_can_invoke_exactly_the_three_hooks" {
  command = apply

  assert {
    condition     = jsondecode(aws_iam_role.hook_invoke[0].assume_role_policy).Statement[0].Principal.Service == "ecs.amazonaws.com"
    error_message = "ECS assumes this role to invoke the hooks; the principal is the control plane, not a task"
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.hook_invoke[0].policy).Statement[0].Action) == toset([
      "lambda:InvokeFunction",
    ])
    error_message = "the invoke role grants lambda:InvokeFunction and nothing else"
  }

  # Never a wildcard. This role is assumable by an AWS service on a trigger this
  # account does not control the timing of, which is exactly when a wildcard
  # stops being a convenience.
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.hook_invoke[0].policy).Statement[0].Resource) == 3
    error_message = "the invoke role must name exactly the three hook functions, never a wildcard"
  }

  assert {
    condition = length([
      for r in jsondecode(aws_iam_role_policy.hook_invoke[0].policy).Statement[0].Resource :
      r if strcontains(r, "*")
    ]) == 0
    error_message = "no wildcard may appear in the invoke role's resource list"
  }

  # The three ARNs are the three hook functions, named. Asserted against the
  # composed form rather than against module.*.function_arn on purpose:
  # mock_provider fills every aws_lambda_function.arn with the same string, so
  # comparing against the module outputs would pass even if all three entries
  # named one function. tests/bluegreen.tftest.hcl closes the other half by
  # asserting each module's function_name equals the local these are built from.
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.hook_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:lambda:us-east-1:590184028094:function:bgd-us-east-1-prod-pre-scale-hook",
      "arn:aws:lambda:us-east-1:590184028094:function:bgd-us-east-1-prod-post-test-hook",
      "arn:aws:lambda:us-east-1:590184028094:function:bgd-us-east-1-prod-post-prod-hook",
    ])
    error_message = "the invoke role's three ARNs must be the three hook functions this layer actually creates"
  }
}

run "the_controller_and_invoke_roles_are_different_roles" {
  command = apply

  # Plan §D4. deployment_configuration.lifecycle_hook.role_arn and
  # load_balancer.advanced_configuration.role_arn are two required slots with
  # two different permission sets — rewriting production routing, and invoking
  # three functions. Merging them would give the rule-rewriter permission to
  # invoke arbitrary Lambdas and the invoker permission to rewrite production
  # routing. Asserting the names differ is what stops a later simplification.
  assert {
    condition     = aws_iam_role.bluegreen[0].name != aws_iam_role.hook_invoke[0].name
    error_message = "the blue/green controller and the hook invoker must be separate roles (plan §D4)"
  }

  assert {
    condition     = aws_iam_role.hook_invoke[0].name == "bgd-us-east-1-prod-hook-invoke-role"
    error_message = "the hook invoke role breaks the naming convention"
  }
}
