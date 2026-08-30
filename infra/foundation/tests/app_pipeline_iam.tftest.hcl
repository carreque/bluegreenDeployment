# What each of the application pipeline's six roles can do, and — for three of
# them — what they cannot.
#
# Plan §D6 argues two boundaries at opposite ends of the privilege range: the
# smoke build makes no AWS API call at all, and the two deploy roles are
# separated structurally rather than by policy because a policy separation
# between two Terraform-applying roles would be fiction. Both erode quietly.
# Someone gives smoke "just one read" so it can look up a URL; someone merges
# the two deploy roles because the duplication looks pointless. Nothing fails
# when they do. These assertions are what says no.
#
# Every policy asserted here is built with jsonencode rather than
# aws_iam_policy_document, the same rule iam-pipeline.tf follows and for the
# same reason: mock_provider mocks every data source the AWS provider owns, the
# policy document generator among them, so a policy built through it is a
# random string under test and these assertions would be vacuous. Phase 5 §F1.
#
# The runs that read a rendered policy document use `command = apply`, for the
# reason tests/pipeline_iam.tftest.hcl records: every one of those policies
# interpolates a computed ARN — a log group's, the bucket's, the connection's,
# the registry's, a build project's — and a computed attribute is unknown under
# `command = plan`, which makes the whole jsonencode unknown and the condition
# unevaluable. Against a mocked provider, apply creates nothing and needs no
# credentials, but it resolves those ARNs.

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

# One override per role, never one mock_resource default for the type. A shared
# default gives every role the same ARN, and "the staging deploy project runs
# as the staging deploy role" would then hold with the two deploy roles
# crossed — which is the single failure D6's structural separation exists to
# prevent.
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

run "the_two_deploy_roles_are_two_roles" {
  command = plan

  assert {
    condition     = aws_iam_role.app_deploy_staging.name != aws_iam_role.app_deploy_prod.name
    error_message = "one role for both environments would let the staging deploy action reach production. A policy cannot express that separation between two administrator roles; two roles can, because the Prod stage's actions run as a different principal (D6)."
  }

  assert {
    condition = (
      aws_iam_role_policy_attachment.app_deploy_staging_admin.policy_arn == "arn:aws:iam::aws:policy/AdministratorAccess" &&
      aws_iam_role_policy_attachment.app_deploy_prod_admin.policy_arn == "arn:aws:iam::aws:policy/AdministratorAccess"
    )
    error_message = "both deploy roles are deliberately administrator (D6): a terraform apply on a layer that creates IAM roles cannot be meaningfully narrowed. If this changed, the reasoning changed and the plan document has to change with it."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.app_plan_prod_readonly.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "the production plan role must be read-only; a plan writes nothing but its own lock file, and this is what makes D11's approval mean something"
  }
}

run "no_role_but_the_two_deploy_roles_is_an_administrator" {
  command = plan

  assert {
    condition = alltrue([
      for a in [
        aws_iam_role_policy_attachment.app_plan_prod_readonly,
      ] : a.policy_arn != "arn:aws:iam::aws:policy/AdministratorAccess"
    ])
    error_message = "swapping ReadOnlyAccess for AdministratorAccess to unblock a plan is the specific shortcut this asserts against — the approval would then approve a plan produced by a principal that could already have changed anything"
  }
}

run "every_app_pipeline_role_trusts_the_right_service_and_only_this_account" {
  command = plan

  assert {
    condition = alltrue([
      for r in [
        aws_iam_role.app_image,
        aws_iam_role.app_deploy_staging,
        aws_iam_role.app_smoke,
        aws_iam_role.app_plan_prod,
        aws_iam_role.app_deploy_prod,
      ] : jsondecode(r.assume_role_policy).Statement[0].Principal.Service == "codebuild.amazonaws.com"
    ])
    error_message = "the five build roles are assumed by CodeBuild; a wrong principal fails at apply with a message about the policy rather than the principal"
  }

  assert {
    condition     = jsondecode(aws_iam_role.app_pipeline.assume_role_policy).Statement[0].Principal.Service == "codepipeline.amazonaws.com"
    error_message = "the pipeline role is assumed by CodePipeline, not by CodeBuild"
  }

  assert {
    condition = alltrue([
      for r in [
        aws_iam_role.app_deploy_staging,
        aws_iam_role.app_deploy_prod,
      ] : jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "590184028094"
    ])
    error_message = "the account condition is the ONLY narrowing on a role holding AdministratorAccess; without it the trust policy is confused-deputy shaped and any CodeBuild project anywhere could assume it given the ARN"
  }

  assert {
    condition = alltrue([
      for r in [
        aws_iam_role.app_pipeline,
        aws_iam_role.app_image,
        aws_iam_role.app_smoke,
        aws_iam_role.app_plan_prod,
      ] : jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "590184028094"
    ])
    error_message = "the same guard the four Phase 7 roles carry, applied to the four here that are not administrators"
  }
}

