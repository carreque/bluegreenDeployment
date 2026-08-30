# One dashboard, four bands: release metrics, pipeline health, production
# health, staging health. Plan §D15 — the metrics are production's, the health
# is both environments', because "staging is sick" is the answer to "why did the
# pipeline stop" and that should not need a second console tab.
#
# Widgets are built as HCL and jsonencoded once at the bottom. The alternative,
# a heredoc of JSON, cannot interpolate a name without quoting rules nobody
# remembers and cannot be read in a diff.
#
# NO LOG WIDGETS, deliberately, and this is the one shape decision the layer
# split forces on the presentation. A log widget names a log group; the ones
# worth showing — the hook groups, the production container's — belong to a
# layer `make teardown` destroys, and a widget pointed at a missing group
# renders an error rather than an empty chart. Metric widgets degrade to empty
# and recover on rebuild, which is the behaviour this dashboard needs.

locals {
  # Every ALB and target-group series, matched by NAME. The LoadBalancer
  # dimension value is app/<name>/<16 hex characters> and the hex is assigned at
  # creation, so it is the one dimension this layer cannot compose — see plan
  # §D17. Searching survives the rebuild that changes it.
  alb_search = {
    prod_5xx        = "SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"HTTPCode_Target_5XX_Count\" ${local.observability.prod_alb_name}', 'Sum', 60)"
    prod_requests   = "SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"RequestCount\" ${local.observability.prod_alb_name}', 'Sum', 60)"
    prod_latency    = "SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"TargetResponseTime\" ${local.observability.prod_alb_name}', 'p95', 60)"
    prod_unhealthy  = "SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} MetricName=\"UnHealthyHostCount\" ${local.observability.prod_alb_name}', 'Maximum', 60)"
    staging_5xx     = "SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"HTTPCode_Target_5XX_Count\" ${local.observability.staging_alb_name}', 'Sum', 60)"
    staging_latency = "SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"TargetResponseTime\" ${local.observability.staging_alb_name}', 'p95', 60)"
  }

  # Twelve widgets, in the order the plan lists them, laid out in four bands so
  # the boundary between "release process" and "environment health" is visible
  # without reading a title. Every widget carries explicit x/y/width/height —
  # the console's own auto-layout would not reproduce these bands, and the
  # result would look arbitrary to the next person who opens it.
  dashboard_widgets = [
    # --- band 0: what this dashboard is ------------------------------------
    {
      type   = "text"
      x      = 0
      y      = 0
      width  = 24
      height = 4
      properties = {
        markdown = join("\n\n", [
          "# ${local.observability.dashboard_name}",
          join(" ", [
            "Release health: how often production deploys, how many of those",
            "deploys fail, how long a change takes to reach production, and how",
            "long a failure takes to recover from — plus both environments'",
            "request, latency and error health, because a sick staging",
            "environment is usually the answer to \"why did the pipeline stop\".",
          ]),
          join(" ", [
            "**Lead time basis:** the source revision's commit timestamp when",
            "CodePipeline populates one for the CodeConnections source;",
            "otherwise the execution's own start time (merge-to-production).",
            "The collector logs which basis was used on every emission — plan D6.",
          ]),
          join(" ", [
            "**Pipelines:**",
            "[Infrastructure](https://${var.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.infra.name}/view?region=${var.region})",
            "·",
            "[Application](https://${var.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.app.name}/view?region=${var.region})",
            "&nbsp;&nbsp;**APIs:**",
            "[Production](https://${local.api_domain})",
            "·",
            "[Staging](https://${local.staging_api_domain})",
          ]),
          join(" ", [
            "**Bake alarm thresholds are chosen, not measured** — five",
            "target-5xx responses a minute, a 2-second p95, one unhealthy host",
            "per colour. See infra/environments/prod/alarms.tf; the runbook",
            "records the real numbers once traffic exists to measure.",
          ]),
        ])
      }
    },

    # --- band 1: release metrics --------------------------------------------
    {
      type   = "metric"
      x      = 0
      y      = 4
      width  = 6
      height = 6
      properties = {
        view   = "bar"
        stat   = "Sum"
        period = 86400
        region = var.region
        title  = "Deployment frequency (per day)"
        metrics = [
          [var.metric_namespace, "DeploymentSucceeded", "Environment", "prod"],
          [var.metric_namespace, "DeploymentFailed", "Environment", "prod"],
        ]
      }
    },
    {
      type   = "metric"
      x      = 6
      y      = 4
      width  = 6
      height = 6
      properties = {
        view   = "singleValue"
        stat   = "Sum"
        period = 86400
        region = var.region
        title  = "Change failure rate (%)"
        metrics = [
          [var.metric_namespace, "DeploymentFailed", "Environment", "prod", { id = "failed", visible = false }],
          [var.metric_namespace, "DeploymentSucceeded", "Environment", "prod", { id = "succeeded", visible = false }],
          # FILL(..., 0) is load-bearing, within what it actually does: it
          # interpolates a missing datapoint inside a period where the OTHER
          # series in the expression still has data, turning that gap into 0
          # rather than leaving the whole expression undefined for that period.
          # It does not synthesize a series where the metric published nothing
          # at all — a week with no deployments of either kind still renders
          # this tile empty, correctly, because there is no ratio to show.
          [{ expression = "100 * FILL(failed, 0) / (FILL(failed, 0) + FILL(succeeded, 0))", label = "Change failure rate %", id = "cfr" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 4
      width  = 6
      height = 6
      properties = {
        view   = "timeSeries"
        stat   = "Average"
        region = var.region
        title  = "Lead time, commit to production (s)"
        metrics = [
          [var.metric_namespace, "LeadTimeSeconds", "Environment", "prod"],
        ]
      }
    },
    {
      type   = "metric"
      x      = 18
      y      = 4
      width  = 6
      height = 6
      properties = {
        view   = "singleValue"
        stat   = "Average"
        region = var.region
        title  = "MTTR (s)"
        metrics = [
          [var.metric_namespace, "RecoveryTimeSeconds", "Environment", "prod"],
        ]
      }
    },

    # --- band 2: pipeline health ---------------------------------------------
    {
      type   = "metric"
      x      = 0
      y      = 10
      width  = 24
      height = 6
      properties = {
        view   = "bar"
        stat   = "Sum"
        region = var.region
        title  = "Pipeline failures and rollbacks"
        metrics = [
          [var.metric_namespace, "PipelineFailed", "PipelineName", aws_codepipeline.infra.name],
          [var.metric_namespace, "PipelineFailed", "PipelineName", aws_codepipeline.app.name],
          [var.metric_namespace, "DeploymentRolledBack", "Environment", "prod"],
        ]
      }
    },

    # --- band 3: production health -------------------------------------------
    {
      type   = "metric"
      x      = 0
      y      = 16
      width  = 6
      height = 6
      properties = {
        view   = "timeSeries"
        region = var.region
        title  = "Production requests and 5xx"
        metrics = [
          [{ expression = local.alb_search.prod_requests, label = "Requests", id = "pr" }],
          [{ expression = local.alb_search.prod_5xx, label = "5xx", id = "p5" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 6
      y      = 16
      width  = 6
      height = 6
      properties = {
        view   = "timeSeries"
        region = var.region
        title  = "Production p95 and unhealthy targets"
        metrics = [
          [{ expression = local.alb_search.prod_latency, label = "p95 latency", id = "pl" }],
          [{ expression = local.alb_search.prod_unhealthy, label = "Unhealthy hosts", id = "pu" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 16
      width  = 6
      height = 6
      properties = {
        view   = "timeSeries"
        stat   = "Average"
        region = var.region
        title  = "Production service"
        metrics = [
          ["AWS/ECS", "CPUUtilization", "ClusterName", local.observability.prod_cluster_name, "ServiceName", local.observability.prod_service_name],
          ["AWS/ECS", "MemoryUtilization", "ClusterName", local.observability.prod_cluster_name, "ServiceName", local.observability.prod_service_name],
          ["AWS/ECS", "RunningTaskCount", "ClusterName", local.observability.prod_cluster_name, "ServiceName", local.observability.prod_service_name, { stat = "Maximum" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 18
      y      = 16
      width  = 6
      height = 6
      properties = {
        view   = "timeSeries"
        stat   = "Sum"
        region = var.region
        title  = "Production tables"
        # concat(...) with the expand operator, not flatten(): flatten()
        # recursively flattens every nesting level, which here would collapse
        # each three-element metric tuple down into the surrounding list of
        # tuples — one flat list of scalars where CloudWatch expects a list of
        # arrays. concat() only merges its top-level arguments, which is the
        # one level of nesting that needs removing (per-table groups), leaving
        # each metric tuple intact.
        metrics = concat([
          for table in local.observability.prod_table_names : [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", table],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", table],
            ["AWS/DynamoDB", "ThrottledRequests", "TableName", table],
          ]
        ]...)
      }
    },

    # --- band 4: staging health -----------------------------------------------
    {
      type   = "metric"
      x      = 0
      y      = 22
      width  = 12
      height = 6
      properties = {
        view   = "timeSeries"
        region = var.region
        title  = "Staging health"
        metrics = [
          [{ expression = local.alb_search.staging_5xx, label = "5xx", id = "s5" }],
          [{ expression = local.alb_search.staging_latency, label = "p95 latency", id = "sl" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 22
      width  = 12
      height = 6
      properties = {
        view   = "timeSeries"
        region = var.region
        title  = "The collector itself"
        metrics = [
          ["AWS/Lambda", "Invocations", "FunctionName", local.observability.collector_name, { stat = "Sum" }],
          ["AWS/Lambda", "Errors", "FunctionName", local.observability.collector_name, { stat = "Sum" }],
          ["AWS/Lambda", "Duration", "FunctionName", local.observability.collector_name, { stat = "Average" }],
        ]
      }
    },
  ]
}

# A dashboard whose data source is broken should say so on its own face — the
# last widget above is the collector's own health, not something bolted onto a
# separate console tab.
resource "aws_cloudwatch_dashboard" "release" {
  dashboard_name = local.observability.dashboard_name
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
