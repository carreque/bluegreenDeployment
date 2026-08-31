# Find-or-create, per design §1.7.
#
# The singular aws_route53_zone data source errors at plan time when nothing
# matches, so "look it up, else create it" cannot be written with it. The plural
# aws_route53_zones takes no arguments and returns a plain list of ids, empty
# when the account has none — and because data sources resolve during plan, the
# for_each below receives known values.

data "aws_route53_zones" "all" {}

data "aws_route53_zone" "candidates" {
  for_each = toset(data.aws_route53_zones.all.ids)
  zone_id  = each.value
}

locals {
  # `private_zone != true` rather than `!private_zone`, deliberately. This reads
  # every hosted zone in the account, and each one's attributes must survive the
  # expression before the name filter can exclude it. A null boolean — from a
  # zone this project did not create, or a provider that widens the type — makes
  # the negation abort the whole plan with "argument must not be null", on a line
  # that looks correct. See the Phase 3 plan §F4.
  #
  # Both sides are trimmed rather than one side being written with a trailing
  # dot, and that is the whole bug this line once had. Route 53's API returns
  # `carloscloudengineer.com.`, so the comparison was written against that —
  # but the aws provider's data source normalises it and hands back
  # `carloscloudengineer.com`, with no dot. The filter therefore matched
  # nothing, `zone_exists` was permanently false, and the create path ran on an
  # account that already held a correctly delegated zone. The symptom is not a
  # failed apply: it is a second zone nobody points at, ACM validation records
  # written into it, and `aws_acm_certificate_validation` hanging for its
  # 75-minute timeout. Found 2026-08-31, on the first real foundation apply.
  #
  # trimsuffix on both sides rather than dropping the dot from the literal, so
  # this survives the provider normalising the other way again.
  matched_zone_ids = [
    for zone in data.aws_route53_zone.candidates : zone.zone_id
    if trimsuffix(zone.name, ".") == trimsuffix(var.domain_name, ".") && zone.private_zone != true
  ]

  zone_exists = length(local.matched_zone_ids) > 0
  zone_id     = local.zone_exists ? local.matched_zone_ids[0] : aws_route53_zone.this[0].zone_id
}

resource "aws_route53_zone" "this" {
  # checkov:skip=CKV2_AWS_39:Query logging streams every DNS lookup into CloudWatch Logs, billed by ingestion, for a project with no traffic analysis to do. The zone's change history — which is what an audit would ask about — is in CloudTrail.
  # checkov:skip=CKV2_AWS_38:DNSSEC is a deliberate deferral, not an oversight. It needs an asymmetric KMS key with a monthly charge, a DS record lodged manually at the registrar — a fourth irreducibly manual step — and a misconfiguration takes the entire domain offline rather than degrading. Reconsider if this project outlives its 2026-12-18 domain expiry.
  count = local.zone_exists ? 0 : 1

  name    = var.domain_name
  comment = "Managed by Terraform — ${local.name_prefix}"
}
