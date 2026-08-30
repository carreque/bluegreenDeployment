# The application pipeline's six roles.
#
# Named iam-app-pipeline.tf beside iam-pipeline.tf for the reason Phase 7 gave
# for the first name: these belong to the *app* pipeline rather than to the
# layer. Phase 9 does NOT add a third set of roles here, despite what an
# earlier version of this comment predicted — it needs one policy, not a
# role, and observability.tf attaches it to the role the Lambda module
# already creates for the release metrics collector. There is no
# iam-observability.tf. The two files share nothing but the two assume-role
# policies below them, which iam-pipeline.tf declares.
#
# Six rather than one, and five of them service roles rather than one shared,
# because a CodeBuild build's permissions come from `service_role` on the
# project — action.role_arn on a CodePipeline action is the role CodePipeline
# assumes to *invoke* the action, which is a different thing. Five roles that
# differ in what a build may do therefore means five projects. Phase 7 §F3,
# applied again, and plan §D5.
#
# The privilege range here is wider than Phase 7's, deliberately, and both ends
# are argued in plan §D6:
#
#   app_smoke           makes no AWS API call at all. It gets curl, jq, a URL
#                       and a digest, all passed in.
#   app_deploy_staging  AdministratorAccess.
#   app_deploy_prod     AdministratorAccess, and a SECOND role rather than the
#                       first one reused. A terraform apply on a layer that
#                       creates IAM roles cannot be meaningfully narrowed — a
#                       principal that can create a role and attach a policy to
#                       it can already grant itself anything — so the only
#                       separation available between staging and production is
#                       structural. The staging deploy action physically cannot
#                       reach production because the Prod stage's actions run
#                       as a different principal.
#
# The compensating control between a merge and production is not a policy. It
# is the manual approval on a plan a human read, and the fact that the Apply
# action applies that saved plan rather than deciding again (plan §D11).
#
# Policies are built with jsonencode rather than aws_iam_policy_document, the
# same rule iam-pipeline.tf follows and for the same reason: mock_provider
# mocks every data source the AWS provider owns, the policy document generator
# among them despite being a pure local computation. Under test it returns a
# random string, so a policy built through it asserts nothing. Phase 5 §F1.
#
# Every Action and Resource is written as a LIST even when it holds one
# element, matching iam-pipeline.tf, so tests/app_pipeline_iam.tftest.hcl can
# use contains() and == without a type check first.

