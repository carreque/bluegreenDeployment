# What a PutDashboard call will not tell you.
#
# Plan §F8: the API validates a widget's STRUCTURE and the provider surfaces
# that as an apply error, so a malformed widget fails loudly. A widget that is
# structurally perfect and names a metric nothing publishes renders empty and
# fails nothing, forever. These runs are the only place that can be caught
# offline.

mock_provider "aws" {
  mock_resource "aws_acm_certificate" {
    defaults = {
      domain_validation_options = [
        {
          domain_name           = "api.carloscloudengineer.com"
          resource_record_name  = "_mock.api.carloscloudengineer.com."
          resource_record_type  = "CNAME"
          resource_record_value = "_mock.acm-validations.aws."
        },
        {
          domain_name           = "staging-api.carloscloudengineer.com"
          resource_record_name  = "_mock.staging-api.carloscloudengineer.com."
          resource_record_type  = "CNAME"
          resource_record_value = "_mock.acm-validations.aws."
        },
      ]
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:590184028094:bgd-us-east-1-alerts" }
  }
}

# command = apply plans and applies the WHOLE root module, not just the
# dashboard — including the ten CodeBuild service roles pipeline_iam.tftest.hcl
# and app_pipeline_iam.tftest.hcl already override. aws_codebuild_project
# validates service_role as an ARN client-side, and mock_provider's default for
# an un-overridden aws_iam_role.arn is an eight-character random string, which
# fails there before this file's own runs are ever reached. Same fourteen lines
# tests/observability.tftest.hcl carries, for the same reason.
override_resource {
  target = aws_iam_role.pipeline
  values = { arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-infra-pipeline-role" }
}

override_resource {
  target = aws_iam_role.infra_validate
  values = { arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-infra-validate-role" }
}

override_resource {
  target = aws_iam_role.infra_plan
  values = { arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-infra-plan-role" }
}

override_resource {
  target = aws_iam_role.infra_apply
  values = { arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-infra-apply-role" }
}

override_resource {
  target = aws_iam_role.app_pipeline
  values = { arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-app-pipeline-role" }
}

override_resource {
  target = aws_iam_role.app_image
  values = { arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-app-image-role" }
}

override_resource {
  target = aws_iam_role.app_deploy_staging
  values = { arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-app-deploy-staging-role" }
}

override_resource {
  target = aws_iam_role.app_smoke
  values = { arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-app-smoke-role" }
}

override_resource {
  target = aws_iam_role.app_plan_prod
  values = { arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-app-plan-prod-role" }
}

override_resource {
  target = aws_iam_role.app_deploy_prod
  values = { arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-app-deploy-prod-role" }
}

# The collector's own execution role needs the same treatment for the same
# reason: aws_lambda_function.this's `role` argument validates as an ARN
# client-side, and mock_provider's default for an un-overridden
# aws_iam_role.arn is an eight-character string.
override_resource {
  target = module.release_metrics.aws_iam_role.this
  values = { arn = "arn:aws:iam::590184028094:role/bgd-us-east-1-release-metrics-exec-role" }
}

override_resource {
  target = module.release_metrics.aws_lambda_function.this
  values = { arn = "arn:aws:lambda:us-east-1:590184028094:function:bgd-us-east-1-release-metrics" }
}

override_resource {
  target = aws_cloudwatch_event_rule.pipeline_executions
  values = { arn = "arn:aws:events:us-east-1:590184028094:rule/bgd-us-east-1-pipeline-executions" }
}

override_resource {
  target = aws_cloudwatch_event_rule.prod_deployments
  values = { arn = "arn:aws:events:us-east-1:590184028094:rule/bgd-us-east-1-prod-deployments" }
}

run "the_body_is_valid_json_with_widgets" {
  command = apply

  assert {
    condition     = length(jsondecode(aws_cloudwatch_dashboard.release.dashboard_body).widgets) == 12
    error_message = "the dashboard must carry exactly the twelve widgets the design specifies — the header, four release-metric tiles, the pipeline band, four production tiles and two staging/collector tiles"
  }

  assert {
    condition = alltrue([
      for widget in jsondecode(aws_cloudwatch_dashboard.release.dashboard_body).widgets :
      contains(["metric", "text"], widget.type)
    ])
    error_message = "only metric and text widgets — a log widget would name a prod log group that make teardown deletes (plan D17)"
  }
}

run "every_release_metric_this_phase_writes_appears_on_the_dashboard" {
  command = apply

  # The failure this catches is a metric that is emitted, billed, and never
  # looked at — or worse, one renamed in handler.py and left stale here.
  assert {
    condition = alltrue([
      for metric_name in [
        "DeploymentSucceeded",
        "DeploymentFailed",
        "DeploymentRolledBack",
        "LeadTimeSeconds",
        "RecoveryTimeSeconds",
        "PipelineFailed",
      ] : strcontains(aws_cloudwatch_dashboard.release.dashboard_body, metric_name)
    ])
    error_message = "every metric the collector writes must be shown somewhere on the dashboard"
  }

  assert {
    condition     = strcontains(aws_cloudwatch_dashboard.release.dashboard_body, var.metric_namespace)
    error_message = "the widgets must read the namespace the collector writes to"
  }
}

run "the_alb_widgets_search_by_name_and_the_rest_name_dimensions_literally" {
  command = apply

  # Plan §D17. If a LoadBalancer dimension value ever appears literally here,
  # someone has hard-coded an arn_suffix that a teardown/rebuild will change,
  # and the widget will go quietly empty on the next rebuild.
  assert {
    condition     = strcontains(aws_cloudwatch_dashboard.release.dashboard_body, "SEARCH(")
    error_message = "ALB widgets must search by load balancer name, not by a suffix this layer cannot know"
  }

  assert {
    condition = alltrue([
      for name in [
        local.observability.prod_alb_name,
        local.observability.staging_alb_name,
        local.observability.prod_cluster_name,
        local.observability.prod_service_name,
      ] : strcontains(aws_cloudwatch_dashboard.release.dashboard_body, name)
    ])
    error_message = "both environments' load balancers and the production service must be on the dashboard (plan D15)"
  }
}
