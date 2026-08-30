# The collector, its permissions, the two rules that feed it and the alarm that
# watches it.
#
# `command = apply` throughout, for the reason pipeline_iam.tftest.hcl records:
# every policy here interpolates a computed ARN — the topic's, both pipelines'
# — and a computed attribute is unknown under `command = plan`, which makes the
# whole jsonencode unknown and the condition unevaluable. Against a mocked
# provider apply creates nothing and needs no credentials.
#
# The archive provider is NOT mocked, deliberately. mock_provider "aws" leaves
# it alone, so this really builds the collector's zip from
# lambdas/release_metrics/handler.py — a wrong source_file fails here rather
# than at the first invocation. Phase 6 §F4, reused; plan §F12.
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
# collector — including the ten CodeBuild service roles pipeline_iam.tftest.hcl
# and app_pipeline_iam.tftest.hcl already override. aws_codebuild_project
# validates service_role as an ARN client-side, and mock_provider's default for
# an un-overridden aws_iam_role.arn is an eight-character random string, which
# fails there before this file's own runs are ever reached. Same ten lines
# those two files carry, for the same reason.
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

run "the_collector_is_packaged_and_runs_on_the_pinned_runtime" {
  command = apply

  assert {
    condition     = module.release_metrics.function_name == "bgd-us-east-1-release-metrics"
    error_message = "the collector takes no <env> segment: it is a shared resource (convention §2)"
  }

  assert {
    condition     = module.release_metrics.runtime == "python3.14"
    error_message = "the collector must run the same interpreter as the container and the hooks"
  }

  assert {
    condition     = contains(module.release_metrics.architectures, "arm64")
    error_message = "arm64, matching the hooks and the container"
  }

  # The four the handler reads. A missing one is not an apply failure — it is a
  # collector that writes to the default namespace, or one that cannot find the
  # topic and logs the alert away. Plan §D9's own error path.
  assert {
    condition = alltrue([
      module.release_metrics.environment_variables["BGD_METRIC_NAMESPACE"] == "ReleaseMetrics",
      module.release_metrics.environment_variables["BGD_ENVIRONMENT"] == "prod",
      module.release_metrics.environment_variables["BGD_APP_PIPELINE"] == aws_codepipeline.app.name,
      module.release_metrics.environment_variables["BGD_ALERT_TOPIC_ARN"] != "",
    ])
    error_message = "the collector's environment must name the namespace, the environment, the app pipeline and the topic"
  }
}

run "the_collector_may_write_only_its_own_namespace" {
  command = apply

  # The one least-privilege lever PutMetricData offers. Without the condition
  # this role can overwrite any metric in the account, including the AWS/ECS
  # series the bake alarms read. Plan §F5.
  assert {
    condition     = jsondecode(aws_iam_role_policy.release_metrics.policy).Statement[0].Condition.StringEquals["cloudwatch:namespace"] == var.metric_namespace
    error_message = "PutMetricData must be confined to the release metrics namespace by condition"
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.release_metrics.policy).Statement :
      !contains(statement.Action, "cloudwatch:PutMetricData") || contains(keys(statement), "Condition")
    ])
    error_message = "no unconditioned PutMetricData statement may exist"
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.release_metrics.policy).Statement :
      !contains(statement.Action, "sns:Publish") || statement.Resource == [aws_sns_topic.alerts.arn]
    ])
    error_message = "sns:Publish must name the alert topic and nothing else"
  }

  # The collector reads two pipelines' executions to compute lead time. It has
  # no business starting, stopping or approving one.
  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.release_metrics.policy).Statement :
      alltrue([
        for action in statement.Action :
        !startswith(action, "codepipeline:") || contains([
          "codepipeline:GetPipelineExecution",
          "codepipeline:ListPipelineExecutions",
        ], action)
      ])
    ])
    error_message = "the collector reads pipeline executions; it must not be able to act on one"
  }
}

