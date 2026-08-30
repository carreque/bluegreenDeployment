# The application pipeline's wiring: what runs, in what order, fed by which
# artifact, and started by which commit.
#
# The companion of tests/pipeline_shape.tftest.hcl, and it exists for the same
# reason: these are the assertions a plan review cannot make. Stage order is a
# list position, artifact hand-off is a string that has to match another string
# in a different block, an exported variable name lives in a YAML file nothing
# else reads, and the trigger's path filter is invisible until the wrong commit
# starts a run.
#
# The mocks below exist because of `command = apply`, and each was added
# because omitting it produced a hard error rather than because it looked tidy
# — the same rule tests/pipeline_shape.tftest.hcl follows.
#
#   aws_acm_certificate      domain_validation_options mocks to an empty set,
#                            and acm.tf's one([...]) over it then yields null
#                            for a required argument of the validation records.
#   aws_sns_topic            aws_sns_topic_subscription validates topic_arn
#                            client-side, and a random eight-character string
#                            is not an ARN.
#
# Every IAM role gets an ARN each through override_resource rather than one
# shared mock_resource default, for the reason prod's bluegreen.tftest.hcl
# gives: aws_codebuild_project validates service_role client-side, so the roles
# need real-looking ARNs — but one default for the type would give all of them
# the same ARN, and "the staging deploy project runs as the staging deploy
# role" would then hold even with the two deploy roles crossed. That crossing
# is exactly what D6's structural separation exists to prevent, so the test
# must be able to see it.
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

# One override per role, never one mock_resource default for the type:
# aws_codebuild_project validates service_role client-side, so the roles need
# real-looking ARNs — and one shared default would make "the staging deploy
# project runs as the staging deploy role" hold even with the two deploy roles
# crossed.
#
# The four Phase 7 roles are here too, although nothing in this file asserts on
# them. The whole module is applied, so their projects validate their
# service_role as well; without these overrides this file fails on resources it
# does not test.
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

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
  domain_name  = "carloscloudengineer.com"
}

# ---------------------------------------------------------------------------
# The scope table (D3) and the exported-variable names (D14 / Task 8).
# ---------------------------------------------------------------------------

run "the_scope_table_gates_the_two_deploy_stages_and_nothing_else" {
  command = plan

  assert {
    condition     = toset(keys(local.app_scope_conditions)) == toset(["staging", "prod"])
    error_message = "only the two deploy stages are scope-gated; Build runs under every scope, so a condition there could only ever evaluate true"
  }

  assert {
    condition     = local.app_scope_conditions["staging"].operator == "MATCHES"
    error_message = "staging runs under two of the three scopes, and a condition's rules are ANDed — there is no arrangement of EQ and NE that expresses 'two of three' (D3)"
  }

  assert {
    condition     = local.app_scope_conditions["staging"].value == "^(staging|all)$"
    error_message = "the regex is the scope table: staging deploys under APP_SCOPE=staging and APP_SCOPE=all, and under nothing else"
  }

  assert {
    condition = (
      local.app_scope_conditions["prod"].operator == "EQ" &&
      local.app_scope_conditions["prod"].value == "all"
    )
    error_message = "production runs under exactly one scope, and equality is the operator a VariableCheck certainly has (Phase 7 §F2)"
  }
}

run "the_exported_variable_names_are_declared_once" {
  command = plan

  assert {
    condition     = local.app_build_exported_variables == ["IMAGE_TAG", "IMAGE_DIGEST"]
    error_message = "every stage after Build interpolates #{Build.IMAGE_TAG}; renaming the export makes the deploy receive that literal string as a tag"
  }

  assert {
    condition     = local.app_plan_exported_variables == ["PLAN_STATUS", "PLAN_SUMMARY", "PLAN_URL"]
    error_message = "the production approval interpolates #{PlanProd.PLAN_SUMMARY} and #{PlanProd.PLAN_URL}; a renamed export shows the literal placeholder and fails nothing"
  }
}

