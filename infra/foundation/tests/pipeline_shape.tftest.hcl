# The pipeline's wiring: what runs, in what order, fed by which artifact.
#
# These are the assertions a plan review cannot make. Stage order is a list
# position, artifact hand-off is a string that has to match another string in a
# different block, and the trigger's path filter is invisible until the wrong
# commit starts a run.

# The mocks below exist because of `command = apply`, and each was added
# because omitting it produced a hard error rather than because it looked tidy
# — the same rule infra/environments/prod/tests/compute.tftest.hcl follows.
#
#   aws_acm_certificate      domain_validation_options mocks to an empty set,
#                            and acm.tf's one([...]) over it then yields null
#                            for a required argument of the validation records.
#   aws_sns_topic            aws_sns_topic_subscription validates topic_arn
#                            client-side, and a random eight-character string
#                            is not an ARN.
#
# The four IAM roles get an ARN each through override_resource rather than one
# shared mock_resource default, for the reason prod's bluegreen.tftest.hcl
# gives: aws_codebuild_project validates service_role client-side, so the roles
# need real-looking ARNs — but one default for the type would give all four the
# same ARN, and "the plan project runs as the plan role" would then hold even
# with the plan and apply roles crossed.
#
# Nothing else is mocked. Every other computed ARN here is compared against
# itself — the rendered policy against the resource it was rendered from — so
# the generated value is enough, and leaving the three build projects with
# three distinct generated ARNs is what makes the RunTheBuilds assertion notice
# a missing one.
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

# Phase 8's six roles. Nothing in this file asserts on them, and they are here
# because `command = apply` applies the WHOLE module: their five projects
# validate service_role client-side too, and an un-overridden mock ARN is an
# eight-character string rather than an ARN. Found while adding the app
# pipeline (Phase 8 §F16); a Phase 9 role set will need the same three lines.
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

# Phase 9's collector role, for the identical reason the block above states:
# `command = apply` reaches module.release_metrics too, and
# aws_lambda_function.this's `role` argument validates as an ARN client-side.
# A Phase 10 role set will need the same shape of line.
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

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
  domain_name  = "carloscloudengineer.com"
}

run "the_layer_list_is_in_dependency_order_not_lexical_order" {
  command = plan

  assert {
    condition     = [for l in local.pipeline_layers : l.name] == ["foundation", "network", "staging", "prod"]
    error_message = "the layers must be ordered foundation, network, staging, prod — a map would sort prod before staging and apply production first"
  }
}

run "every_environment_layer_has_an_image_tag_parameter" {
  command = plan

  assert {
    condition     = toset(keys(aws_ssm_parameter.image_tag)) == toset(["staging", "prod"])
    error_message = "staging and prod each need /bgd/<env>/image_tag; terraform.tfvars does not exist in CodeBuild (plan §F7)"
  }

  assert {
    condition     = aws_ssm_parameter.image_tag["prod"].name == "/bgd/prod/image_tag"
    error_message = "the parameter name is what scripts/pipeline-terraform.sh looks up; it is derived, not typed twice"
  }

  assert {
    condition     = alltrue([for p in aws_ssm_parameter.image_tag : p.type == "String"])
    error_message = "an image tag is printed in every build log and every /version response; SecureString would imply it is a secret"
  }
}

run "only_the_validate_project_runs_containers" {
  command = plan

  assert {
    condition     = one(aws_codebuild_project.infra_validate.environment).privileged_mode
    error_message = "scripts/lint-infra.sh runs tflint and checkov from digest-pinned containers; without privileged mode docker cannot start"
  }

  assert {
    # coalesce, because privileged_mode is optional with no schema default:
    # leaving it out leaves the attribute null rather than false, and `!null`
    # is an error rather than a passing assertion.
    condition = (
      !coalesce(one(aws_codebuild_project.infra_plan.environment).privileged_mode, false) &&
      !coalesce(one(aws_codebuild_project.infra_apply.environment).privileged_mode, false)
    )
    error_message = "plan and apply run no containers; privileged mode there is reach nobody asked for"
  }
}

run "every_project_is_x86_because_the_lint_digests_are" {
  command = plan

  assert {
    condition = alltrue([
      for p in [aws_codebuild_project.infra_validate, aws_codebuild_project.infra_plan, aws_codebuild_project.infra_apply] :
      one(p.environment).type == "LINUX_CONTAINER"
    ])
    error_message = "ARM_CONTAINER would pull the pinned tflint and checkov digests on arm64, which local runs cannot prove exist — Docker Desktop emulates amd64 transparently. Plan §D7."
  }
}

