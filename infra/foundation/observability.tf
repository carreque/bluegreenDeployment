# The observability plane: one collector, two rules, one alarm.
#
# It lives in this layer and not in prod, and that is forced rather than
# preferred — see plan §D2 and §F1. The short version: prod already reads this
# layer's remote state, so the mirror would be a cycle Terraform does not detect;
# and the metric history is the deliverable, so it must outlive `make teardown`.
#
# What prod owns is four lines: alarm_actions on the bake alarms, which can only
# be set where the alarm is.

module "release_metrics" {
  source = "../modules/lambda"

  function_name      = local.observability.collector_name
  source_file        = "${path.module}/../../lambdas/release_metrics/handler.py"
  log_retention_days = var.collector_log_retention_days

  # 256, against the hooks' 128. Not because the work is heavy — it is four API
  # calls — but because importing boto3 on a cold start is the whole of this
  # function's runtime, and memory scales CPU. The difference is fractions of a
  # cent a month at this invocation rate and a second off every cold start.
  memory_size_mb = 256

  # 30, against the hooks' 60. Nothing here waits on a five-minute bake: the
  # slowest path is get_metric_data plus put_metric_data. A collector still
  # running after thirty seconds is stuck, and a stuck async invocation retries
  # and then fires the errors alarm, which is the behaviour wanted.
  timeout_seconds = 30

  # Everything the handler reads. It has defaults for the first three, so a
  # missing one is silent rather than fatal — which is why they are asserted in
  # tests/observability.tftest.hcl rather than trusted.
  environment = {
    BGD_METRIC_NAMESPACE   = var.metric_namespace
    BGD_ENVIRONMENT        = "prod"
    BGD_MTTR_LOOKBACK_DAYS = tostring(var.mttr_lookback_days)
    BGD_ALERT_TOPIC_ARN    = aws_sns_topic.alerts.arn
    BGD_APP_PIPELINE       = aws_codepipeline.app.name
  }
}

# Attached to the role the module created, rather than a role of its own. The
# module's role already carries the one policy every function here needs — write
# to its own log group and nothing else — and a second role would mean the
# function had two, one of which could not be the execution role.
#
# This is where iam-app-pipeline.tf's prediction that "Phase 9 adds a third set"
# turns out to be wrong: it is one policy, not a set, and separating it from the
# function it belongs to would cost a file and gain nothing.
resource "aws_iam_role_policy" "release_metrics" {
  name = "${local.observability.collector_name}-collect-policy"
  role = module.release_metrics.role_name

  # jsonencode rather than aws_iam_policy_document, the rule every IAM file in
  # this project follows: mock_provider mocks the policy-document data source
  # too, so a policy built through it is a random string under test and every
  # assertion on it is vacuous. Phase 5 §F1.
  #
  # Action and Resource are LISTS even at one element, so the test file can use
  # contains() and == without a type check first.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # PutMetricData takes no resource ARN — CloudWatch metrics are not resources — so "*" is the only Resource this action accepts. The Condition below is the actual control and it is tighter than a resource scope would be: this role can write the ReleaseMetrics namespace and no other, so a compromised collector cannot overwrite the AWS/ApplicationELB series the bake alarms read.
        #
        # No checkov:skip here, deliberately: this statement and the one below share
        # one aws_iam_role_policy resource, and CKV_AWS_355 evaluates per resource, not
        # per statement — a skip on either statement suppresses the check for both, and
        # removing both directives moved only one check from skipped to passed
        # (488/110 -> 489/109). The check passes unsuppressed; do not re-add a skip here.
        Sid       = "PublishReleaseMetricsOnly"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = ["*"]
        Condition = { StringEquals = { "cloudwatch:namespace" = var.metric_namespace } }
      },
      {
        # GetMetricData takes no resource ARN either, and unlike PutMetricData it supports no namespace condition key — the read is account-wide or it does not happen. What it buys is MTTR with no state store (plan D7): the metric store is the state store, so there is no DynamoDB table, no S3 marker and no second thing to keep in step. The exposure is read access to metric values in an account that holds one project.
        Sid      = "ReadBackTheFailureAndSuccessSeries"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = ["*"]
      },
      {
        Sid      = "AlertOnFailuresAndRollbacks"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.alerts.arn]
      },
      {
        # Read, never act. Lead time needs to know when the change was made;
        # nothing here needs to start, retry, stop or approve an execution, and
        # a collector that could would be a strange thing to have subscribed to
        # pipeline events.
        #
        # Both pipeline ARNs are granted even though the handler today only ever
        # calls GetPipelineExecution/ListPipelineExecutions for the app pipeline
        # (lead time is commit-to-PRODUCTION, plan D6, and the infra pipeline
        # deploys layers, not the application). This is deliberate, not an
        # oversight: the pipeline_executions rule already delivers infra-pipeline
        # execution events to this collector, so a future change that computes
        # something from an infra execution is a one-line handler change rather
        # than also a Terraform change — and a runtime AccessDenied on a read-only
        # grant scoped to two named ARNs would be a confusing debugging session
        # for very little isolation gained.
        Sid    = "ReadTheTwoPipelinesExecutions"
        Effect = "Allow"
        Action = ["codepipeline:GetPipelineExecution", "codepipeline:ListPipelineExecutions"]
        Resource = [
          aws_codepipeline.infra.arn,
          aws_codepipeline.app.arn,
        ]
      },
    ]
  })
}