run "app_scope_defaults_to_all_because_a_git_run_supplies_no_variables" {
  command = plan

  assert {
    condition     = var.app_scope_default == "all"
    error_message = "a run started by the git trigger cannot set execution variables, so every app/** merge takes this default — the approval, not this value, is what stands between a merge and production (D3)"
  }
}

# ---------------------------------------------------------------------------
# The five projects (D5, D7) and their log groups.
# ---------------------------------------------------------------------------

run "only_the_image_build_is_arm_and_only_the_image_build_is_privileged" {
  command = plan

  assert {
    condition     = one(aws_codebuild_project.app_image.environment).type == "ARM_CONTAINER"
    error_message = "the image is linux/arm64 only. An x86 build would emulate — measuring the emulator as much as the Dockerfile — and produce an amd64 manifest that pushes cleanly and fails minutes later at task start with an exec format error (Phase 2's amendment). This assertion is worth its line."
  }

  assert {
    condition = alltrue([
      for p in [
        aws_codebuild_project.app_deploy_staging,
        aws_codebuild_project.app_smoke,
        aws_codebuild_project.app_plan_prod,
        aws_codebuild_project.app_deploy_prod,
      ] : one(p.environment).type == "LINUX_CONTAINER"
    ])
    error_message = "the other four run Terraform, curl and jq — architecture-agnostic — and scripts/install-terraform.sh pins a linux_amd64 checksum. D7: what decides the compute type is the architecture of the artifacts a build handles."
  }

  assert {
    condition     = one(aws_codebuild_project.app_image.environment).privileged_mode
    error_message = "privileged twice over: docker buildx with the docker-container driver, which Phase 2 §F1 proved is the only driver honouring rewrite-timestamp, and the two containers D10 runs the tests in"
  }

  assert {
    # coalesce, because privileged_mode is optional with no schema default:
    # leaving it out leaves the attribute null rather than false, and `!null`
    # is an error rather than a passing assertion.
    condition = alltrue([
      for p in [
        aws_codebuild_project.app_deploy_staging,
        aws_codebuild_project.app_smoke,
        aws_codebuild_project.app_plan_prod,
        aws_codebuild_project.app_deploy_prod,
      ] : !coalesce(one(p.environment).privileged_mode, false)
    ])
    error_message = "the other four run no containers; privileged mode there is reach nobody asked for, on two roles that already hold AdministratorAccess"
  }
}

run "the_production_apply_may_block_through_a_bake" {
  command = plan

  assert {
    condition     = aws_codebuild_project.app_deploy_prod.build_timeout == 60
    error_message = "prod's service sets wait_for_steady_state, so the apply does not return until green is provisioned, tested by three hooks, promoted and baked for five minutes under the alarms. This timeout must not be the thing that decides the deployment went badly (Phase 6 §D11)."
  }

  assert {
    condition     = aws_codebuild_project.app_smoke.build_timeout == 20
    error_message = "smoke is three HTTP probes; twenty minutes is already generous and a longer one hides a hung stage"
  }
}

run "each_project_runs_its_own_buildspec_under_its_own_role" {
  # apply, because service_role is compared against a role ARN, which is
  # computed and therefore unknown under plan.
  command = apply

  assert {
    condition = (
      one(aws_codebuild_project.app_image.source).buildspec == "pipelines/app-build.yml" &&
      one(aws_codebuild_project.app_deploy_staging.source).buildspec == "pipelines/app-deploy.yml" &&
      one(aws_codebuild_project.app_smoke.source).buildspec == "pipelines/app-smoke.yml" &&
      one(aws_codebuild_project.app_plan_prod.source).buildspec == "pipelines/app-plan.yml" &&
      one(aws_codebuild_project.app_deploy_prod.source).buildspec == "pipelines/app-apply.yml"
    )
    error_message = "a project pointing at the wrong buildspec plans when it should apply, or smokes when it should deploy, and nothing about the pipeline shape reveals it"
  }

  assert {
    condition = (
      aws_codebuild_project.app_deploy_staging.service_role == aws_iam_role.app_deploy_staging.arn &&
      aws_codebuild_project.app_deploy_prod.service_role == aws_iam_role.app_deploy_prod.arn
    )
    error_message = "the service role is where a build's permissions come from (Phase 7 §F3), and these two are the structural separation D6 buys: crossing them puts the staging deploy inside production's principal"
  }

  assert {
    condition = (
      aws_codebuild_project.app_smoke.service_role == aws_iam_role.app_smoke.arn &&
      aws_codebuild_project.app_plan_prod.service_role == aws_iam_role.app_plan_prod.arn &&
      aws_codebuild_project.app_image.service_role == aws_iam_role.app_image.arn
    )
    error_message = "crossing any of these gives a build reach its buildspec was never reviewed for — the smoke build in particular is asserted to hold no credentials, and that assertion is about this role"
  }
}

