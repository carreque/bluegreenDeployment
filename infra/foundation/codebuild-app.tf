# The five projects that execute the application pipeline.
#
# Five rather than one, and five rather than two, because a build's permissions
# come from `service_role`, which is a property of the project — action.role_arn
# on a CodePipeline action is the role CodePipeline assumes to *invoke* the
# action, which is a different thing (Phase 7 §F3). Five roles that differ in
# what a build may do therefore means five projects. Plan §D5.
#
# The difference from codebuild.tf next door is worth stating, because it looks
# like an inconsistency and is not. There, the LAYER a build works on is passed
# per action, so eight actions share two projects. Here there is no shared
# deploy project: app-deploy-staging and app-deploy-prod differ in their ROLE,
# not only in a variable, and that difference is the whole point of the
# separation (plan §D6). A shared project would have to run under one role, and
# the staging deploy would then be able to reach production.
#
# The compute-type divergence is deliberate in both directions and it is one
# fact seen twice: what decides the compute type is the architecture of the
# artifacts a build handles, not a project-wide preference. Plan §D7.

locals {
  # aarch64, and only for the image build. The image is linux/arm64 only
  # (Phase 2's amendment), so an x86 build would have to emulate — which
  # measures the emulator as much as the Dockerfile — and would produce a
  # manifest for the wrong architecture. That manifest pushes cleanly and the
  # ECS task fails at start, minutes later, with an exec format error.
  app_image_build_image = "aws/codebuild/amazonlinux-aarch64-standard:3.0"

  # x86_64 for the other four. They run Terraform, curl and jq, all
  # architecture-agnostic, and scripts/install-terraform.sh pins a
  # linux_amd64 checksum. Deliberately the same image and the same compute
  # type as the three infra projects: a change to the pinned Terraform version
  # should mean one thing in both pipelines.
  app_deploy_build_image  = local.codebuild_image
  app_deploy_compute_type = local.codebuild_compute_type
}

# ---------------------------------------------------------------------------
# Log groups, created before the projects that reference them.
#
# CodeBuild creates its own group on first build if Terraform does not, without
# retention and outside this configuration — and the two skips below would then
# explain a decision about a resource this layer does not own.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app_image" {
  # checkov:skip=CKV_AWS_338:thirty days is deliberate and is what var.pipeline_log_retention_days says: a pipeline log is worth keeping until the deployment it describes is understood, and retention is the entirety of what a log group costs. The durable record of a build — its SBOM, its two test reports and its metadata — is published to the artifact bucket under app-builds/<tag>/ and kept indefinitely, which is where design §4.2's history actually lives.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. This group holds pytest output, buildx output and a syft package count. All of it is derived from the commit, and none of it is a credential or a customer record.
  name              = "/bgd/${var.region}/shared/app-image"
  retention_in_days = var.pipeline_log_retention_days
}

resource "aws_cloudwatch_log_group" "app_deploy_staging" {
  # checkov:skip=CKV_AWS_338:thirty days is deliberate and is what var.pipeline_log_retention_days says: a pipeline log is worth keeping until the deployment it describes is understood, and retention is the entirety of what a log group costs. Same reasoning as the three Phase 7 groups and both ECS log groups.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. This group holds terraform apply output for the staging layer — resource addresses and an image tag, both of which are in the repository or in a /version response.
  name              = "/bgd/${var.region}/shared/app-deploy-staging"
  retention_in_days = var.pipeline_log_retention_days
}

resource "aws_cloudwatch_log_group" "app_smoke" {
  # checkov:skip=CKV_AWS_338:thirty days is deliberate and is what var.pipeline_log_retention_days says: a pipeline log is worth keeping until the deployment it describes is understood, and retention is the entirety of what a log group costs. Same reasoning as the three Phase 7 groups and both ECS log groups.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. This group holds three HTTP status codes and an image digest that /version serves publicly.
  name              = "/bgd/${var.region}/shared/app-smoke"
  retention_in_days = var.pipeline_log_retention_days
}

resource "aws_cloudwatch_log_group" "app_plan_prod" {
  # checkov:skip=CKV_AWS_338:thirty days is deliberate and is what var.pipeline_log_retention_days says: a pipeline log is worth keeping until the deployment it describes is understood, and retention is the entirety of what a log group costs. Same reasoning as the three Phase 7 groups and both ECS log groups.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. This group holds a terraform plan of the production layer — resource addresses and attribute diffs for infrastructure whose configuration is in this repository.
  name              = "/bgd/${var.region}/shared/app-plan-prod"
  retention_in_days = var.pipeline_log_retention_days
}

resource "aws_cloudwatch_log_group" "app_deploy_prod" {
  # checkov:skip=CKV_AWS_338:thirty days is deliberate and is what var.pipeline_log_retention_days says: a pipeline log is worth keeping until the deployment it describes is understood, and retention is the entirety of what a log group costs. Same reasoning as the three Phase 7 groups and both ECS log groups.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. This group holds the production apply's output, including the blue/green deployment's progress. All of it is derived from the commit and from the plan the approval displayed.
  name              = "/bgd/${var.region}/shared/app-deploy-prod"
  retention_in_days = var.pipeline_log_retention_days
}

# ---------------------------------------------------------------------------
# Image. The only ARM project in the account, and the only privileged one.
# Tests, builds, SBOMs, pushes and publishes; records nothing (plan §D9).
# ---------------------------------------------------------------------------