run "each_project_runs_its_own_buildspec_under_its_own_role" {
  # apply, because service_role is compared against a role ARN, which is
  # computed and therefore unknown under plan. Same reason as the three runs
  # in pipeline_iam.tftest.hcl, and the same mocked provider — nothing is
  # created and no credentials are needed.
  command = apply

  assert {
    condition = (
      one(aws_codebuild_project.infra_plan.source).buildspec == "pipelines/infra-plan.yml" &&
      one(aws_codebuild_project.infra_apply.source).buildspec == "pipelines/infra-apply.yml" &&
      one(aws_codebuild_project.infra_validate.source).buildspec == "pipelines/infra-validate.yml"
    )
    error_message = "a project pointing at the wrong buildspec plans when it should apply, and nothing about the pipeline shape reveals it"
  }

  assert {
    condition = (
      aws_codebuild_project.infra_plan.service_role == aws_iam_role.infra_plan.arn &&
      aws_codebuild_project.infra_apply.service_role == aws_iam_role.infra_apply.arn
    )
    error_message = "the service role is where a build's permissions come from (plan §F3); crossing these gives the plan build administrator"
  }
}

run "the_build_log_groups_have_retention" {
  command = plan

  assert {
    condition = alltrue([
      for g in [aws_cloudwatch_log_group.infra_validate, aws_cloudwatch_log_group.infra_plan, aws_cloudwatch_log_group.infra_apply] :
      g.retention_in_days == 30
    ])
    error_message = "CodeBuild creates its own group without retention if Terraform does not; logs then accumulate forever at a cost nobody attributes"
  }
}

run "the_stages_are_source_validate_then_the_four_layers_in_order" {
  command = plan

  assert {
    condition = [for s in aws_codepipeline.infra.stage : s.name] == [
      "Source", "Validate", "Foundation", "Network", "Staging", "Prod"
    ]
    error_message = "stage order is dependency order; staging reads network's outputs through remote state and prod must be last"
  }

  assert {
    condition     = aws_codepipeline.infra.pipeline_type == "V2"
    error_message = "variable, trigger and before_entry are all V2-only, and a V1 pipeline rejects them at apply rather than at plan"
  }

  assert {
    condition     = aws_codepipeline.infra.execution_mode == "QUEUED"
    error_message = "SUPERSEDED would cancel a run whose approval is open, or one mid-apply, when a second merge lands (plan §D11)"
  }
}

run "every_layer_stage_plans_then_approves_then_applies" {
  command = plan

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : (
        [for a in s.action : a.name] == ["Plan", "Approve", "Apply"] &&
        [for a in s.action : a.run_order] == [1, 2, 3]
      ) if contains(["Foundation", "Network", "Staging", "Prod"], s.name)
    ])
    error_message = "each layer stage is three ordered actions in one stage — the skip condition is stage-level, so splitting them could strand an approval (plan §D2)"
  }

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : (
        [for a in s.action : a.category if a.name == "Approve"] == ["Approval"]
      ) if contains(["Foundation", "Network", "Staging", "Prod"], s.name)
    ])
    error_message = "the middle action must be a manual approval; the roadmap's gate is a human, not a rule"
  }
}

run "apply_consumes_the_plan_action_output_and_never_replans" {
  command = plan

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : (
        [for a in s.action : a.output_artifacts if a.name == "Plan"] ==
        [for a in s.action : a.input_artifacts if a.name == "Apply"]
      ) if contains(["Foundation", "Network", "Staging", "Prod"], s.name)
    ])
    error_message = "the approval approves a plan file; if Apply does not consume Plan's artifact it computes a new one and the approval meant nothing (plan §D9)"
  }

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : (
        [for a in s.action : a.configuration["ProjectName"] if a.name == "Apply"] ==
        ["bgd-us-east-1-infra-apply-build"]
      ) if contains(["Foundation", "Network", "Staging", "Prod"], s.name)
    ])
    error_message = "an Apply action pointed at the plan project applies nothing and reports success"
  }
}

run "only_the_three_later_stages_are_scope_gated" {
  command = plan

  assert {
    condition = length([
      for s in aws_codepipeline.infra.stage : s if length(s.before_entry) > 0
    ]) == 3
    error_message = "network, staging and prod are conditional; foundation runs under every scope so a condition there could only evaluate true"
  }

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : alltrue([
        for c in s.before_entry[0].condition : c.result == "SKIP"
      ]) if length(s.before_entry) > 0
    ])
    error_message = "the result must be SKIP, not FAIL — an out-of-scope stage leaves the execution green, or Phase 9's change-failure-rate counts a deliberate stop as a failure"
  }

  assert {
    condition = [
      for s in aws_codepipeline.infra.stage :
      s.before_entry[0].condition[0].rule[0].configuration["Value"]
      if s.name == "Prod"
    ] == ["all"]
    error_message = "production runs under exactly one scope, and equality is the operator a VariableCheck certainly has (plan §F2)"
  }
}