run "every_app_build_writes_to_its_own_log_group_with_retention" {
  command = apply

  assert {
    condition = alltrue([
      for g in [
        aws_cloudwatch_log_group.app_image,
        aws_cloudwatch_log_group.app_deploy_staging,
        aws_cloudwatch_log_group.app_smoke,
        aws_cloudwatch_log_group.app_plan_prod,
        aws_cloudwatch_log_group.app_deploy_prod,
      ] : g.retention_in_days == 30
    ])
    error_message = "CodeBuild creates its own group without retention if Terraform does not — and the checkov skip explaining thirty days would then apply to nothing"
  }

  assert {
    condition = (
      one(one(aws_codebuild_project.app_image.logs_config).cloudwatch_logs).group_name == aws_cloudwatch_log_group.app_image.name &&
      one(one(aws_codebuild_project.app_deploy_staging.logs_config).cloudwatch_logs).group_name == aws_cloudwatch_log_group.app_deploy_staging.name &&
      one(one(aws_codebuild_project.app_smoke.logs_config).cloudwatch_logs).group_name == aws_cloudwatch_log_group.app_smoke.name &&
      one(one(aws_codebuild_project.app_plan_prod.logs_config).cloudwatch_logs).group_name == aws_cloudwatch_log_group.app_plan_prod.name &&
      one(one(aws_codebuild_project.app_deploy_prod.logs_config).cloudwatch_logs).group_name == aws_cloudwatch_log_group.app_deploy_prod.name
    )
    error_message = "each project writes to the group its own role can write to; a shared or crossed group means a build fails on logs rather than on its work, and the role's OwnLogGroup grant names the wrong ARN"
  }
}

# ---------------------------------------------------------------------------
# The buildspecs still export the names the pipeline interpolates.
#
# This is the only thing that catches a rename offline. A renamed export fails
# nothing at apply: the approval shows a literal `#{PlanProd.PLAN_SUMMARY}`,
# the deploy receives the literal `#{Build.IMAGE_TAG}` and tries to resolve it
# as an ECR tag, and the smoke action curls an empty URL. All three are runtime
# failures on a pipeline that planned clean.
#
# yamldecode rather than strcontains, unlike Phase 7's equivalent: the point is
# that the list under env.exported-variables IS the list in locals.tf, not that
# the three strings appear somewhere in the file. A name left behind in a
# comment would satisfy strcontains.
# ---------------------------------------------------------------------------

run "the_buildspecs_export_exactly_what_the_pipeline_interpolates" {
  command = plan

  assert {
    condition     = yamldecode(file("${path.module}/../../pipelines/app-build.yml")).env["exported-variables"] == local.app_build_exported_variables
    error_message = "pipelines/app-build.yml must export IMAGE_TAG and IMAGE_DIGEST — every stage after Build interpolates them, and a rename makes the deploy try to resolve the literal placeholder as an ECR tag"
  }

  assert {
    condition     = yamldecode(file("${path.module}/../../pipelines/app-deploy.yml")).env["exported-variables"] == local.app_deploy_exported_variables
    error_message = "pipelines/app-deploy.yml must export SMOKE_URL and SMOKE_DIGEST — they are how the smoke action learns what to check without holding any AWS credentials (D6)"
  }

  assert {
    condition     = yamldecode(file("${path.module}/../../pipelines/app-plan.yml")).env["exported-variables"] == local.app_plan_exported_variables
    error_message = "pipelines/app-plan.yml must export the three PLAN_ variables — the approval beside it shows PLAN_SUMMARY and links PLAN_URL, and a rename makes it show the placeholder instead"
  }
}