resource "aws_codebuild_project" "app_image" {
  # checkov:skip=CKV_AWS_147:SSE-S3 and AWS-owned keys throughout, decided once in the Phase 3 plan §D4 and applied to every encrypted-at-rest resource here. A customer-managed key costs a monthly charge and its own policy for build logs that are reproducible from the commit.
  name         = "${local.name_prefix}-app-image-build"
  service_role = aws_iam_role.app_image.arn

  # Thirty minutes. A cold ARM build pulls the CodeBuild image, then
  # python:3.14.6-slim and amazon/dynamodb-local for the test run (plan §D10),
  # then runs a --no-cache buildx build, syft and skopeo. None of those is
  # cached between builds, deliberately: an artifact of record should not be
  # assembled from layers built at some other time.
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = var.app_build_compute_type
    image        = local.app_image_build_image
    type         = "ARM_CONTAINER"

    # checkov:skip=CKV_AWS_316:Required twice over. docker buildx with the docker-container driver is the only driver that honours rewrite-timestamp, which Phase 2 §F1 measured and which the reproducibility requirement in design §4.1 depends on; and the test run itself is two digest-pinned containers, because CodeBuild's ARM image ships Python 3.11 and 3.12 rather than the 3.14.6 .python-version pins (plan §F3 and §D10). Removing privileged mode means either abandoning reproducibility or building CPython from source in every build.
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/app-build.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.app_image.name
      stream_name = "build"
    }
  }
}

# ---------------------------------------------------------------------------
# Deploy staging. terraform apply -auto-approve, then record the tag.
#
# One action, not plan-then-approve, because staging's stated job is to fail
# fast (roadmap §Phase 5) and there is nobody to approve anything at that point
# in the run. A human gate in front of the environment whose purpose is to be
# the gate would be a strange shape. Plan §D11.
# ---------------------------------------------------------------------------

resource "aws_codebuild_project" "app_deploy_staging" {
  # checkov:skip=CKV_AWS_147:Same decision as app_image above, and as every other encrypted-at-rest resource in this project. Phase 3 plan §D4.
  name         = "${local.name_prefix}-app-deploy-staging-build"
  service_role = aws_iam_role.app_deploy_staging.arn

  # Thirty, matching Phase 7's plan project. The staging service does not set
  # wait_for_steady_state, so this apply returns when the service update is
  # accepted rather than when it has stabilised.
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = local.app_deploy_compute_type
    image        = local.app_deploy_build_image
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/app-deploy.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.app_deploy_staging.name
      stream_name = "build"
    }
  }
}

# ---------------------------------------------------------------------------
# Smoke. scripts/smoke.sh against a URL passed in, holding no credentials.
#
# Its own project rather than a step folded into the deploy buildspec, for two
# reasons (plan §D12). Folding it in would make "the apply failed" and "the
# deployment succeeded but the service is wrong" indistinguishable in the
# pipeline view — and it would lose D6's property that the thing checking
# production-shaped behaviour holds nothing.
# ---------------------------------------------------------------------------

resource "aws_codebuild_project" "app_smoke" {
  # checkov:skip=CKV_AWS_147:Same decision as app_image above, and as every other encrypted-at-rest resource in this project. Phase 3 plan §D4.
  name         = "${local.name_prefix}-app-smoke-build"
  service_role = aws_iam_role.app_smoke.arn

  # Twenty. Three HTTP probes, the longest of which waits 40 seconds because
  # /ready's 503 takes 25.6 seconds when DynamoDB is unreachable (Phase 5 §F5).
  # Generous already; longer would only hide a hung stage.
  build_timeout = 20

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = local.app_deploy_compute_type
    image        = local.app_deploy_build_image
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/app-smoke.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.app_smoke.name
      stream_name = "build"
    }
  }
}

# ---------------------------------------------------------------------------
# Plan production. ReadOnlyAccess, and it exports what the approval displays.
# ---------------------------------------------------------------------------

resource "aws_codebuild_project" "app_plan_prod" {
  # checkov:skip=CKV_AWS_147:Same decision as app_image above, and as every other encrypted-at-rest resource in this project. Phase 3 plan §D4.
  name         = "${local.name_prefix}-app-plan-prod-build"
  service_role = aws_iam_role.app_plan_prod.arn

  # Thirty, matching Phase 7's plan project and for the same reason: a plan on
  # prod refreshes an ECS service, two DynamoDB tables, an ALB with three
  # listeners and three Lambda functions.
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = local.app_deploy_compute_type
    image        = local.app_deploy_build_image
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/app-plan.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.app_plan_prod.name
      stream_name = "build"
    }
  }
}

# ---------------------------------------------------------------------------
# Deploy production. The saved plan, and only the saved plan.
# ---------------------------------------------------------------------------

resource "aws_codebuild_project" "app_deploy_prod" {
  # checkov:skip=CKV_AWS_147:Same decision as app_image above, and as every other encrypted-at-rest resource in this project. Phase 3 plan §D4.
  name         = "${local.name_prefix}-app-deploy-prod-build"
  service_role = aws_iam_role.app_deploy_prod.arn

  # 60 minutes, and it is the same number Phase 7's apply project carries for
  # the same reason. The production service sets wait_for_steady_state, so an
  # apply that starts a blue/green deployment does not return until green has
  # been provisioned, tested by three hooks, promoted and baked for five
  # minutes under the alarms — six to ten minutes when it goes well, and this
  # timeout should not be the thing that decides when it has gone badly.
  # Phase 6 plan §D11.
  build_timeout = 60

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = local.app_deploy_compute_type
    image        = local.app_deploy_build_image
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/app-apply.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.app_deploy_prod.name
      stream_name = "build"
    }
  }
}
