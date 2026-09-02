# The reference copy of this layer's mocks. Terraform's test framework has no
# shared-setup construct for mock_provider, so every other test file in this
# directory repeats these three blocks verbatim; this file is what a reviewer
# diffs the copies against.
#
# Each mock_resource default below exists because omitting it produced a hard
# error before any assertion ran, not because it looked tidy. mock_provider
# fills computed attributes with a random eight-character string, and several
# resources validate ARN shape client-side. See the plan's F2.

variables {
  image_tag = "0.0.0-test"

  # This suite exercises the STAGING shape. Stated explicitly even though
  # both match the variable defaults, so the file says what it tests
  # rather than depending on a default staying put.
  environment = "staging"
  enable_prod = false
}

mock_provider "aws" {
  source = "./tests/mocks"
}

# Without these two overrides the tests reach the real S3 backend and fail on
# credentials rather than silently asserting against null. Measured — plan F3.
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
}
