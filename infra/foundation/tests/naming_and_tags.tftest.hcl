# The tagging convention, asserted.
#
# Tag keys are case-sensitive and a misspelling is not an error: `Environment`
# and `environment` are two different tags, both apply cleanly, and the result
# is every future cost report silently split in two. Worse, cost allocation tag
# activation is not retroactive (naming convention §6.2), so the data lost
# between the mistake and its discovery never comes back.
#
# This is the one thing in Phase 3 that a plan review genuinely cannot catch,
# which is why it is a test.

mock_provider "aws" {}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
  domain_name  = "carloscloudengineer.com"
}

run "the_four_tag_keys_are_spelled_exactly_as_the_convention_requires" {
  command = plan

  assert {
    condition     = toset(keys(output.common_tags)) == toset(["environment", "owner", "projectName", "region"])
    error_message = "tag keys must be exactly environment, owner, projectName, region — case-sensitive, no extras, no omissions"
  }
}

run "shared_layers_tag_themselves_shared" {
  command = plan

  assert {
    condition     = output.common_tags["environment"] == "shared"
    error_message = "foundation is not an environment; it is used by both, so environment=shared"
  }
}

run "the_name_prefix_leaves_room_for_the_longest_alb_name" {
  command = plan

  assert {
    condition     = length("${output.name_prefix}-prod-api-blue") <= 32
    error_message = "ALB and target group names are capped at 32 characters and the cap is enforced at apply time"
  }
}

run "both_api_domains_derive_from_one_variable" {
  command = plan

  assert {
    condition     = output.api_domain == "api.carloscloudengineer.com"
    error_message = "production API hostname must be api.<domain_name>"
  }

  assert {
    condition     = output.staging_api_domain == "staging-api.carloscloudengineer.com"
    error_message = "staging API hostname must be staging-api.<domain_name>"
  }
}
