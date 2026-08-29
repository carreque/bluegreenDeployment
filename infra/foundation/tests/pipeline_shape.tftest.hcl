# The pipeline's wiring: what runs, in what order, fed by which artifact.
#
# These are the assertions a plan review cannot make. Stage order is a list
# position, artifact hand-off is a string that has to match another string in a
# different block, and the trigger's path filter is invisible until the wrong
# commit starts a run.

mock_provider "aws" {}

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
