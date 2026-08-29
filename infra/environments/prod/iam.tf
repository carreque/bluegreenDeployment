# Five roles, of design §8.1's seven. Phase 0 found that §8.1's list of five was
# missing load_balancer.advanced_configuration.role_arn; inspecting the same
# schema for Phase 6 turned up a *second* required slot neither document names,
# deployment_configuration.lifecycle_hook.role_arn. Plan §D4.
#
#   task_exec        ecs-tasks.amazonaws.com   ECR pull, log stream write
#   task             ecs-tasks.amazonaws.com   the application's six DynamoDB calls
#   bluegreen        ecs.amazonaws.com         rewrite this ALB's listener rules
#   hook_invoke      ecs.amazonaws.com         invoke exactly the three hooks
#   <the fifth>      lambda.amazonaws.com      created three times by ../../modules/lambda
#
# The first two are staging's file with the prefix changed, both long comments
# preserved — they are as true here as there, and production is not the place to
# thin out the reasoning. All are created here rather than in foundation because
# a role's policy cannot be scoped to resources that do not exist yet — the
# Phase 3 §D2 rule — and the tables, log group and functions are this layer's.
#
# Policies are built with jsonencode rather than aws_iam_policy_document.
# mock_provider mocks every data source the AWS provider owns, and the policy
# document generator is one of them despite being a pure local computation: it
# returns a random string under test and aws_iam_role rejects it client-side.
# jsonencode keeps the JSON real under mocks, which is what lets the tests
# assert what these policies actually grant. See the Phase 5 plan's F1 and D9.

locals {
  # Shared by both task roles: identical trust, different permissions. The account
  # condition is what stops these being confused-deputy shaped — without it any
  # ECS task anywhere could assume them given the ARN.
  ecs_tasks_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}

# --- execution role: what the ECS agent does on the task's behalf -----------
#
# Assumed by ECS itself, before the container starts, to pull the image and
# create the log stream. The application code never holds these permissions.

resource "aws_iam_role" "task_exec" {
  name               = "${local.env_prefix}-task-exec-role"
  assume_role_policy = local.ecs_tasks_assume_role_policy
}

resource "aws_iam_role_policy" "task_exec" {
  name = "${local.env_prefix}-task-exec-policy"
  role = aws_iam_role.task_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The one action that genuinely cannot be scoped: it returns a
        # registry-wide token and AWS defines no resource type for it. Isolated
        # in its own statement so the wildcard is visibly attached to this
        # action alone.
        Sid      = "EcrAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPullThisRepositoryOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = local.foundation.ecr_repository_arn
      },
      {
        # CreateLogGroup is deliberately absent. Terraform owns the group, and
        # granting the agent permission to create one would let a typo in the
        # log configuration silently produce a second, unmanaged group instead
        # of failing.
        Sid      = "WriteThisServicesLogsOnly"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.api.arn}:*"
      },
    ]
  })
}

# --- task role: what the application code itself can do ---------------------

resource "aws_iam_role" "task" {
  name               = "${local.env_prefix}-task-role"
  assume_role_policy = local.ecs_tasks_assume_role_policy
}

resource "aws_iam_role_policy" "task" {
  name = "${local.env_prefix}-task-policy"
  role = aws_iam_role.task.id

  # app/src/bgd/repository/dynamodb.py's simple calls are GetItem, PutItem,
  # Query and Scan. post_transaction is not simple: it is a two-item
  # transact_write_items call — a Put on transactions guarded by
  # attribute_not_exists(transaction_id), and an Update on accounts that
  # applies SET balance_minor = balance_minor + :delta. The Update item is why
  # UpdateItem must be granted; without it POST /api/transactions, the
  # application's primary write path, fails AccessDenied at runtime.
  #
  # TransactWriteItems is granted alongside it. AWS documents the requirement
  # as the per-item actions (here, PutItem and UpdateItem), so whether the
  # compound action is *additionally* required could not be confirmed without
  # an AWS session. It is a real DynamoDB API action, so granting it is either
  # necessary or inert — never harmful on its own — and omitting it risks
  # breaking the main write path if the per-item actions turn out not to be
  # sufficient. The runbook's POST /api/transactions step exercises both
  # permissions in the same call, so a success proves only that the granted
  # set is sufficient — it cannot isolate which member was necessary, since
  # both the first call and the idempotent repeat run the identical
  # transact_write_items call (idempotency comes from a ConditionExpression
  # raising TransactionCanceledException, not from a different code path).
  # Isolating this action requires the separate, optional experiment the
  # runbook describes: remove it, apply, and repeat the step — a failure
  # proves it necessary, a success proves it redundant.
  #
  # The index ARN below is the other easy thing to omit: an IAM index is a
  # distinct resource, and without it every endpoint works except
  # GET /api/transactions, which fails AccessDenied at runtime. Phase 5 plan §F6.
  #
  # This precision is action-exact, not resource-exact. The Action list above
  # really is exactly the six calls the application code makes — nothing
  # more, nothing unused. The Resource list is a separate, coarser thing: it
  # is the set of ARNs the application touches at all, and a single
  # statement grants their full cross-product rather than a per-resource
  # mapping. That means some pairs in the cross-product are meaningless —
  # Query and Scan are never issued against accounts, and GetItem, PutItem,
  # UpdateItem and TransactWriteItems can never apply to the LSI ARN, since
  # an index is read-only. This is a deliberate simplification, not an
  # oversight: it only widens access within one application's own two
  # tables, there is no tenant or blast-radius boundary being crossed, and a
  # test asserts length(Statement) == 1, so the fix for anyone tempted to
  # split this into a tighter per-resource mapping is: don't — the single
  # statement is the intended shape.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DynamoDbDataPlane"
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:TransactWriteItems",
        "dynamodb:UpdateItem",
      ]
      Resource = [
        aws_dynamodb_table.accounts.arn,
        aws_dynamodb_table.transactions.arn,
        "${aws_dynamodb_table.transactions.arn}/index/created_at-index",
      ]
    }]
  })
}

