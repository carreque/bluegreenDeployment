# The reference copy of this layer's mocks. Terraform's test framework has no
# shared-setup construct for mock_provider, so every other test file in this
# directory repeats these three blocks verbatim; this file is what a reviewer
# diffs the copies against.
#
# Each mock_resource default below exists because omitting it produced a hard
# error before any assertion ran, not because it looked tidy. mock_provider
# fills computed attributes with a random eight-character string, and several
# resources validate ARN shape client-side. See Phase 5 plan §F2, and the Phase 6
# local verification record for which of this layer's additions were genuinely
# needed.
#
# What is deliberately NOT mocked: the archive provider. mock_provider mocks one
# provider, so data.archive_file in ../../modules/lambda executes for real during
# terraform test and builds an actual zip from lambdas/lifecycle_hook/handler.py.
# That is the point — the offline gate proves the packaging works rather than
# mocking away the step most likely to be misconfigured. Plan §F4.

variables {
  image_tag = "0.0.0-test"

  # This suite exercises the PRODUCTION shape. Both are set explicitly
  # rather than relying on defaults, which are staging's: a file that
  # forgot them would silently assert production's properties against a
  # staging plan and fail with a message about a missing resource.
  environment = "prod"
  enable_prod = true

  # Mirrors environments/prod.tfvars, which terraform test cannot read: -var-file
  # applies to every file in a run, and this directory holds both suites. The two
  # places that state prod's shape are therefore this line and that file, and
  # prod_compute.tftest.hcl asserts the service actually runs two tasks — so a
  # drift between them fails here rather than in a production apply.
  desired_count = 2
}

mock_provider "aws" {
  source = "./tests/mocks"
}

# Without these two overrides the tests reach the real S3 backend and fail on
# credentials rather than silently asserting against null. Measured — Phase 5
# plan F3.
override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      certificate_arn    = "arn:aws:acm:us-east-1:590184028094:certificate/mock"
      zone_id            = "Z0MOCKZONEID000"
      api_domain         = "api.carloscloudengineer.com"
      staging_api_domain = "staging-api.carloscloudengineer.com"
      ecr_repository_url = "590184028094.dkr.ecr.us-east-1.amazonaws.com/bgd-us-east-1-api"
      ecr_repository_arn = "arn:aws:ecr:us-east-1:590184028094:repository/bgd-us-east-1-api"
      alerts_topic_arn   = "arn:aws:sns:us-east-1:590184028094:bgd-us-east-1-alerts"
    }
  }
}

override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      vpc_id                  = "vpc-0mockvpc"
      public_subnet_ids       = ["subnet-0mockpuba", "subnet-0mockpubb"]
      private_subnet_ids      = ["subnet-0mockprva", "subnet-0mockprvb"]
      alb_security_group_ids  = { staging = "sg-0mockalbstaging", prod = "sg-0mockalbprod" }
      task_security_group_ids = { staging = "sg-0mocktaskstaging", prod = "sg-0mocktaskprod" }
      container_port          = 8080
    }
  }
}

run "the_mock_reference_resolves" {
  command = apply

  assert {
    condition     = local.container_port == 8080
    error_message = "the network remote-state override did not reach locals"
  }

  assert {
    condition     = local.env_prefix == "bgd-us-east-1-prod"
    error_message = "this layer's prefix must be prod's, not staging's"
  }

  assert {
    condition     = local.foundation.api_domain == "api.carloscloudengineer.com"
    error_message = "the foundation override must expose api_domain; prod uses it, not staging_api_domain"
  }
}