run "the_two_buildspecs_that_need_no_terraform_do_not_install_it" {
  command = plan

  assert {
    condition = alltrue([
      for f in ["app-build.yml", "app-smoke.yml"] :
      !can(yamldecode(file("${path.module}/../../pipelines/${f}")).phases.install)
    ])
    error_message = "the build runs its tools from digest-pinned containers and the smoke build runs curl and jq; installing Terraform in either is two minutes per run for a binary neither calls"
  }

  assert {
    condition = alltrue([
      for f in ["app-deploy.yml", "app-plan.yml", "app-apply.yml"] :
      contains(yamldecode(file("${path.module}/../../pipelines/${f}")).phases.install.commands, "./scripts/install-terraform.sh")
    ])
    error_message = "the three Terraform-driving buildspecs must install the pinned version; the CodeBuild image's own terraform, if any, is not the version .terraform-version names"
  }
}

run "only_the_production_plan_publishes_a_workspace" {
  command = plan

  assert {
    condition     = contains(yamldecode(file("${path.module}/../../pipelines/app-plan.yml")).artifacts.files, "**/*")
    error_message = "Apply consumes this artifact to get the saved plan; without it the approval approves a plan file that no later action can see"
  }

  assert {
    condition     = contains(yamldecode(file("${path.module}/../../pipelines/app-plan.yml")).artifacts["exclude-paths"], "**/.terraform/**")
    error_message = "roughly 700 MB of provider binaries, re-downloadable from the committed .terraform.lock.hcl in less time than uploading and downloading them costs"
  }
}

# ---------------------------------------------------------------------------
# The pipeline: five stages, the hand-offs between them, and the trigger.
# ---------------------------------------------------------------------------

run "the_stages_are_source_build_staging_then_prod" {
  command = plan

  assert {
    condition = [for s in aws_codepipeline.app.stage : s.name] == [
      "Source", "Build", "DeployStaging", "Prod"
    ]
    error_message = "stage order is the dependency order: an image must exist before it can be deployed, and must have passed staging smoke before production is offered it"
  }

  assert {
    condition     = aws_codepipeline.app.pipeline_type == "V2"
    error_message = "variable, trigger and before_entry are all V2-only, and a V1 pipeline rejects them at apply rather than at plan"
  }

  assert {
    condition     = aws_codepipeline.app.execution_mode == "QUEUED"
    error_message = "SUPERSEDED would cancel a run mid-bake when a second app/** merge lands, leaving production half-shifted with nothing watching. PARALLEL is worse: two applies of the prod layer contend on one state lock. Plan §D15."
  }
}

run "the_source_action_hands_the_build_a_clone_not_a_zip" {
  command = plan

  assert {
    condition = [
      for a in aws_codepipeline.app.stage[0].action : a.configuration["OutputArtifactFormat"]
    ] == ["CODEBUILD_CLONE_REF"]
    error_message = "image_build_identity derives the tag, SOURCE_DATE_EPOCH and BUILT_AT from git rev-parse, git status and git log. A CODE_ZIP workspace has no .git, so all three fail — and the bad case is someone 'fixing' it with a clock fallback, which compiles and silently ends the reproducibility Phase 2 measured. Plan §F2 and §D8."
  }

  assert {
    condition = [
      for a in aws_codepipeline.app.stage[0].action : a.configuration["DetectChanges"]
    ] == ["false"]
    error_message = "true creates a second, unfiltered webhook that fires on every push to the branch — so an infra/**-only commit would run this pipeline while the trigger block sat beside it looking as though it were working (Phase 7 §D13)"
  }
}