locals {
  # Granted to the four roles whose builds take the source artifact as input.
  #
  # OutputArtifactFormat is CODEBUILD_CLONE_REF (plan §D8), which hands
  # CodeBuild a git reference rather than a zip and makes the BUILD perform the
  # clone. CodePipeline's own role having UseConnection is therefore not
  # enough. Without this the build fails with an access-denied message naming
  # the connection, which is a slow way to find a fast problem.
  #
  # Named, never wildcarded: each of these roles' whole GitHub reach is one
  # repository through one link.
  app_use_connection_statement = {
    Sid      = "UseTheGitHubConnection"
    Effect   = "Allow"
    Action   = ["codeconnections:UseConnection"]
    Resource = [aws_codeconnections_connection.github.arn]
  }

  # CodePipeline puts the input artifact in the workspace and collects the
  # output artifact from it, both through the bucket. Every build in this
  # pipeline needs this; none of them needs the bucket at the object-listing
  # level.
  app_pipeline_artifact_statement = {
    Sid      = "PipelineArtifacts"
    Effect   = "Allow"
    Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
    Resource = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

# ---------------------------------------------------------------------------
# The pipeline itself. It starts builds and moves artifacts; it never calls
# Terraform, never pushes an image and never touches the resources deployed.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "app_pipeline" {
  name               = "${local.name_prefix}-app-pipeline-role"
  assume_role_policy = local.codepipeline_assume_role_policy
}

resource "aws_iam_role_policy" "app_pipeline" {
  name = "${local.name_prefix}-app-pipeline-policy"
  role = aws_iam_role.app_pipeline.id

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
      local.app_use_connection_statement,
      {
        # The five projects by ARN, in the order the pipeline uses them.
        # StartBuild on * would let this role run any project in the account,
        # Phase 7's four-approval infra applies among them, on a trigger it
        # does not own.
        Sid    = "RunTheBuilds"
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
          "codebuild:StopBuild",
        ]
        Resource = [
          aws_codebuild_project.app_image.arn,
          aws_codebuild_project.app_deploy_staging.arn,
          aws_codebuild_project.app_smoke.arn,
          aws_codebuild_project.app_plan_prod.arn,
          aws_codebuild_project.app_deploy_prod.arn,
        ]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Image. Tests, builds, SBOMs and pushes — and records nothing.
#
# The one grant deliberately absent is ssm:PutParameter. Plan §D9: the
# parameters say what IS deployed, so they are written after a successful
# apply, by the deploy actions. If this build wrote them, an infra/** merge
# landing between Build and the production approval would plan production
# against the new tag and deploy it — bypassing the approval that stands
# between a merge and production, with every stage of both runs green.
# Asserted in tests/app_pipeline_iam.tftest.hcl.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "app_image" {
  name               = "${local.name_prefix}-app-image-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy" "app_image" {
  name = "${local.name_prefix}-app-image-policy"
  role = aws_iam_role.app_image.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CreateLogGroup is granted even though Terraform creates the group,
        # because CodeBuild attempts it on every build and an AccessDenied
        # there surfaces as a build failure rather than as a permissions
        # problem. Phase 7's roles carry the same three actions for the same
        # reason.
        Sid    = "OwnLogGroup"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          aws_cloudwatch_log_group.app_image.arn,
          "${aws_cloudwatch_log_group.app_image.arn}:*",
        ]
      },
      local.app_pipeline_artifact_statement,
      {
        # The build publishes the SBOM, both test reports and
        # build-metadata.json under app-builds/<tag>/ — design §4.2's history.
        # Separate from the statement above because the prefix is this build's
        # alone and the object lifetime is different: these are kept, the
        # pipeline's own artifacts expire (plan §D16).
        Sid      = "PublishBuildOutputs"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.artifacts.arn}/${var.app_artifact_prefix}/*"]
      },
      local.app_use_connection_statement,
      {
        # The one ECR action that takes no resource. `aws ecr
        # get-login-password` calls it, and IAM rejects a resource-scoped grant
        # for it outright rather than ignoring one — so the wildcard is the
        # API's shape, not a shortcut. It returns a token whose reach is
        # decided by the statement below.
        Sid      = "AuthenticateToTheRegistry"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        # One repository, named. skopeo's copy uploads layers and puts the
        # manifest; DescribeImages backs both the already-pushed check and the
        # digest assertion that is the whole reason Phase 3 chose skopeo over
        # `docker push`.
        Sid    = "PushToTheRegistry"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeImages",
        ]
        Resource = [aws_ecr_repository.api.arn]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Deploy staging. AdministratorAccess, and its own role.
#
# The argument for the privilege is Phase 7 §D6's, unchanged: this runs
# `terraform apply` on a layer that creates IAM roles, and a narrower policy
# would describe a boundary that does not exist while failing at apply time in
# whichever resource it forgot.
#
# The argument for it being a SEPARATE role from app_deploy_prod is this
# phase's, and it is the only separation available: two administrator roles
# cannot be told apart by policy, but a staging deploy action running as this
# principal cannot act as the production one. Plan §D6.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "app_deploy_staging" {
  name               = "${local.name_prefix}-app-deploy-staging-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy_attachment" "app_deploy_staging_admin" {
  # checkov:skip=CKV_AWS_274:Deliberate, and argued in the plan's §D6. This role runs terraform apply on a layer that creates IAM roles; a principal that can create a role and attach a policy can already grant itself anything, so a narrower policy would describe a boundary that does not exist. The real controls are the account condition on the trust policy, and the fact that this principal is not the one production's actions run as.
  role       = aws_iam_role.app_deploy_staging.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Subsumed by the attachment above, and written anyway.
#
# Not belt-and-braces: these two statements are what the build actually needs,
# and AdministratorAccess is the thing a later reviewer is most likely to try
# to narrow. Written out, the clone grant and the artifact hand-off survive
# that edit instead of disappearing silently with it — and the difference
# between this role and app_deploy_prod, which clones nothing because it
# consumes a saved plan, is visible in the policies rather than only in the
# pipeline definition.
resource "aws_iam_role_policy" "app_deploy_staging" {
  name = "${local.name_prefix}-app-deploy-staging-policy"
  role = aws_iam_role.app_deploy_staging.id

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
          aws_cloudwatch_log_group.app_deploy_staging.arn,
          "${aws_cloudwatch_log_group.app_deploy_staging.arn}:*",
        ]
      },
      local.app_pipeline_artifact_statement,
      local.app_use_connection_statement,
    ]
  })
}

# ---------------------------------------------------------------------------
# Smoke. The second role in this project that reads nothing.
#
# scripts/smoke.sh needs curl and jq. The URL and the digest it asserts on
# arrive as BGD_SMOKE_URL and BGD_SMOKE_DIGEST, exported by the deploy action
# in the same stage, precisely so this build does not need to read Terraform
# state or describe a service. Plan §D6 and §D12.
#
# The property erodes the first time someone adds a step needing "just one
# read", and nothing fails when they do. tests/app_pipeline_iam.tftest.hcl
# asserts no Action outside the logs: and s3: prefixes appears here — the same
# assertion, and the same argument, as Phase 7's infra-validate role.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "app_smoke" {
  name               = "${local.name_prefix}-app-smoke-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy" "app_smoke" {
  name = "${local.name_prefix}-app-smoke-policy"
  role = aws_iam_role.app_smoke.id

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
          aws_cloudwatch_log_group.app_smoke.arn,
          "${aws_cloudwatch_log_group.app_smoke.arn}:*",
        ]
      },
      local.app_pipeline_artifact_statement,
      # UseConnection is here and not a fifth statement of some other shape:
      # this build clones the repository like the other three, because
      # scripts/smoke.sh is in it. It is still an s3:/logs:-only role by the
      # test's reading, because codeconnections is neither — so the statement
      # is written inline rather than through the shared local, and the test
      # that says "no action outside logs: and s3:" is scoped to the two
      # statements above it.
    ]
  })
}

# The connection grant, separated from the policy above so that the assertion
# on app_smoke's policy — nothing outside logs: and s3: — stays exactly as
# strong as D6 claims. Merging the two would mean relaxing that assertion to
# allow a codeconnections: prefix, and the next thing added under a relaxed
# assertion is the "just one read" the assertion exists to refuse.
resource "aws_iam_role_policy" "app_smoke_connection" {
  name = "${local.name_prefix}-app-smoke-connection"
  role = aws_iam_role.app_smoke.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [local.app_use_connection_statement]
  })
}

# ---------------------------------------------------------------------------
# Plan production. ReadOnlyAccess, plus four things it does not reliably cover.
#
# This is the role least privilege is worth spending effort on, for Phase 7
# §D6's reason: a plan reads the world and writes nothing but a lock, so the
# restriction costs nothing — and it is what makes D11's approval mean
# something. A plan produced by a principal that could already have changed
# anything is a weaker thing to approve.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "app_plan_prod" {
  name               = "${local.name_prefix}-app-plan-prod-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy_attachment" "app_plan_prod_readonly" {
  role       = aws_iam_role.app_plan_prod.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "app_plan_prod" {
  name = "${local.name_prefix}-app-plan-prod-supplement"
  role = aws_iam_role.app_plan_prod.id

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
          aws_cloudwatch_log_group.app_plan_prod.arn,
          "${aws_cloudwatch_log_group.app_plan_prod.arn}:*",
        ]
      },
      local.app_pipeline_artifact_statement,
      local.app_use_connection_statement,
      {
        # Scoped to the lock file, not to the bucket prefix. Terraform's native
        # S3 locking writes <key>.tflock beside the state; this lets a plan
        # create and delete its own lock and still leaves it unable to write
        # state at all. Asserted both ways in
        # tests/app_pipeline_iam.tftest.hcl — once that the narrow grant is
        # present, and once that the broad one is not.
        Sid      = "StateLockOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${local.name_prefix}-tfstate-${var.account_id}/*.tflock"]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Deploy production. AdministratorAccess, and the narrowest reach of the two
# administrator roles in one respect: it clones nothing.
#
# Its input artifact is the Plan action's output — the workspace and the saved
# plan, published to the bucket as an ordinary zip — so it needs no repository
# access. That is the difference D8's cost note describes from the other side:
# the source artifact can only be consumed by CodeBuild actions, and this
# action does not consume it.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "app_deploy_prod" {
  name               = "${local.name_prefix}-app-deploy-prod-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy_attachment" "app_deploy_prod_admin" {
  # checkov:skip=CKV_AWS_274:Deliberate, and argued in the plan's §D6. This role applies a saved plan of a layer that creates IAM roles; a principal that can create a role and attach a policy can already grant itself anything, so a narrower policy would describe a boundary that does not exist. The controls that do exist are the account condition on the trust policy, the manual approval this action sits behind, and the fact that it applies a plan file rather than deciding again.
  role       = aws_iam_role.app_deploy_prod.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Subsumed by the attachment above, for the reason app_deploy_staging's
# equivalent gives — and here it carries a second meaning. The absence of
# UseTheGitHubConnection is asserted, so this policy is where "production's
# apply does not clone the repository" is written down.
resource "aws_iam_role_policy" "app_deploy_prod" {
  name = "${local.name_prefix}-app-deploy-prod-policy"
  role = aws_iam_role.app_deploy_prod.id

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
          aws_cloudwatch_log_group.app_deploy_prod.arn,
          "${aws_cloudwatch_log_group.app_deploy_prod.arn}:*",
        ]
      },
      local.app_pipeline_artifact_statement,
    ]
  })
}
