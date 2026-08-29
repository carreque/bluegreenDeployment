# Four resources per instantiation: the archive, the function, its log group,
# and the execution role that lets it write to that group and nothing else.
#
# The module has no conditionals, no for_each and no computed names. That is
# deliberate and it is why it has no test suite of its own — the calling layer's
# assertions on three real instantiations cover everything it does, and a suite
# over a module with no branches asserts that Terraform works. See
# infra/environments/prod/tests/bluegreen.tftest.hcl.

# Built during terraform plan and terraform test alike. archive is a different
# provider from aws, so mock_provider "aws" does not touch it and the zip is
# genuinely produced on disk from var.source_file — which means the offline gate
# fails loudly if the handler path is wrong, rather than mocking away the step
# most likely to be misconfigured. Plan §F4.
data "archive_file" "this" {
  type        = "zip"
  source_file = var.source_file
  output_path = "${path.module}/.build/${var.function_name}.zip"

  # Without this the archived file inherits whatever mode it has on the machine
  # that ran the plan, so a clone with different umask produces a different
  # hash and terraform plan shows a redeploy that changes nothing.
  output_file_mode = "0644"
}

resource "aws_cloudwatch_log_group" "this" {
  # /aws/lambda/<function-name>, not the convention's /bgd/<region>/<env>/<x>.
  # That prefix is what Lambda writes to unless a logging_config block redirects
  # it, and every console path, sample query and AWS tool assumes it. Deviating
  # would gain consistency in a naming document and lose it everywhere an
  # operator actually looks. Plan §F8; amended into the convention.
  #
  # Created explicitly rather than left to Lambda's implicit creation, for two
  # reasons: retention is then managed rather than "never expire", and the
  # execution role below can be scoped to this group's ARN.
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "this" {
  name = "${var.function_name}-exec-role"

  # No aws:SourceAccount condition, unlike the ecs-tasks and ecs roles in the
  # calling layer. A Lambda execution role is assumed by the Lambda service only
  # in the context of a function that already lives in this account, so there is
  # no cross-account principal for the condition to exclude.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "this" {
  name = "${var.function_name}-exec-policy"
  role = aws_iam_role.this.id

  # jsonencode rather than aws_iam_policy_document: mock_provider mocks every
  # data source the AWS provider owns, and the policy document generator is one
  # of them despite being a pure local computation. Under test it returns a
  # random string, so a policy built through it asserts nothing. Phase 5 §D9.
  #
  # logs:CreateLogGroup is deliberately absent, for the reason staging/iam.tf
  # already records: granting it lets a typo in a name produce a second,
  # unmanaged group instead of failing. The group above is the only one this
  # function may write to.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "WriteThisFunctionsLogsOnly"
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.this.arn}:*"
    }]
  })
}

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  role          = aws_iam_role.this.arn
  handler       = var.handler

  # python3.14, matching the container and the local interpreter exactly. Phase
  # 0's A4 confirmed the identifier is in the provider's enum; its own caveat is
  # that membership proves the identifier is *recognised*, not that the runtime
  # is creatable. The first apply is what confirms that.
  runtime = "python3.14"

  # arm64, matching the container's Graviton choice and its price. Nothing in
  # the handler is architecture-sensitive — it is standard library only — so the
  # only thing this changes is the bill.
  architectures = ["arm64"]

  filename = data.archive_file.this.output_path

  # Without this a changed handler.py produces an identical filename and
  # Terraform sees no reason to redeploy, so the fix you just wrote never
  # reaches the function that gates production.
  source_code_hash = data.archive_file.this.output_base64sha256

  timeout     = var.timeout_seconds
  memory_size = var.memory_size_mb

  dynamic "environment" {
    # Omitted entirely rather than sent empty when there is nothing to set: an
    # empty environment block is a valid but pointless diff.
    for_each = length(var.environment) > 0 ? [var.environment] : []

    content {
      variables = environment.value
    }
  }

  # The log group Terraform manages must exist before Lambda would create one
  # implicitly on first invocation. Nothing else in this file makes the function
  # depend on the group, so without this they are unordered.
  depends_on = [aws_cloudwatch_log_group.this]
}