run "the_smoke_role_makes_no_aws_call_at_all" {
  command = apply

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.app_smoke.policy).Statement :
      alltrue([for a in s.Action : startswith(a, "logs:") || startswith(a, "s3:")])
    ])
    error_message = "smoke runs curl and jq against a URL passed in as an action-level variable — it needs its log group and the artifact bucket and nothing else. A new prefix here means a step was added that reads the account, and D6's property that the thing checking production-shaped behaviour holds no credentials has gone."
  }

  assert {
    # The clone grant, and only the clone grant, in the second policy. If
    # anything else ever appears beside it, it has been put there to dodge the
    # assertion above.
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.app_smoke_connection.policy).Statement :
      s.Action == ["codeconnections:UseConnection"]
    ])
    error_message = "the smoke role's second policy exists to hold D8's clone grant alone; a second action here is a way around the logs-and-s3 assertion rather than a new requirement"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.app_smoke.policy).Statement :
      s if contains(s.Action, "ecs:DescribeServices") || contains(s.Action, "elasticloadbalancing:DescribeTargetHealth")
    ]) == 0
    error_message = "the two reads a smoke build is most likely to be given. Both are avoidable: the URL and the digest arrive as BGD_SMOKE_URL and BGD_SMOKE_DIGEST from the stage that deployed them."
  }
}

run "the_image_role_pushes_to_one_repository_and_records_nothing" {
  command = apply

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.app_image.policy).Statement :
      s if s.Sid == "PushToTheRegistry"
    ]).Resource == [aws_ecr_repository.api.arn]
    error_message = "the ECR grant must name this repository; a wildcard would let a compromised build push into any registry in the account, including one another team deploys from"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.app_image.policy).Statement :
      !contains(s.Action, "ssm:PutParameter")
    ])
    error_message = "the build must not record a tag. D9: /bgd/<env>/image_tag says what IS deployed, and it is written after a successful apply — if the build wrote it, an infra/** merge landing mid-run would deploy the new image to production with no approval and every stage green."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.app_image.policy).Statement :
      !contains(s.Resource, "*") if anytrue([for a in s.Action : startswith(a, "ecr:") && a != "ecr:GetAuthorizationToken"])
    ])
    error_message = "GetAuthorizationToken is the one ECR action that takes no resource; every other ecr: grant here must name the repository"
  }
}

run "the_four_roles_whose_builds_clone_the_repository_may_use_the_connection" {
  command = apply

  assert {
    # app_smoke's grant is in its own policy resource, not in the one above.
    # D6 says the smoke role's policy holds nothing outside logs: and s3:, and
    # D8 says every role whose build clones the repository needs this grant;
    # both are right, and merging them would have meant relaxing the D6
    # assertion to admit a codeconnections: prefix. Splitting the policy keeps
    # that assertion exactly as strong as D6 claims. Recorded as F13.
    condition = alltrue([
      for p in [
        aws_iam_role_policy.app_image,
        aws_iam_role_policy.app_deploy_staging,
        aws_iam_role_policy.app_smoke_connection,
        aws_iam_role_policy.app_plan_prod,
        ] : one([
          for s in jsondecode(p.policy).Statement : s if s.Sid == "UseTheGitHubConnection"
      ]).Resource == [aws_codeconnections_connection.github.arn]
    ])
    error_message = "CODEBUILD_CLONE_REF means the BUILD performs the clone, not CodePipeline (D8) — without this grant the build fails with an access-denied naming the connection rather than the role. Named, not wildcarded: these roles' whole GitHub reach is one repository."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.app_deploy_prod.policy).Statement :
      !contains(s.Action, "codeconnections:UseConnection")
    ])
    error_message = "the production apply consumes the Plan action's output artifact — a plain S3 zip — and clones nothing. Granting it repository access would be reach nobody asked for on the role that already holds AdministratorAccess."
  }
}

run "the_app_pipeline_role_names_everything_it_may_touch" {
  command = apply

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.app_pipeline.policy).Statement :
      s if s.Sid == "UseTheGitHubConnection"
    ]).Resource == [aws_codeconnections_connection.github.arn]
    error_message = "UseConnection must name this connection, not *; the pipeline role should not be able to read every repository the account ever connects"
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.app_pipeline.policy).Statement :
      s if s.Sid == "RunTheBuilds"
      ]).Resource == [
      aws_codebuild_project.app_image.arn,
      aws_codebuild_project.app_deploy_staging.arn,
      aws_codebuild_project.app_smoke.arn,
      aws_codebuild_project.app_plan_prod.arn,
      aws_codebuild_project.app_deploy_prod.arn,
    ]
    error_message = "StartBuild on * would let this role run any project in the account — Phase 7's four-approval infra applies among them — on a trigger it does not own. Five ARNs, in the order the pipeline uses them."
  }
}

run "the_production_plan_role_can_lock_state_but_cannot_write_it" {
  command = apply

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.app_plan_prod.policy).Statement :
      s if s.Sid == "StateLockOnly"
    ]).Resource == ["arn:aws:s3:::bgd-us-east-1-tfstate-590184028094/*.tflock"]
    error_message = "the state grant must be scoped to *.tflock — a plan creates and deletes its own lock and must not be able to write state. The same grant Phase 7's plan role carries, and for the same reason."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.app_plan_prod.policy).Statement :
      !contains(s.Resource, "arn:aws:s3:::bgd-us-east-1-tfstate-590184028094/*")
    ])
    error_message = "granting the whole state bucket prefix would let a plan overwrite state, which is exactly what the narrow grant avoids"
  }
}
