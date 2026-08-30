# The application pipeline.
#
# Source → Build → DeployStaging → Prod. A commit under app/ becomes a
# production blue/green deployment, with Phase 6's dark canary hook and bake
# alarms standing between it and the users — and, operationally, this is the
# sentence worth reading twice: **an app/** merge now reaches production behind
# ONE approval**, not the four the infra pipeline asks for. That is intended,
# it is the whole point of the phase, and the compensating controls are Phase
# 6's rather than more approvals.
#
# ---------------------------------------------------------------------------
# The deploy actions run Terraform, not the standard ECS deploy action
# ---------------------------------------------------------------------------
#
# The roadmap's task list says "deploy to staging via the standard ECS deploy
# action", and that action cannot deploy this application. It replaces
# container image URIs only, copying the container environment from the current
# revision — and both task definitions carry BGD_IMAGE_DIGEST there, so every
# deployment would produce a revision whose image and whose self-reported
# digest disagree. /version would be wrong in production and smoke.sh's fourth
# assertion would fail on every deploy.
#
# So these actions run `terraform apply -var image_tag=...` and let
# data.aws_ecr_image resolve the tag to a digest once, feeding both the image
# field and BGD_IMAGE_DIGEST from the same expression. Plan §D2 and §F1;
# design §1.5 and §6 are amended to say so.
#
# What design §1.5 cares about is preserved by mechanism: only images flow
# through this pipeline. The environment layers' Terraform is whatever is on
# main, and the single input supplied here is a tag — an app/** merge cannot
# change the service shape, because an app/** merge does not change infra/.
#
# ---------------------------------------------------------------------------
# Why these stages are written out and codepipeline.tf's are generated
# ---------------------------------------------------------------------------
#
# codepipeline.tf iterates local.pipeline_layers because its four stages are
# structurally identical — Plan, Approve, Apply, differing only in a name.
# These are not. DeployStaging holds Deploy and Smoke; Prod holds Plan, Approve
# and Apply. A dynamic block over two shapes would need a conditional inside it
# for every action, which is a worse way to say "these two stages are
# different" than writing two different stages.
#
# What the two stages DO share is the scope table, and they take it from
# local.app_scope_conditions by lookup rather than each carrying its own
# operator and value.
#
# This pipeline lives in the layer it deploys from, like the infra one, and has
# the same consequence: a change that breaks this definition cannot be repaired
# by this pipeline. It is fixed with a local `make apply-foundation`.

