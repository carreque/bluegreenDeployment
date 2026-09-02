# The mocks the six PIPELINE and OBSERVABILITY suites need.
#
# Loaded by `mock_provider "aws" { source = "./tests/mocks" }` in
# app_pipeline_iam, app_pipeline_shape, dashboard, observability, pipeline_iam
# and pipeline_shape. The path is relative to the ROOT MODULE, not the test file.
#
# Hoisted on 2026-09-03. Those six carried a byte-identical copy of this block.
#
# THREE of this layer's nine suites deliberately do not use it, and that is the
# reason this file is scoped to a named six rather than to the directory:
#
#   zone_and_certificate  mocks aws_route53_zone and aws_route53_zones, and
#                         deliberately does NOT mock aws_acm_certificate —
#                         because the certificate is the thing it asserts about.
#                         Giving it a fixed certificate ARN from here would not
#                         fail; it would make its assertions pass vacuously,
#                         which is worse.
#
#   naming_and_tags       mock nothing at all, on purpose. Both assert on names
#   registry_and_artifacts  and tags, which are arguments rather than computed
#                         attributes, so there is nothing a mock would supply.
#
# Unioning all three sets into one file would have saved another ten lines and
# cost the first of those properties. Not worth it.
#
# What is NOT here: `variables`, `override_data` and `override_resource`, all of
# which are test-file scoped. Terraform parses an override_data inside a
# .tfmock.hcl without complaint and then IGNORES it — measured 2026-09-03 — so
# moving those would silently stop overriding and the suite would reach the real
# backend.

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
