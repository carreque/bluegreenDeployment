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
#
# `name` has NO trailing dot, because that is what the aws provider actually
# returns — verified against provider 6.61.0 on 2026-08-31, not assumed. This
# mock previously carried the dotted form copied from the Route 53 API, and the
# adopt assertion below passed against a formatting the provider never produces:
# on the first real apply the filter matched nothing, a second hosted zone was
# created for a delegated domain, and ACM validation hung. A mock is only
# evidence to the extent it matches the thing it stands in for.
mock_provider "aws" {
  alias = "zone_present"

  mock_data "aws_route53_zones" {
    defaults = { ids = ["Z01311493LQ7UOIRHM1H9"] }
  }

  mock_data "aws_route53_zone" {
    defaults = {
      zone_id      = "Z01311493LQ7UOIRHM1H9"
      name         = "carloscloudengineer.com"
      private_zone = false
    }
  }
}

# The same zone, named the way the Route 53 API renders it. The matcher trims
# both sides, so both spellings must adopt — and asserting both is what stops a
# future provider change from silently reintroducing the bug in either
# direction. Neither run alone is sufficient: the undotted mock above is the
# truth today, this one is the truth the provider could return tomorrow.
mock_provider "aws" {
  alias = "zone_present_dotted"

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

run "adopts_the_zone_however_the_provider_spells_the_name" {
  command = plan

  providers = {
    aws = aws.zone_present_dotted
  }

  assert {
    condition     = output.zone_was_created == false
    error_message = "a trailing dot on the zone name must not defeat the match; that exact mismatch created a second zone on 2026-08-31"
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
