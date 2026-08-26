# One certificate covering both environments' hostnames, DNS-validated in the
# zone above. It lives in foundation rather than beside the load balancers
# because it must survive a teardown: re-issuing on every rebuild would make
# the certificate a rebuild cost and put it in the critical path of Phase 10.

resource "aws_acm_certificate" "api" {
  domain_name               = local.api_domain
  subject_alternative_names = [local.staging_api_domain]
  validation_method         = "DNS"

  # A certificate is replaced, not updated, when its names change. Without this
  # the old one is destroyed first — and it is still attached to two live ALB
  # listeners at that moment.
  lifecycle {
    create_before_destroy = true
  }
}

# for_each over the certificate's own domain_validation_options would be the
# obvious form, but that attribute is unknown until the certificate exists, and
# an unknown for_each is a plan-time error. Keying on the two hostnames — which
# are known from variables — lets the plan expand, with the record values filled
# in during apply.
resource "aws_route53_record" "certificate_validation" {
  for_each = toset([local.api_domain, local.staging_api_domain])

  zone_id = local.zone_id
  ttl     = 60

  name = one([
    for option in aws_acm_certificate.api.domain_validation_options :
    option.resource_record_name if option.domain_name == each.value
  ])

  type = one([
    for option in aws_acm_certificate.api.domain_validation_options :
    option.resource_record_type if option.domain_name == each.value
  ])

  records = [
    one([
      for option in aws_acm_certificate.api.domain_validation_options :
      option.resource_record_value if option.domain_name == each.value
    ])
  ]

  # ACM reuses a validation CNAME across certificates for the same name, so a
  # re-issue can produce a record that already exists. Without this, that is a
  # hard failure on a record whose value is identical to the one being written.
  allow_overwrite = true
}

# Not a resource in AWS — a wait. It blocks the apply until ACM reports the
# certificate ISSUED, so no later phase can attach a listener to a certificate
# that is still PENDING_VALIDATION.
#
# Gated on wait_for_validation because on the zone-create path the validation
# CNAME is not publicly resolvable until the registrar's name servers are
# repointed, and this would hang for its 75-minute default before failing.
resource "aws_acm_certificate_validation" "api" {
  count = var.wait_for_validation ? 1 : 0

  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]
}
