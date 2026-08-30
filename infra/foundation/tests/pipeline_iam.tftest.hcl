# What each of the four roles can do, and — for two of them — what they cannot.
#
# Plan §D6 argues that the plan role is the one place in this pipeline where
# least privilege is both achievable and worth having, and that the validate
# role should never touch AWS at all. Both of those erode quietly: someone adds
# "just one read" to validate, or swaps ReadOnlyAccess for something broader to
# unblock a plan, and nothing fails. These assertions are what says no.
#
# Every policy asserted here is built with jsonencode rather than
# aws_iam_policy_document, for the reason the prod layer's iam.tf records:
# mock_provider mocks every data source the AWS provider owns, the policy
# document generator among them, so a policy built through it is a random
# string under test and these assertions would be vacuous. Phase 5 §F1.
#
# The three runs that read a rendered policy document use `command = apply`,
# for the reason infra/network/tests/routing.tftest.hcl records: every one of
# those policies interpolates a computed ARN — a log group's, the artifact
# bucket's, the connection's, a build project's — and a computed attribute is
# unknown under `command = plan`, which makes the whole jsonencode unknown and
# the condition unevaluable. Against a mocked provider apply creates nothing
# and needs no credentials, but it resolves those ARNs, which is the only way a
# statement's Resource list can be asserted at all.
#
# mock_resource defaults were the other option and are the worse one here: one
# default per resource type gives every role the same ARN, and the assertion
# that the plan project runs as the plan role rather than the apply role would
# then hold no matter which way they were crossed.

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

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
  domain_name  = "carloscloudengineer.com"
}

run "plan_and_apply_are_different_roles_with_different_reach" {
  command = plan

  assert {
    condition     = aws_iam_role.infra_plan.name != aws_iam_role.infra_apply.name
    error_message = "a single role for both means the plan build runs as administrator, which is the thing D6 buys by splitting them"
  }

  assert {
    condition     = aws_iam_role_policy_attachment.infra_plan_readonly.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "the plan role must be read-only; a plan writes nothing but its own lock file"
  }

  assert {
    condition     = aws_iam_role_policy_attachment.infra_apply_admin.policy_arn == "arn:aws:iam::aws:policy/AdministratorAccess"
    error_message = "the apply role is deliberately administrator (D6); if this changed, the reasoning changed and the plan document has to change with it"
  }
}

run "every_pipeline_role_trusts_the_right_service_and_only_this_account" {
  command = plan

  assert {
    condition = alltrue([
      for r in [aws_iam_role.infra_validate, aws_iam_role.infra_plan, aws_iam_role.infra_apply] :
      jsondecode(r.assume_role_policy).Statement[0].Principal.Service == "codebuild.amazonaws.com"
    ])
    error_message = "the three build roles are assumed by CodeBuild; a wrong principal fails at apply with a message about the policy rather than the principal"
  }

  assert {
    condition     = jsondecode(aws_iam_role.pipeline.assume_role_policy).Statement[0].Principal.Service == "codepipeline.amazonaws.com"
    error_message = "the pipeline role is assumed by CodePipeline, not by CodeBuild"
  }

  assert {
    condition = alltrue([
      for r in [aws_iam_role.pipeline, aws_iam_role.infra_validate, aws_iam_role.infra_plan, aws_iam_role.infra_apply] :
      jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "590184028094"
    ])
    error_message = "without the account condition these trust policies are confused-deputy shaped — the same guard the prod roles carry, and it matters most on the role holding AdministratorAccess"
  }
}

run "the_plan_role_can_lock_state_but_cannot_write_it" {
  command = apply

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.infra_plan.policy).Statement :
      s if s.Sid == "StateLockOnly"
    ]).Resource == ["arn:aws:s3:::bgd-us-east-1-tfstate-590184028094/*.tflock"]
    error_message = "the state grant must be scoped to *.tflock — a plan creates and deletes its own lock and must not be able to write state"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.infra_plan.policy).Statement :
      !contains(s.Resource, "arn:aws:s3:::bgd-us-east-1-tfstate-590184028094/*")
    ])
    error_message = "granting the whole state bucket prefix would let a plan overwrite state, which is exactly what the narrow grant avoids"
  }
}

run "the_validate_role_makes_no_aws_call_at_all" {
  command = apply

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.infra_validate.policy).Statement :
      alltrue([for a in s.Action : startswith(a, "logs:") || startswith(a, "s3:")])
    ])
    error_message = "validate runs terraform with -backend=false, tflint and checkov — it needs its log group and the artifact bucket and nothing else. A new prefix here means a step was added that reads the account."
  }
}

run "the_pipeline_role_names_everything_it_may_touch" {
  command = apply

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.pipeline.policy).Statement :
      s if s.Sid == "UseTheGitHubConnection"
    ]).Resource == [aws_codeconnections_connection.github.arn]
    error_message = "UseConnection must name this connection, not *; the pipeline role should not be able to read every repository the account ever connects"
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.pipeline.policy).Statement :
      s if s.Sid == "RunTheBuilds"
      ]).Resource == [
      aws_codebuild_project.infra_validate.arn,
      aws_codebuild_project.infra_plan.arn,
      aws_codebuild_project.infra_apply.arn,
    ]
    error_message = "StartBuild on * would let this role run any build project in the account, including Phase 8's, on a trigger it does not own"
  }
}
