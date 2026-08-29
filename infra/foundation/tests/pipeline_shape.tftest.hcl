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
