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
