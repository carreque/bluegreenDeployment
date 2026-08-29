# The three projects that execute the infra pipeline.
#
# Three rather than one because a build's permissions come from `service_role`,
# which is a property of the project — `action.role_arn` on a CodePipeline
# action is the role CodePipeline assumes to *invoke* the action, which is a
# different thing (plan §F3). Three roles that differ in what a build may do
# therefore means three projects.
#
# Which LAYER a build works on is not a property of the project. It is passed
# per action through the CodeBuild action's EnvironmentVariables override, so
# eight actions — four plans and four applies — share two projects.

locals {
  # x86_64 for all three. scripts/lint-infra.sh runs tflint and checkov from
  # digest-pinned containers, and those digests passing on the development
  # machine does not prove they have linux/arm64 variants: Docker Desktop runs
  # amd64 images transparently under emulation. CodeBuild does not. amd64 is
  # the side that is certainly safe for both pins, and Terraform is
  # architecture-agnostic. Phase 8's app build is ARM because its image is.
  # Plan §D7.
  codebuild_image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
  codebuild_compute_type = "BUILD_GENERAL1_SMALL"
}

resource "aws_cloudwatch_log_group" "infra_validate" {
  # checkov:skip=CKV_AWS_338:thirty days is deliberate and is what var.pipeline_log_retention_days says: a pipeline log is worth keeping until the deployment it describes is understood, and retention is the entirety of what a log group costs. A year of build output for a repository whose every build is reproducible from the commit that produced it buys nothing. Same reasoning as network's flow logs and both ECS log groups.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. This group holds the validate build's stdout — terraform plan output, tflint and checkov findings, and the resource addresses in a plan summary. All of it is derived from the commit, and none of it is a credential or a customer record.
  name              = "/bgd/${var.region}/shared/infra-validate"
  retention_in_days = var.pipeline_log_retention_days
}

resource "aws_cloudwatch_log_group" "infra_plan" {
  # checkov:skip=CKV_AWS_338:thirty days is deliberate and is what var.pipeline_log_retention_days says: a pipeline log is worth keeping until the deployment it describes is understood, and retention is the entirety of what a log group costs. A year of build output for a repository whose every build is reproducible from the commit that produced it buys nothing. Same reasoning as network's flow logs and both ECS log groups.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. This group holds the plan build's stdout — terraform plan output, tflint and checkov findings, and the resource addresses in a plan summary. All of it is derived from the commit, and none of it is a credential or a customer record.
  name              = "/bgd/${var.region}/shared/infra-plan"
  retention_in_days = var.pipeline_log_retention_days
}

resource "aws_cloudwatch_log_group" "infra_apply" {
  # checkov:skip=CKV_AWS_338:thirty days is deliberate and is what var.pipeline_log_retention_days says: a pipeline log is worth keeping until the deployment it describes is understood, and retention is the entirety of what a log group costs. A year of build output for a repository whose every build is reproducible from the commit that produced it buys nothing. Same reasoning as network's flow logs and both ECS log groups.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. This group holds the apply build's stdout — terraform plan output, tflint and checkov findings, and the resource addresses in a plan summary. All of it is derived from the commit, and none of it is a credential or a customer record.
  name              = "/bgd/${var.region}/shared/infra-apply"
  retention_in_days = var.pipeline_log_retention_days
}

# The gate, and the only project that needs docker.
resource "aws_codebuild_project" "infra_validate" {
  # checkov:skip=CKV_AWS_147:SSE-S3 and AWS-owned keys throughout, decided once in the Phase 3 plan §D4 and applied to every encrypted-at-rest resource here. A customer-managed key costs a monthly charge and its own policy for build logs that are reproducible from the commit.
  name          = "${local.name_prefix}-infra-validate-build"
  service_role  = aws_iam_role.infra_validate.arn
  build_timeout = 20

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = local.codebuild_compute_type
    image        = local.codebuild_image
    type         = "LINUX_CONTAINER"

    # checkov:skip=CKV_AWS_316:Docker-in-docker is how scripts/lint-infra.sh runs its digest-pinned tflint and checkov containers — the identical command used locally, installing nothing on the host. Removing it means installing both tools into the build image at floating versions, which is the drift the pins exist to prevent. Plan §F9.
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/infra-validate.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.infra_validate.name
      stream_name = "build"
    }
  }
}

resource "aws_codebuild_project" "infra_plan" {
  # checkov:skip=CKV_AWS_147:Same decision as infra_validate above, and as every other encrypted-at-rest resource in this project. Phase 3 plan §D4.
  name         = "${local.name_prefix}-infra-plan-build"
  service_role = aws_iam_role.infra_plan.arn

  # Longer than validate's because a plan on prod refreshes an ECS service, two
  # DynamoDB tables, an ALB with three listeners and three Lambda functions.
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = local.codebuild_compute_type
    image        = local.codebuild_image
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/infra-plan.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.infra_plan.name
      stream_name = "build"
    }
  }
}

resource "aws_codebuild_project" "infra_apply" {
  # checkov:skip=CKV_AWS_147:Same decision as infra_validate above, and as every other encrypted-at-rest resource in this project. Phase 3 plan §D4.
  name         = "${local.name_prefix}-infra-apply-build"
  service_role = aws_iam_role.infra_apply.arn

  # 60 minutes, and prod is why. Its service sets wait_for_steady_state, so an
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
    compute_type = local.codebuild_compute_type
    image        = local.codebuild_image
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/infra-apply.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.infra_apply.name
      stream_name = "build"
    }
  }
}
