# Two of design §8.1's six roles. Both are created here rather than in
# foundation because a role's policy cannot be scoped to resources that do not
# exist yet — the Phase 3 §D2 rule — and the tables and log group are this
# layer's.
#
# Policies are built with jsonencode rather than aws_iam_policy_document.
# mock_provider mocks every data source the AWS provider owns, and the policy
# document generator is one of them despite being a pure local computation: it
# returns a random string under test and aws_iam_role rejects it client-side.
# jsonencode keeps the JSON real under mocks, which is what lets the tests
# assert what these policies actually grant. See the plan's F1 and D9.

locals {
  # Shared by both roles: identical trust, different permissions. The account
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
  # GET /api/transactions, which fails AccessDenied at runtime. Plan §F6.
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