run "the_pipeline_rule_watches_both_pipelines_and_only_the_terminal_states" {
  command = apply

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.pipeline_executions.event_pattern)["detail-type"] == ["CodePipeline Pipeline Execution State Change"]
    error_message = "the pipeline rule must match execution state changes, not stage or action ones"
  }

  assert {
    condition = toset(jsondecode(aws_cloudwatch_event_rule.pipeline_executions.event_pattern).detail.pipeline) == toset([
      aws_codepipeline.infra.name,
      aws_codepipeline.app.name,
    ])
    error_message = "both pipelines, named rather than wildcarded"
  }

  # SUCCEEDED for lead time and MTTR, FAILED for the alert. STARTED and
  # SUPERSEDED would invoke the collector for nothing — and unlike the ECS
  # rule there is no unknown vocabulary here to leave room for, because
  # CodePipeline's execution states are a documented closed set.
  assert {
    condition     = toset(jsondecode(aws_cloudwatch_event_rule.pipeline_executions.event_pattern).detail.state) == toset(["SUCCEEDED", "FAILED"])
    error_message = "the pipeline rule matches SUCCEEDED and FAILED only"
  }
}

run "the_deployment_rule_names_the_production_service_and_does_not_filter_event_names" {
  command = apply

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.prod_deployments.event_pattern).resources == [
      "arn:aws:ecs:us-east-1:590184028094:service/bgd-us-east-1-prod-cluster/bgd-us-east-1-prod-api"
    ]
    error_message = "the deployment rule must name the production service exactly; staging deployments are not release metrics (plan D15)"
  }

  # Plan §D4, and the single assertion most worth having in this file. Which
  # eventName a blue/green rollback produces is a runtime contract with no
  # offline source of truth (§F3). A filter here that guesses wrong makes the
  # rollback this project exists to demonstrate produce no metric and no email,
  # with the rule still looking correct in the console.
  # Asserted against the raw pattern string rather than the decoded object,
  # deliberately. The correct pattern has no `detail` key at all, so
  # jsondecode(...).detail is an error rather than a null — an assertion written
  # that way fails on the configuration it is meant to pass.
  assert {
    condition     = !strcontains(aws_cloudwatch_event_rule.prod_deployments.event_pattern, "eventName")
    error_message = "the deployment rule must not filter on eventName — an unrecognised name has to reach the handler and be logged (plan D4)"
  }
}

run "both_targets_bound_delivery_and_both_permissions_name_their_own_rule" {
  command = apply

  # Plan §F11. Unset, EventBridge retries for 24 hours across 185 attempts: a
  # "deployment failed" email arriving tomorrow, and a broken collector invoked
  # all day.
  assert {
    condition = alltrue([
      for target in [
        aws_cloudwatch_event_target.pipeline_executions,
        aws_cloudwatch_event_target.prod_deployments,
      ] : one(target.retry_policy).maximum_retry_attempts == 2 && one(target.retry_policy).maximum_event_age_in_seconds == 300
    ])
    error_message = "both targets must bound retries to three attempts over five minutes"
  }

  # Crossed source_arns is the failure this catches: both permissions would
  # still apply, both rules would still fire, and nothing would ever report it —
  # until someone removed one rule and the other stopped working.
  assert {
    condition = (
      aws_lambda_permission.pipeline_executions.source_arn == aws_cloudwatch_event_rule.pipeline_executions.arn &&
      aws_lambda_permission.prod_deployments.source_arn == aws_cloudwatch_event_rule.prod_deployments.arn
    )
    error_message = "each permission must be scoped to the rule it exists for"
  }

  assert {
    condition = alltrue([
      for permission in [
        aws_lambda_permission.pipeline_executions,
        aws_lambda_permission.prod_deployments,
      ] : permission.principal == "events.amazonaws.com" && permission.function_name == module.release_metrics.function_name
    ])
    error_message = "both permissions must let EventBridge, and only EventBridge, invoke the collector"
  }
}