run "the_deploy_staging_stage_deploys_then_smokes_in_that_order" {
  command = plan

  assert {
    condition = [
      for s in aws_codepipeline.app.stage : [for a in s.action : a.name] if s.name == "DeployStaging"
    ] == [["Deploy", "Smoke"]]
    error_message = "smoke is a separate action at run_order 2, not a step inside the deploy buildspec: folding it in makes 'the apply failed' and 'the deployment succeeded but the service is wrong' indistinguishable in the pipeline view, and loses D6's property that the thing checking behaviour holds no credentials"
  }

  assert {
    condition = [
      for s in aws_codepipeline.app.stage : [for a in s.action : a.run_order] if s.name == "DeployStaging"
    ] == [[1, 2]]
    error_message = "equal run_orders make the two actions parallel, and the smoke would probe the previous image while the deployment it is meant to check is still going out"
  }
}

run "the_prod_stage_plans_then_approves_then_applies" {
  command = plan

  assert {
    condition = [
      for s in aws_codepipeline.app.stage : [for a in s.action : a.name] if s.name == "Prod"
    ] == [["Plan", "Approve", "Apply"]]
    error_message = "production is Phase 7's stage shape: the approval approves a specific change — this digest, this task definition revision — rather than a description of one"
  }

  assert {
    condition = [
      for s in aws_codepipeline.app.stage : [for a in s.action : a.category if a.name == "Approve"] if s.name == "Prod"
    ] == [["Approval"]]
    error_message = "the middle action must be a manual approval; the compensating control between an app/** merge and production is a human, not a rule"
  }

  assert {
    condition = [
      for s in aws_codepipeline.app.stage :
      [for a in s.action : a.output_artifacts if a.name == "Plan"] ==
      [for a in s.action : a.input_artifacts if a.name == "Apply"]
      if s.name == "Prod"
    ] == [true]
    error_message = "the approval approves a plan FILE; if Apply does not consume Plan's artifact it computes a new one and the approval meant nothing. No error at any point (Phase 7 §D9)."
  }

  assert {
    condition = [
      for s in aws_codepipeline.app.stage :
      strcontains([for a in s.action : a.configuration["CustomData"] if a.name == "Approve"][0], "#{PlanProd.PLAN_SUMMARY}")
      if s.name == "Prod"
    ] == [true]
    error_message = "an approval with no plan in the message is a reflex, not a decision — and the namespace has to be PlanProd, because that is what the Plan action declares and what the buildspec's exports land under"
  }
}

run "the_build_action_is_namespaced_so_its_tag_can_be_interpolated" {
  command = plan

  assert {
    condition = [
      for s in aws_codepipeline.app.stage : [for a in s.action : a.namespace] if s.name == "Build"
    ] == [["Build"]]
    error_message = "namespace does not default. Without it #{Build.IMAGE_TAG} resolves to nothing and every later stage deploys an empty tag."
  }

  assert {
    condition = alltrue([
      for s in aws_codepipeline.app.stage : alltrue([
        for a in s.action :
        strcontains(a.configuration["EnvironmentVariables"], "#{Build.IMAGE_TAG}")
        if contains(["Deploy", "Plan", "Apply"], a.name)
      ]) if contains(["DeployStaging", "Prod"], s.name)
    ])
    error_message = "every action that deploys or plans must receive the tag the Build stage produced — never one read from SSM, which records what IS deployed rather than telling a run what to deploy (D9's corollary)"
  }
}

