# Both paths through find-or-create, and the certificate's two names.
#
# The adopt path is the one Phase 0 proved is real. The create path is tested
# anyway, because it is the path a fresh account takes and the one nobody will
# exercise before needing it to work.

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
  domain_name  = "carloscloudengineer.com"
}

# The account already holds the zone, delegated by the Route 53 registrar.
mock_provider "aws" {
  alias = "zone_present"

  mock_data "aws_route53_zones" {
    defaults = { ids = ["Z01311493LQ7UOIRHM1H9"] }
  }

  mock_data "aws_route53_zone" {
    defaults = {
      zone_id      = "Z01311493LQ7UOIRHM1H9"
      name         = "carloscloudengineer.com."
      private_zone = false
    }
  }
}

# A fresh account: no zones at all.
mock_provider "aws" {
  alias = "zone_absent"

  mock_data "aws_route53_zones" {
    defaults = { ids = [] }
  }
}

run "adopts_the_zone_the_registrar_created" {
  command = plan

  providers = {
    aws = aws.zone_present
  }

  assert {
    condition     = output.zone_was_created == false
    error_message = "the existing zone must be adopted; creating a second zone for the same domain breaks delegation"
  }

  assert {
    condition     = output.zone_id == "Z01311493LQ7UOIRHM1H9"
    error_message = "the adopted zone must be the one the registrar delegated to"
  }
}

run "creates_a_zone_when_the_account_has_none" {
  command = plan

  providers = {
    aws = aws.zone_absent
  }

  assert {
    condition     = output.zone_was_created == true
    error_message = "with no matching zone the layer must create one rather than fail"
  }
}

run "the_certificate_covers_both_environments" {
  command = plan

  providers = {
    aws = aws.zone_present
  }

  assert {
    condition     = aws_acm_certificate.api.domain_name == "api.carloscloudengineer.com"
    error_message = "the certificate's primary name must be the production hostname"
  }

  assert {
    condition     = aws_acm_certificate.api.subject_alternative_names == toset(["staging-api.carloscloudengineer.com"])
    error_message = "one certificate covers both environments; a second certificate is a second thing to renew"
  }

  assert {
    condition     = aws_acm_certificate.api.validation_method == "DNS"
    error_message = "DNS validation renews automatically; email validation does not"
  }
}

run "one_validation_record_per_name" {
  command = plan

  providers = {
    aws = aws.zone_present
  }

  assert {
    condition     = length(aws_route53_record.certificate_validation) == 2
    error_message = "each name on the certificate needs its own validation record, or issuance never completes"
  }
}
