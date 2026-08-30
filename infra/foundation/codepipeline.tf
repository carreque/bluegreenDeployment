# The infrastructure pipeline.
#
# Source → Validate → Foundation → Network → Staging → Prod, where each of the
# last four is one stage holding Plan, a manual approval, and Apply. Six stages
# rather than fourteen, because before_entry is a stage-level condition: one
# condition skips a layer's plan, its approval and its apply together, and
# three stages per layer would need three conditions each with four times as
# many ways to disagree with themselves. Plan §D2.
#
# This pipeline lives in the layer it deploys. That is intentional (roadmap §1)
# and it has one consequence worth stating here rather than only in the
# runbook: a change that breaks the pipeline definition cannot be repaired by
# the pipeline, and must be fixed with a local `make apply-foundation`.

resource "aws_codepipeline" "infra" {
  # checkov:skip=CKV_AWS_219:SSE-S3 on the artifact bucket rather than a customer-managed key, the same decision the Phase 3 plan §D4 took for every encrypted-at-rest resource in this project and applied to the bucket this pipeline stores into. The artifacts are a source zip of a public repository and four Terraform plans of infrastructure whose configuration is in that repository; a CMK would add a monthly charge and a key policy for content reproducible from the commit.
  name          = "${local.name_prefix}-infra-pipeline"
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V2"

  # QUEUED, not the SUPERSEDED default. SUPERSEDED cancels the older execution
  # when a newer one starts, and this pipeline's executions sit waiting on
  # human approvals and then run applies that take minutes — so a second merge
  # would cancel the run whose plan someone is part-way through reading, and
  # could cancel one mid-apply. PARALLEL is worse still: two applies of the
  # same layer contend on the same state lock. Plan §D11.
  execution_mode = "QUEUED"

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  # A run started by the git trigger supplies no variables, so every merge takes
  # this default (plan §F4). `all` is the policy: an infra change is normally a
  # change you want in production, and the four approvals — not this default —
  # are what stand between the merge and prod.
  variable {
    name          = "DEPLOY_SCOPE"
    default_value = var.deploy_scope_default
    description   = "How far this run goes: foundation | network | staging | all. Cumulative — staging also applies foundation and network; all reaches production."
  }

  trigger {
    provider_type = "CodeStarSourceConnection"

    git_configuration {
      source_action_name = "Source"

      push {
        branches {
          includes = [var.github_branch]
        }

        # The roadmap says infra/**. The rest is the pipeline's own executable
        # content: a change to a buildspec or to pipeline-terraform.sh changes
        # what every stage does, and it would be odd for that to reach
        # production only when someone next edits a .tf file.
        #
        # scripts/** as a whole is deliberately excluded — it also holds
        # build-image.sh, smoke.sh and generate-sbom.sh, which belong to the
        # application pipeline, and watching the directory would run a
        # four-approval infra deployment on an application change. Plan §D12.
        #
        # NARROWED IN PHASE 8, and this is not cosmetic. As originally written
        # this list held `pipelines/**` and `scripts/pipeline-*.sh`, and both
        # match files Phase 8 creates: pipelines/app-build.yml, and both
        # pipeline-app-build.sh and pipeline-deploy.sh. Left alone, every
        # application-buildspec edit would have started a four-approval
        # infrastructure deployment alongside the application deployment it was
        # meant to start. The naming was chosen to make this a two-line fix.
        # Phase 8 §F4.
        #
        # scripts/tf.sh and scripts/lib/common.sh join the list at the same
        # time, and that is a pre-existing gap rather than a consequence of
        # Phase 8: every plan and every apply here runs both, so by the D12
        # argument above they are this pipeline's executable content and always
        # were. Nobody noticed because neither had changed since Phase 3.
        # Recorded as a Phase 7 amendment.
        file_paths {
          includes = [
            "infra/**",
            "pipelines/infra-*.yml",
            "scripts/pipeline-terraform.sh",
            "scripts/install-terraform.sh",
            "scripts/tf.sh",
            "scripts/lib/common.sh",

            # lambdas/** joins in Phase 9, and — like scripts/tf.sh in Phase 8 —
            # this is a PRE-EXISTING gap rather than a consequence of the phase
            # that found it. infra/environments/prod/hooks.tf has packaged
            # lambdas/lifecycle_hook/handler.py since Phase 6, and Phase 9's
            # collector is packaged from the same directory. A commit that only
            # fixes a handler changes no watched file, so this pipeline does not
            # run and the fix never reaches the function that gates production.
            # No error, no failed run: nothing happens at all. Phase 9 §D18, §F6.
            #
            # Seven of the eight patterns filePaths.includes accepts (§F7), so
            # this still needs no second push block — unlike the application
            # pipeline's eleven.
            "lambdas/**",
          ]
        }
      }
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source"]

      configuration = {
        ConnectionArn        = aws_codeconnections_connection.github.arn
        FullRepositoryId     = var.github_repository_id
        BranchName           = var.github_branch
        OutputArtifactFormat = "CODE_ZIP"

        # False, deliberately. True creates a second webhook that fires on
        # every push to the branch with no path filter, which would run this
        # pipeline on an app-only commit while the trigger block above sat
        # beside it looking as though it were working. In a V2 pipeline the
        # trigger owns change detection. Plan §D13.
        DetectChanges = "false"
      }
    }
  }

  # No AWS credentials are used here and the project's role grants none: tf.sh
  # initialises validate and test with -backend=false, and tflint and checkov
  # read files. Plan §D6.
  stage {
    name = "Validate"

    action {
      name            = "Validate"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source"]

      configuration = {
        ProjectName = aws_codebuild_project.infra_validate.name
      }
    }
  }

  dynamic "stage" {
    for_each = local.pipeline_layers

    content {
      name = stage.value.title

      # foundation has no condition — every scope includes it. The other three
      # skip rather than fail, so a deliberately narrow run finishes green;
      # a FAIL result would make Phase 9's change-failure-rate count an
      # intentional stop as a failure, which is the roadmap's stated reason for
      # not using a declined approval as the mechanism.
      dynamic "before_entry" {
        for_each = stage.value.scope_operator == null ? [] : [stage.value]

        content {
          condition {
            result = "SKIP"

            rule {
              name = "in-scope"

              rule_type_id {
                category = "Rule"
                owner    = "AWS"
                provider = "VariableCheck"
                version  = "1"
              }

              # configuration is an untyped map(string): the provider validates
              # nothing here and the service validates it at execution time, so
              # whether MATCHES is accepted cannot be confirmed offline. That is
              # why scripts/pipeline-terraform.sh checks the scope again — see
              # plan §F2 for the fallback if it is not.
              configuration = {
                Variable = "#{variables.DEPLOY_SCOPE}"
                Operator = before_entry.value.scope_operator
                Value    = before_entry.value.scope_value
              }
            }
          }
        }
      }

      action {
        name             = "Plan"
        category         = "Build"
        owner            = "AWS"
        provider         = "CodeBuild"
        version          = "1"
        run_order        = 1
        namespace        = "Plan${stage.value.title}"
        input_artifacts  = ["source"]
        output_artifacts = ["plan_${stage.value.name}"]

        configuration = {
          ProjectName = aws_codebuild_project.infra_plan.name

          # LAYER is what makes one project serve four layers; DEPLOY_SCOPE is
          # the second gate. Both are per-action overrides because neither is a
          # property of the shared project.
          EnvironmentVariables = jsonencode([
            { name = "LAYER", value = stage.value.name, type = "PLAINTEXT" },
            { name = "DEPLOY_SCOPE", value = "#{variables.DEPLOY_SCOPE}", type = "PLAINTEXT" },
          ])
        }
      }

      action {
        name      = "Approve"
        category  = "Approval"
        owner     = "AWS"
        provider  = "Manual"
        version   = "1"
        run_order = 2

        configuration = {
          # The plan summary the Plan action exported, so approving is an
          # informed decision rather than a reflex. Capped at 1000 characters
          # by CodePipeline, which is why the script truncates at 900 and
          # offers the full plan behind the link.
          CustomData         = "#{Plan${stage.value.title}.PLAN_SUMMARY}"
          ExternalEntityLink = "#{Plan${stage.value.title}.PLAN_URL}"
        }
      }

      action {
        name            = "Apply"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        run_order       = 3
        input_artifacts = ["plan_${stage.value.name}"]

        configuration = {
          ProjectName = aws_codebuild_project.infra_apply.name

          EnvironmentVariables = jsonencode([
            { name = "LAYER", value = stage.value.name, type = "PLAINTEXT" },
            { name = "DEPLOY_SCOPE", value = "#{variables.DEPLOY_SCOPE}", type = "PLAINTEXT" },
          ])
        }
      }
    }
  }
}