# --- what reaches the collector ----------------------------------------------

resource "aws_cloudwatch_event_rule" "pipeline_executions" {
  name = "${local.name_prefix}-pipeline-executions"
  description = join(" ", [
    "Both pipelines' terminal execution states, for the failure alert and for",
    "lead time. SUCCEEDED and FAILED only: CodePipeline's execution states are",
    "a documented closed set, so unlike the ECS rule there is no unknown",
    "vocabulary to leave room for.",
  ])

  event_pattern = jsonencode({
    source        = ["aws.codepipeline"]
    "detail-type" = ["CodePipeline Pipeline Execution State Change"]
    detail = {
      # Named rather than wildcarded. This account holds one project today; a
      # pattern that matched every pipeline would silently start counting
      # someone else's the day it does not.
      pipeline = [aws_codepipeline.infra.name, aws_codepipeline.app.name]
      state    = ["SUCCEEDED", "FAILED"]
    }
  })
}

resource "aws_cloudwatch_event_rule" "prod_deployments" {
  name = "${local.name_prefix}-prod-deployments"
  description = join(" ", [
    "Every ECS deployment state change on the production service. Deliberately",
    "unfiltered by eventName — which names a blue/green rollback emits is a",
    "runtime contract with no offline source of truth, and a wrong guess would",
    "make rollbacks invisible. Plan D4 and F3.",
  ])

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change"]

    # The service ARN, composed from this layer's own convention variables
    # rather than read from prod's remote state — plan §D2. Staging's service is
    # deliberately absent: staging is built to fail fast, and counting its
    # deployments would inflate frequency and deflate change failure rate at the
    # same time (plan §D15).
    resources = [local.observability.prod_service_arn]
  })
}

resource "aws_cloudwatch_event_target" "pipeline_executions" {
  rule      = aws_cloudwatch_event_rule.pipeline_executions.name
  target_id = "release-metrics"
  arn       = module.release_metrics.function_arn

  # Plan §F11: unset, this is 185 attempts across 24 hours. Three attempts
  # inside five minutes is what an alert is worth, and after that the collector's
  # Errors alarm has already said so.
  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 300
  }
}

resource "aws_cloudwatch_event_target" "prod_deployments" {
  rule      = aws_cloudwatch_event_rule.prod_deployments.name
  target_id = "release-metrics"
  arn       = module.release_metrics.function_arn

  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 300
  }
}

# One permission per rule rather than one covering both. source_arn takes a
# single ARN, and a permission scoped to one rule is what makes "this rule may
# invoke the collector" a statement rather than "EventBridge may".
resource "aws_lambda_permission" "pipeline_executions" {
  statement_id  = "AllowInvocationFromPipelineExecutionsRule"
  action        = "lambda:InvokeFunction"
  function_name = module.release_metrics.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_executions.arn
}

resource "aws_lambda_permission" "prod_deployments" {
  statement_id  = "AllowInvocationFromProdDeploymentsRule"
  action        = "lambda:InvokeFunction"
  function_name = module.release_metrics.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.prod_deployments.arn
}

# --- who watches the watcher -------------------------------------------------
#
# Every alert this phase produces is published BY the collector, which makes a
# broken collector silent. This is the exception: CloudWatch alarms on the
# function's own Errors metric and publishes to the topic directly, so the one
# failure the design cannot route through the Lambda does not have to be.
#
# One error in one minute is enough. This function runs a few times a week and
# every invocation matters; there is no volume here for a threshold to smooth.

resource "aws_cloudwatch_metric_alarm" "release_metrics_errors" {
  alarm_name = "${local.observability.collector_name}-errors"
  alarm_description = join(" ", [
    "The release metrics collector raised. Something it needed from CloudWatch,",
    "SNS or CodePipeline failed — which means metrics and alerts are being",
    "lost. This alarm does not travel through the collector (plan D13).",
  ])

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  statistic   = "Sum"

  dimensions = {
    FunctionName = module.release_metrics.function_name
  }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 1

  # Load-bearing, not cosmetic: the collector runs a handful of times a week,
  # so the Errors metric is absent almost always, and the default treatment
  # would park this alarm in INSUFFICIENT_DATA permanently — one that never
  # fires and never says why.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]

  # No ok_actions, matching D16: the collector recovering is not news, and this
  # topic has one subscriber whose attention is the scarce resource.
}
