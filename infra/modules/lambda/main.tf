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
  # checkov:skip=CKV_AWS_338:a year of retention on a log group whose entire content is three probe verdicts per deployment, in an environment make teardown destroys at the end of every session. Retention is the whole of what a log group costs. The evidence these lines carry — which stage saw which digest — is read within minutes of the deployment that produced it, by the runbook step that is watching the deployment happen; nobody reads a hook verdict from eleven months ago.
  # checkov:skip=CKV_AWS_158:AES256 rather than a customer-managed key. These logs contain the probe URL, the stage name, and the git_sha and image_digest the endpoint reported — all of which are public facts about a public API. There is no credential, token or customer record in them, so a CMK would add a per-API-call charge and a key to manage in exchange for encrypting information that is already published at /version.
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

# --- the checkov skips, each with the reason it is safe HERE -----------------
#
# These are written for the risk profile of a *blue/green lifecycle hook*: a
# synchronous deployment gate, invoked three times per deployment by the ECS
# control plane, running standard-library code that makes three HTTP requests to
# a public endpoint and holds no secret. That is a different profile from a
# general-purpose Lambda, and each reason below says why rather than pointing at
# another layer.
#
# PHASE 9 MUST RE-EXAMINE THEM. These suppressions live on the module, so a
# metrics collector added here inherits every one of them. A function that calls
# boto3, writes CloudWatch metrics and runs on a schedule has a different answer
# to at least the DLQ and concurrency questions than a synchronous gate does.
resource "aws_lambda_function" "this" {
  # checkov:skip=CKV_AWS_50:X-Ray traces a request as it crosses services. This function calls exactly one thing, over plain urllib, and already logs the stage, the URL, the probe outcome and the digest it saw. A trace would add a sampling charge and a segment for a call the log line already describes in full, and the thing an operator actually needs after a rejected deployment is the exception message naming the path and status — which is in CloudWatch, not in a trace.
  # checkov:skip=CKV_AWS_116:a dead letter queue captures asynchronous invocations that failed after retries. These are invoked SYNCHRONOUSLY by the ECS deployment controller, which is itself the consumer of the result — a failure is delivered to ECS as an invocation error and becomes a rejected deployment stage (plan D3), which is the entire point. There is no dropped event for a DLQ to catch, and a queue here would collect nothing while suggesting to a reader that failures are handled somewhere other than the deployment itself.
  # checkov:skip=CKV_AWS_115:reserved concurrency protects the rest of the account from one function exhausting the pool. Concurrency here is bounded by the deployment controller, not by load: at most three invocations per deployment, sequential across stages, and deployments do not overlap. Reserving concurrency would instead introduce a new failure mode — a deployment gate throttled by its own reservation fails closed, and D3 turns that into the rejection of a build that was fine.
  # checkov:skip=CKV_AWS_117:not VPC-attached, deliberately. The production ALB is internet-facing and network already opens :8443 on the prod ALB security group, so both listeners are reachable over the public internet either way — a private ENI would buy no isolation. It would cost an ENI per concurrent execution, an ENI attachment delay on cold start INSIDE a synchronous deployment gate, and a NAT dependency for a function whose whole job is to run while the deployment is in a fragile state. A VPC-attached hook would need NAT egress to reach its own ALB and would fail closed during exactly the deployments it exists to gate. Plan §D6.
  # checkov:skip=CKV_AWS_173:the environment holds a probe URL, a stage name, and — only when the runbook sets it by hand — an expected image digest. Every one of those is a public fact about a public API; the URL is in DNS and the digest is served at /version. A customer-managed key would bill a Decrypt call per cold start to protect information that is already published, and would add a key whose deletion breaks every deployment.
  # checkov:skip=CKV_AWS_272:code signing binds a deployment package to a signing profile, which answers "did someone replace the zip out of band". The zip is built by data.archive_file from a file in this repository during the same terraform apply that deploys it, and source_code_hash means any change to handler.py is visible in the plan. A signing profile would add a key, a Signer profile and a CI signing step to guard a path that has no unsigned upload in it — and Phase 8's pipeline, which is where an out-of-band replacement would have to enter, does not touch these functions.
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