run "both_deploy_stages_are_scope_gated_and_skip_rather_than_fail" {
  command = plan

  assert {
    condition = length([
      for s in aws_codepipeline.app.stage : s if length(s.before_entry) > 0
    ]) == 2
    error_message = "DeployStaging and Prod are conditional; Source and Build run under every scope, so a condition there could only evaluate true"
  }

  assert {
    condition = alltrue([
      for s in aws_codepipeline.app.stage : alltrue([
        for c in s.before_entry[0].condition : c.result == "SKIP"
      ]) if length(s.before_entry) > 0
    ])
    error_message = "SKIP, not FAIL — an out-of-scope stage must leave the execution green, or Phase 9's change-failure-rate counts a deliberate stop as a failure, which is the roadmap's stated reason for not using a declined approval as the mechanism"
  }

  assert {
    condition = [
      for s in aws_codepipeline.app.stage :
      s.before_entry[0].condition[0].rule[0].configuration["Value"]
      if s.name == "Prod"
    ] == ["all"]
    error_message = "production runs under exactly one scope, and equality is the operator a VariableCheck certainly has (Phase 7 §F2)"
  }

  assert {
    condition = [
      for s in aws_codepipeline.app.stage :
      s.before_entry[0].condition[0].rule[0].configuration["Value"]
      if s.name == "DeployStaging"
    ] == ["^(staging|all)$"]
    error_message = "the condition must come from local.app_scope_conditions, so the scope table stays in one place even though the two stages do not share a body"
  }
}

run "app_scope_is_an_execution_variable_defaulting_to_all" {
  command = plan

  assert {
    condition     = aws_codepipeline.app.variable[0].name == "APP_SCOPE"
    error_message = "scripts/pipeline-deploy.sh reads this variable by that name, and the before_entry conditions interpolate #{variables.APP_SCOPE}"
  }

  assert {
    condition     = aws_codepipeline.app.variable[0].default_value == "all"
    error_message = "a git-triggered run cannot set variables, so the default is the policy: every app merge reaches production, gated by one approval (D3)"
  }
}

run "the_trigger_watches_app_and_this_pipelines_own_executable_content" {
  command = plan

  # The union of BOTH push filters. file_paths.includes caps at eight patterns
  # and this list has eleven, so it is split across two filters that the
  # service ORs together (F11). Asserting the union rather than either half is
  # what makes the split invisible to this test and a re-split harmless.
  assert {
    condition = toset(flatten([
      for pu in aws_codepipeline.app.trigger[0].git_configuration[0].push : pu.file_paths[0].includes
      ])) == toset([
      "app/**",
      "pipelines/app-*.yml",
      "scripts/build-image.sh",
      "scripts/generate-sbom.sh",
      "scripts/push-image.sh",
      "scripts/pipeline-app-build.sh",
      "scripts/pipeline-deploy.sh",
      "scripts/smoke.sh",
      "scripts/install-terraform.sh",
      "scripts/tf.sh",
      "scripts/lib/common.sh",
    ])
    error_message = "app/** alone would ignore edits to the pipeline's own logic — a change to build-image.sh or to smoke.sh changes what every run does. scripts/** as a whole would cross-trigger on Phase 7's scripts. D14."
  }

  assert {
    condition = alltrue([
      for pu in aws_codepipeline.app.trigger[0].git_configuration[0].push :
      toset(pu.branches[0].includes) == toset([var.github_branch])
    ])
    error_message = "EVERY push filter needs its own branch filter — branches and file_paths are ANDed within a filter, and a filter that omits branches matches every branch, so this pipeline would deploy a feature branch's commit to production"
  }

  assert {
    condition = length([
      for pu in aws_codepipeline.app.trigger[0].git_configuration[0].push :
      pu if length(pu.file_paths[0].includes) > 8
    ]) == 0
    error_message = "eight patterns is the service maximum per filter (F11). Adding a ninth fails at plan with 'Too many list items' — which is loud, and this assertion is what names the fix: a third push filter, of which the trigger allows three."
  }
}