# --- the blue/green controller: what ECS does to the listener rules ----------
#
# Assumed by the ECS control plane — ecs.amazonaws.com, not ecs-tasks — during a
# traffic shift, to point the production and test listener rules at the other
# target group. Design §8.1's sixth role, found in Phase 0:
# load_balancer.advanced_configuration.role_arn is REQUIRED, and without it the
# service cannot be created at all.

locals {
  # Both control-plane roles share this trust. The account condition matters
  # more here than on the task roles: these are assumed by an AWS service on a
  # trigger whose timing this account does not control.
  ecs_control_plane_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}

resource "aws_iam_role" "bluegreen" {
  name               = "${local.env_prefix}-bluegreen-role"
  assume_role_policy = local.ecs_control_plane_assume_role_policy
}

# The AWS-managed policy, not a hand-written one, and this is the one place in
# the project where that is the *stricter* choice rather than the lazier one.
#
# The action set ECS uses to rewrite listener rules mid-shift is not in the
# provider schema and cannot be read offline. A hand-rolled policy that is
# slightly too narrow does not fail at apply — it fails halfway through a
# production traffic shift, in the window where neither colour cleanly owns the
# listener. The failure mode of getting the managed policy's *name* wrong is the
# opposite and entirely benign: terraform apply fails immediately with "policy
# does not exist", before creating anything, and the runbook's step 3 catches it
# with aws iam get-policy before the apply even runs. Plan §D5.
resource "aws_iam_role_policy_attachment" "bluegreen" {
  role       = aws_iam_role.bluegreen.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}

# --- the hook invoker: what ECS does to the three Lambda functions -----------

# A separate role from bluegreen above, deliberately.
# deployment_configuration.lifecycle_hook.role_arn and
# load_balancer.advanced_configuration.role_arn are two required slots with two
# different permission sets — rewriting production routing, and invoking three
# functions. Design §8.1's stated premise is roles separated by function;
# merging these would give the rule-rewriter permission to invoke arbitrary
# Lambdas and the invoker permission to rewrite production routing. Plan §D4.
resource "aws_iam_role" "hook_invoke" {
  name               = "${local.env_prefix}-hook-invoke-role"
  assume_role_policy = local.ecs_control_plane_assume_role_policy
}

resource "aws_iam_role_policy" "hook_invoke" {
  name = "${local.env_prefix}-hook-invoke-policy"
  role = aws_iam_role.hook_invoke.id

  # The resource list is the three hook ARNs, never a wildcard. This role is
  # assumable by an AWS service on a trigger this account does not control the
  # timing of, which is exactly when a wildcard stops being a convenience.
  #
  # The ARNs are composed from local.hook_function_names rather than read from
  # module.*.function_arn. Both are correct against real AWS; the composed form
  # is what makes the test meaningful, because mock_provider fills every
  # aws_lambda_function.arn with the same string and a set of three identical
  # mocks cannot show that a wildcard has not crept in. hooks.tf names the
  # functions from the same local, and tests/bluegreen.tftest.hcl asserts each
  # module's function_name equals it, so the two cannot drift.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeExactlyTheseLifecycleHooks"
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = values(local.hook_function_arns)
    }]
  })
}