run "the_trigger_filters_the_paths_the_pipeline_actually_owns" {
  command = plan

  assert {
    condition = toset(aws_codepipeline.infra.trigger[0].git_configuration[0].push[0].file_paths[0].includes) == toset([
      "infra/**",
      "pipelines/infra-*.yml",
      "scripts/pipeline-terraform.sh",
      "scripts/install-terraform.sh",
      "scripts/tf.sh",
      "scripts/lib/common.sh",
      "lambdas/**",
    ])
    error_message = "scripts/** as a whole would cross-trigger a four-approval infra run on every app change; infra/** alone would ignore edits to the pipeline's own logic (plan §D12). Narrowed from pipelines/** and scripts/pipeline-*.sh in Phase 8, because both matched that phase's files (Phase 8 §F4) — widening either back reintroduces the cross-trigger. lambdas/** joins in Phase 9, but the gap it closes is Phase 6's, not Phase 8's or Phase 9's: infra/environments/prod/hooks.tf has packaged lambdas/lifecycle_hook/handler.py since Phase 6, and a handler-only commit changed no watched file until now — this asserting the set exactly is what makes finding that a one-line fix (Phase 9 §D18)."
  }

  assert {
    condition     = aws_codepipeline.infra.stage[0].action[0].configuration["DetectChanges"] == "false"
    error_message = "DetectChanges creates a second, unfiltered webhook that fires on every push to the branch, and terraform plan stays clean forever (plan §D13)"
  }
}

run "deploy_scope_is_an_execution_variable_defaulting_to_all" {
  command = plan

  assert {
    condition     = aws_codepipeline.infra.variable[0].name == "DEPLOY_SCOPE"
    error_message = "the roadmap names this variable, and scripts/pipeline-terraform.sh reads it by that name"
  }

  assert {
    condition     = aws_codepipeline.infra.variable[0].default_value == "all"
    error_message = "a git-triggered run cannot set variables, so the default is the policy: every infra merge reaches production, gated by four approvals (plan §F4)"
  }
}

run "the_approval_shows_the_plan_it_is_approving" {
  command = plan

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : alltrue([
        for a in s.action :
        strcontains(a.configuration["CustomData"], ".PLAN_SUMMARY}")
        if a.name == "Approve"
      ]) if contains(["Foundation", "Network", "Staging", "Prod"], s.name)
    ])
    error_message = "an approval with no plan in the message is a reflex, not a decision — the roadmap asks for the plan output in the approval"
  }
}

run "the_buildspec_still_exports_what_the_approval_interpolates" {
  command = plan

  assert {
    condition = alltrue([
      for v in local.plan_exported_variables :
      strcontains(file("${path.module}/../../pipelines/infra-plan.yml"), v)
    ])
    error_message = "renaming an exported variable does not fail anything: the approval message shows the literal #{PlanProd.PLAN_SUMMARY} instead. This is the only thing that notices."
  }
}

run "pipeline_artifacts_expire_and_the_existing_rule_does_not_cover_them" {
  command = plan

  assert {
    condition = length([
      for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule :
      r if r.id == "expire-infra-pipeline-artifacts"
    ]) == 1
    error_message = "CodePipeline writes a source zip and four plan artifacts per execution as CURRENT versions; the Phase 3 rule expires only noncurrent ones and matches none of them"
  }

  assert {
    condition = [
      for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule :
      one(r.filter).prefix if r.id == "expire-infra-pipeline-artifacts"
    ] == ["bgd-us-east-1-infra-pipeline/"]
    error_message = "the rule must be scoped to the pipeline's own prefix — an unscoped expiration would delete the SBOMs and test reports the bucket exists to keep"
  }
}

run "the_outputs_phase_8_and_9_consume_are_present" {
  command = plan

  assert {
    condition     = output.infra_pipeline_name == "bgd-us-east-1-infra-pipeline"
    error_message = "Phase 9's EventBridge rule filters on the pipeline name and reads it from here rather than typing it again"
  }

  assert {
    condition     = toset(keys(output.image_tag_parameter_names)) == toset(["staging", "prod"])
    error_message = "Phase 8 writes these parameters after pushing an image and needs their names from the layer that owns them"
  }
}