run "the_infra_trigger_narrowed_when_the_app_buildspecs_arrived" {
  command = plan

  assert {
    condition = !contains(
      aws_codepipeline.infra.trigger[0].git_configuration[0].push[0].file_paths[0].includes,
      "pipelines/**"
    )
    error_message = "pipelines/** matches pipelines/app-build.yml, so every application buildspec edit would fire a four-approval infrastructure deployment alongside the application deployment it was meant to start (F4). This assertion is the durable form of that fix — it fails if someone widens it back."
  }

  assert {
    condition = !contains(
      aws_codepipeline.infra.trigger[0].git_configuration[0].push[0].file_paths[0].includes,
      "scripts/pipeline-*.sh"
    )
    error_message = "scripts/pipeline-*.sh matches pipeline-app-build.sh and pipeline-deploy.sh, both of which belong to the application pipeline (F4)"
  }

  assert {
    condition = toset(aws_codepipeline.infra.trigger[0].git_configuration[0].push[0].file_paths[0].includes) == toset([
      "infra/**",
      "pipelines/infra-*.yml",
      "scripts/pipeline-terraform.sh",
      "scripts/install-terraform.sh",
      "scripts/tf.sh",
      "scripts/lib/common.sh",
    ])
    error_message = "tf.sh and lib/common.sh join the list here rather than as a consequence of this phase: every plan and every apply in that pipeline runs both, so by Phase 7's own D12 argument they are its executable content and always were (F4)"
  }
}

run "the_two_pipelines_share_a_connection_a_bucket_and_nothing_else" {
  command = apply

  assert {
    condition     = aws_codepipeline.app.role_arn != aws_codepipeline.infra.role_arn
    error_message = "one role for both pipelines would let either start the other's builds; each role's StartBuild names only its own five or three projects"
  }

  assert {
    condition     = aws_codepipeline.app.name == "bgd-us-east-1-app-pipeline"
    error_message = "the name is the artifact-store prefix and the filter Phase 9's EventBridge rule matches on; the lifecycle rule in artifacts.tf is scoped to it"
  }
}

# ---------------------------------------------------------------------------
# The artifact bucket's two prefixes, and their two fates (D16).
# ---------------------------------------------------------------------------

run "app_pipeline_artifacts_expire_and_the_build_outputs_do_not" {
  command = plan

  assert {
    condition = length([
      for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule :
      r if r.id == "expire-app-pipeline-artifacts"
    ]) == 1
    error_message = "CodePipeline writes a clone reference and one saved plan per execution as CURRENT versions; the Phase 3 rule expires only noncurrent ones and matches none of them, so the store would grow forever"
  }

  assert {
    condition = [
      for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule :
      one(r.filter).prefix if r.id == "expire-app-pipeline-artifacts"
    ] == ["bgd-us-east-1-app-pipeline/"]
    error_message = "the rule must be scoped to this pipeline's own prefix - an unscoped expiration would delete the SBOMs and test reports the bucket exists to keep"
  }

  assert {
    # Reads EVERY rule that expires current versions, not only the two named
    # above, so a fourth rule added later with a wider prefix fails here. This
    # is the assertion that stops a tidying-up from deleting the history
    # design 4.2 asked for.
    condition = alltrue([
      for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule :
      (
        coalesce(one(r.filter).prefix, "") != "" &&
        !startswith("${var.app_artifact_prefix}/", one(r.filter).prefix)
      )
      if length(r.expiration) > 0
    ])
    error_message = "no expiry rule may cover app-builds/. Design 4.2 wants an SBOM for the image running in production three deployments ago, and an expiry there deletes exactly that - silently, thirty days after each deployment."
  }
}

run "the_outputs_phase_9_and_the_runbook_consume_are_present" {
  command = apply

  assert {
    condition     = output.app_pipeline_name == "bgd-us-east-1-app-pipeline"
    error_message = "Phase 9's EventBridge rule filters on the pipeline name and reads it from here rather than typing it again"
  }

  assert {
    condition     = output.app_deploy_staging_role_arn != output.app_deploy_prod_role_arn
    error_message = "two ARNs, because they are two roles - the structural separation D6 buys, visible from outside the layer"
  }
}
