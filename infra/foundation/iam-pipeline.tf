# The pipeline's four roles.
#
# Named iam-pipeline.tf rather than iam.tf because these belong to the pipeline
# rather than to the layer, and Phases 8 and 9 add more of them. Phase 3's
# amendment to the roadmap is the rule being followed: each of the design's IAM
# roles is created by the phase that creates the resource it acts on, because a
# policy cannot be scoped to resources that do not exist yet.
#
# Three service roles rather than one, because a CodeBuild build's permissions
# come from `service_role` on the project — action.role_arn is the role
# CodePipeline assumes to *invoke* an action, which is a different thing.
# Plan §F3.
#
# Policies are built with jsonencode rather than aws_iam_policy_document, the
# same rule infra/iam.tf follows and for the same reason:
# mock_provider mocks every data source the AWS provider owns, the policy
# document generator among them despite being a pure local computation. Under
# test it returns a random string, so a policy built through it asserts nothing
# and aws_iam_role rejects it client-side. Phase 5 §F1.
#
# Every Action and Resource is written as a LIST even when it holds one element.
# aws_iam_policy_document collapses singletons to a bare string, which is valid
# IAM and awkward to assert on; writing the JSON by hand means the tests can use
# contains() and == without a type check first.

locals {
  # Shared by the three build roles. The account condition is what stops these
  # being confused-deputy shaped — without it, any CodeBuild project anywhere
  # could assume them given the ARN. It matters most on the apply role, which
  # holds AdministratorAccess.
  codebuild_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codebuild.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })

  codepipeline_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}

# ---------------------------------------------------------------------------
# The pipeline itself. It starts builds and moves artifacts; it never calls
# Terraform and never touches the resources being deployed.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "pipeline" {
  name               = "${local.name_prefix}-infra-pipeline-role"
  assume_role_policy = local.codepipeline_assume_role_policy
}

resource "aws_iam_role_policy" "pipeline" {
  name = "${local.name_prefix}-infra-pipeline-policy"
  role = aws_iam_role.pipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ArtifactStore"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:GetBucketVersioning",
        ]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
      },
      {
        # Named, not wildcarded. This role's whole GitHub reach is one
        # repository through one link; a wildcard would let it read anything
        # else the account ever connects.
        Sid      = "UseTheGitHubConnection"
        Effect   = "Allow"
        Action   = ["codeconnections:UseConnection"]
        Resource = [aws_codeconnections_connection.github.arn]
      },
      {
        # The three projects by ARN, in the order the pipeline uses them.
        # StartBuild on * would let this role run any project in the account,
        # including Phase 8's, on a trigger it does not own.
        Sid    = "RunTheBuilds"
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
          "codebuild:StopBuild",
        ]
        Resource = [
          aws_codebuild_project.infra_validate.arn,
          aws_codebuild_project.infra_plan.arn,
          aws_codebuild_project.infra_apply.arn,
        ]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Validate. The only role in this project that reads nothing.
#
# `scripts/tf.sh validate` and `terraform test` both init with -backend=false,
# and tflint and checkov read files. So this build makes no AWS API call, and
# the policy below says so — asserted in tests/pipeline_iam.tftest.hcl, because
# the property erodes the first time someone adds a step that needs "just one
# read" and nothing fails when they do. Plan §D6.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "infra_validate" {
  name               = "${local.name_prefix}-infra-validate-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy" "infra_validate" {
  name = "${local.name_prefix}-infra-validate-policy"
  role = aws_iam_role.infra_validate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CreateLogGroup is granted even though Terraform creates the group,
        # because CodeBuild attempts it on every build and an AccessDenied
        # there surfaces as a build failure rather than as a permissions
        # problem.
        Sid    = "OwnLogGroup"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          aws_cloudwatch_log_group.infra_validate.arn,
          "${aws_cloudwatch_log_group.infra_validate.arn}:*",
        ]
      },
      {
        Sid      = "PipelineArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.artifacts.arn}/*"]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Plan. ReadOnlyAccess, plus four things it does not reliably cover.
#
# This is the role least privilege is actually worth spending effort on: a plan
# reads the world and writes nothing but a lock, so the restriction costs
# nothing and means a compromised plan build — or an edited buildspec — cannot
# mutate the account. Plan §D6.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "infra_plan" {
  name               = "${local.name_prefix}-infra-plan-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy_attachment" "infra_plan_readonly" {
  role       = aws_iam_role.infra_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "infra_plan" {
  name = "${local.name_prefix}-infra-plan-supplement"
  role = aws_iam_role.infra_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OwnLogGroup"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          aws_cloudwatch_log_group.infra_plan.arn,
          "${aws_cloudwatch_log_group.infra_plan.arn}:*",
        ]
      },
      {
        Sid      = "PipelineArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.artifacts.arn}/*"]
      },
      {
        # Scoped to the lock file, not to the bucket prefix. Terraform's native
        # S3 locking writes <key>.tflock beside the state; this lets a plan
        # create and delete its own lock and still leaves it unable to write
        # state at all. Asserted both ways in tests/pipeline_iam.tftest.hcl —
        # once that the narrow grant is present, and once that the broad one is
        # not.
        Sid      = "StateLockOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${local.name_prefix}-tfstate-${var.account_id}/*.tflock"]
      },
      {
        # ReadOnlyAccess is an AWS-managed policy and lags new services and
        # renamed API prefixes. Both spellings of the connection API are
        # granted because the service was renamed and the provider keeps the
        # old one for compatibility (Phase 3 §F1) — a managed policy may carry
        # one and not the other. Plan §F5.
        Sid    = "ReadTheGitHubConnection"
        Effect = "Allow"
        Action = [
          "codeconnections:GetConnection",
          "codeconnections:ListTagsForResource",
          "codestar-connections:GetConnection",
          "codestar-connections:ListTagsForResource",
        ]
        Resource = [aws_codeconnections_connection.github.arn]
      },
      {
        # Granted explicitly although ReadOnlyAccess almost certainly covers
        # it: a plan that cannot read the image tag fails inside
        # data.aws_ecr_image with a message about a missing image rather than
        # about a missing permission, which is a slow way to find a fast
        # problem.
        Sid      = "ReadTheImageTags"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [for env in local.image_tag_environments : aws_ssm_parameter.image_tag[env].arn]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Apply. AdministratorAccess, and the reason is written down rather than
# implied.
#
# This role creates IAM roles in four layers. A principal that can create a
# role and attach a policy to it can grant itself anything, so a narrower
# policy here would describe a boundary that does not exist — while failing at
# apply time in whichever layer it forgot and needing an extension from every
# future phase.
#
# Phase 6's D5 reached an opposite-looking conclusion for the blue/green
# controller by the same rule: write the policy that is honest about the
# boundary, not the one that looks strict.
#
# The control that stands between a merge and a production change is not this
# role. It is the manual approval on a plan a human read, and the fact that the
# apply applies that plan file rather than deciding again. Plan §D6 and §D9.
#
# The account condition on the trust policy therefore does more work here than
# anywhere else in the project: it is the only thing narrowing who can assume
# a role that can do anything.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "infra_apply" {
  name               = "${local.name_prefix}-infra-apply-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy_attachment" "infra_apply_admin" {
  # checkov:skip=CKV_AWS_274:Deliberate, and argued in the plan's §D6. This role creates IAM roles in four layers; a principal that can create a role and attach a policy can already grant itself anything, so a narrower policy would describe a boundary that does not exist. The real control is the manual approval on a plan a human read.
  role       = aws_iam_role.infra_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