resource "aws_codepipeline" "app" {
  # checkov:skip=CKV_AWS_219:SSE-S3 on the artifact bucket rather than a customer-managed key, the same decision the Phase 3 plan §D4 took for every encrypted-at-rest resource in this project. This pipeline's artifacts are a git clone reference and one saved Terraform plan per execution; a CMK would add a monthly charge and a key policy for content reproducible from the commit.
  name          = "${local.name_prefix}-app-pipeline"
  role_arn      = aws_iam_role.app_pipeline.arn
  pipeline_type = "V2"

  # QUEUED, and it matters more here than in the infra pipeline. This
  # pipeline's executions wait on a human approval and then run an apply that
  # blocks through a five-minute bake. SUPERSEDED — the V2 default — would
  # cancel a run mid-bake when a second app/** merge lands, leaving production
  # in a half-shifted state that nothing is watching. PARALLEL is worse: two
  # applies of the prod layer contend on one state lock. Plan §D15.
  execution_mode = "QUEUED"

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  # A run started by the git trigger supplies no variables, so every app/**
  # merge takes this default. `all` is the policy: an application change is
  # normally a change you want in production, and the approval in the Prod
  # stage — not this default — is what stands between the merge and prod.
  #
  # Cumulative, and it names where a run STOPS. `build` exists beyond symmetry:
  # Phase 11 needs to push a deliberately broken image to ECR *without*
  # deploying it, so the demonstration can be started by hand at the moment the
  # screenshots are being taken. Plan §D3.
  variable {
    name          = "APP_SCOPE"
    default_value = var.app_scope_default
    description   = "How far this run goes: build | staging | all. Cumulative — staging also builds and pushes; all reaches production."
  }

  trigger {
    provider_type = "CodeStarSourceConnection"

    git_configuration {
      source_action_name = "Source"

      # TWO push blocks, not one, and the reason is a hard cap rather than a
      # design choice: file_paths.includes accepts a maximum of EIGHT patterns
      # and D14's list has eleven (plan §F11). A trigger holds up to three push
      # filters and they are OR'd — branches and file_paths are ANDed *within*
      # a filter — so two filters of six and five are exactly equivalent to one
      # list of eleven. Both must repeat the branch filter; a push block
      # without one matches every branch, which would run this pipeline on a
      # feature branch's commit.
      #
      # The split is by what a change means rather than arbitrary, so a reader
      # adding a path knows which block it belongs in.

      # What the pipeline builds, and the scripts that produce and check the
      # artefact. The roadmap says app/**; the rest is here by Phase 7 §D12's
      # argument — a change to build-image.sh or to smoke.sh changes what every
      # run of this pipeline does, and it would be odd for that to reach
      # production only when someone next edits a file under app/.
      push {
        branches {
          includes = [var.github_branch]
        }

        file_paths {
          includes = [
            "app/**",
            "pipelines/app-*.yml",
            "scripts/build-image.sh",
            "scripts/generate-sbom.sh",
            "scripts/push-image.sh",
            "scripts/smoke.sh",
          ]
        }
      }

      # The drivers: this pipeline's own two, and the three that BOTH pipelines
      # run. install-terraform.sh, tf.sh and lib/common.sh appear in both
      # triggers deliberately — each is run by both, and a change to die() or
      # to the pinned Terraform version changes what every stage of both does.
      #
      # scripts/** as a whole is deliberately not used, and neither is
      # scripts/pipeline-*.sh: both would match Phase 7's
      # pipeline-terraform.sh, and watching them would deploy the application
      # on an infrastructure change — the mirror image of the mistake §F4
      # found in Phase 7's own filter.
      push {
        branches {
          includes = [var.github_branch]
        }

        file_paths {
          includes = [
            "scripts/pipeline-app-build.sh",
            "scripts/pipeline-deploy.sh",
            "scripts/install-terraform.sh",
            "scripts/tf.sh",
            "scripts/lib/common.sh",
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
        ConnectionArn    = aws_codeconnections_connection.github.arn
        FullRepositoryId = var.github_repository_id
        BranchName       = var.github_branch

        # A git reference, not a zip, and this is the one configuration value
        # in this file that the reproducibility requirement depends on.
        # image_build_identity() reads git rev-parse, git status and git log to
        # derive the tag, SOURCE_DATE_EPOCH and BUILT_AT; a CODE_ZIP workspace
        # has no .git and all three fail. Plan §F2 and §D8.
        #
        # Two accepted costs. The source artifact can only be consumed by
        # CodeBuild actions — every action here that consumes it is one, and
        # the approval consumes none. And the four roles whose builds take it
        # need codeconnections:UseConnection, because the clone is performed by
        # the build rather than by CodePipeline.
        OutputArtifactFormat = "CODEBUILD_CLONE_REF"

        # False, deliberately. True creates a second webhook that fires on
        # every push to the branch with no path filter, which would run this
        # pipeline on an infra-only commit while the trigger block above sat
        # beside it looking as though it were working. In a V2 pipeline the
        # trigger owns change detection. Phase 7 §D13.
        DetectChanges = "false"
      }
    }
  }

  # No scope condition: Build runs under every scope. Deploying an image that
  # was never built is one of the two failures the stage ordering exists to
  # prevent, so there is nothing here for a gate to skip.
  stage {
    name = "Build"

    action {
      name            = "Build"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source"]

      # Load-bearing and it does not default. Without it #{Build.IMAGE_TAG}
      # resolves to nothing and every later stage deploys an empty tag.
      namespace = "Build"

      configuration = {
        ProjectName = aws_codebuild_project.app_image.name

        # Both passed so the build reads no Terraform state: it has no backend
        # and, by design, the narrowest AWS reach of any build that touches the
        # registry.
        EnvironmentVariables = jsonencode([
          { name = "BGD_ECR_REPOSITORY_URL", value = aws_ecr_repository.api.repository_url, type = "PLAINTEXT" },
          { name = "BGD_ARTIFACT_BUCKET", value = aws_s3_bucket.artifacts.bucket, type = "PLAINTEXT" },
          { name = "BGD_ARTIFACT_PREFIX", value = var.app_artifact_prefix, type = "PLAINTEXT" },
        ])
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Staging: apply, then smoke. Two actions, ordered, in one stage.
  #
  # One stage rather than two because before_entry is a stage-level condition:
  # one condition skips the deploy and its check together, and two stages would
  # need two conditions with twice as many ways to disagree with themselves.
  # ---------------------------------------------------------------------------
  stage {
    name = "DeployStaging"

    before_entry {
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
          # whether MATCHES is accepted cannot be confirmed offline. That is why
          # scripts/pipeline-deploy.sh checks APP_SCOPE again — plan §D4, and
          # Phase 7 §F2 for the fallback if it is not.
          configuration = {
            Variable = "#{variables.APP_SCOPE}"
            Operator = local.app_scope_conditions["staging"].operator
            Value    = local.app_scope_conditions["staging"].value
          }
        }
      }
    }

    action {
      name            = "Deploy"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      run_order       = 1
      input_artifacts = ["source"]

      # The smoke action beside this one interpolates #{DeployStaging.SMOKE_URL}
      # and #{DeployStaging.SMOKE_DIGEST}, which is what lets it hold no AWS
      # credentials at all.
      namespace = "DeployStaging"

      configuration = {
        ProjectName = aws_codebuild_project.app_deploy_staging.name

        EnvironmentVariables = jsonencode([
          { name = "ENVIRONMENT", value = "staging", type = "PLAINTEXT" },
          { name = "IMAGE_TAG", value = "#{Build.IMAGE_TAG}", type = "PLAINTEXT" },
          { name = "APP_SCOPE", value = "#{variables.APP_SCOPE}", type = "PLAINTEXT" },
        ])
      }
    }

    action {
      name            = "Smoke"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      run_order       = 2
      input_artifacts = ["source"]

      configuration = {
        ProjectName = aws_codebuild_project.app_smoke.name

        # Everything scripts/smoke.sh needs, passed in. No APP_SCOPE: the
        # stage condition already gated this action, and unlike the deploy
        # beside it this build makes no AWS call, so an unwanted run of it is
        # harmless. That asymmetry is deliberate and it is why only one of
        # these two actions carries a second gate. Plan §D4.
        EnvironmentVariables = jsonencode([
          { name = "BGD_SMOKE_URL", value = "#{DeployStaging.SMOKE_URL}", type = "PLAINTEXT" },
          { name = "BGD_SMOKE_DIGEST", value = "#{DeployStaging.SMOKE_DIGEST}", type = "PLAINTEXT" },
        ])
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Production: plan, approve, apply. Phase 7's stage shape, unchanged.
  #
  # The approval approves a specific change — this digest, this task definition
  # revision — rather than a description of one, and the apply cannot compute
  # something different from what was read, because it applies the saved plan.
  # ---------------------------------------------------------------------------
  stage {
    name = "Prod"

    before_entry {
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

          configuration = {
            Variable = "#{variables.APP_SCOPE}"
            Operator = local.app_scope_conditions["prod"].operator
            Value    = local.app_scope_conditions["prod"].value
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
      namespace        = "PlanProd"
      input_artifacts  = ["source"]
      output_artifacts = ["plan_prod"]

      configuration = {
        ProjectName = aws_codebuild_project.app_plan_prod.name

        EnvironmentVariables = jsonencode([
          { name = "IMAGE_TAG", value = "#{Build.IMAGE_TAG}", type = "PLAINTEXT" },
          { name = "APP_SCOPE", value = "#{variables.APP_SCOPE}", type = "PLAINTEXT" },
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
        # informed decision rather than a reflex. Capped at 1000 characters by
        # CodePipeline, which is why plan_summary() truncates at 900 and offers
        # the full plan behind the link.
        CustomData         = "#{PlanProd.PLAN_SUMMARY}"
        ExternalEntityLink = "#{PlanProd.PLAN_URL}"
      }
    }

    action {
      name      = "Apply"
      category  = "Build"
      owner     = "AWS"
      provider  = "CodeBuild"
      version   = "1"
      run_order = 3

      # The Plan action's output, not "source". This is what makes the approval
      # mean something: the plan a human read is the plan that runs. If this
      # were "source" the apply would re-plan and the approval would have
      # approved something else, with no error at any point. Phase 7 §D9.
      #
      # It is also why this stage's role needs no repository access: a
      # CodePipeline output artifact is an ordinary S3 zip, not a clone
      # reference.
      input_artifacts = ["plan_prod"]

      configuration = {
        ProjectName = aws_codebuild_project.app_deploy_prod.name

        # IMAGE_TAG is not passed to Terraform here — a saved plan rejects
        # variables. It is what the script records in /bgd/prod/image_tag after
        # the apply returns 0 (plan §D9).
        EnvironmentVariables = jsonencode([
          { name = "IMAGE_TAG", value = "#{Build.IMAGE_TAG}", type = "PLAINTEXT" },
          { name = "APP_SCOPE", value = "#{variables.APP_SCOPE}", type = "PLAINTEXT" },
        ])
      }
    }
  }
}
