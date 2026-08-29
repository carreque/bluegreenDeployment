# The three lifecycle hooks ECS invokes during a blue/green deployment.
#
# One handler, three deployments of it. All three do the same job — probe an
# HTTP endpoint and report pass or fail — and differ only in which listener they
# probe and at which stage they run, both of which come from the environment
# below. The alternative, three handler files, would triple the code under test
# to express one behaviour three times. Plan §D2.
#
#   PRE_SCALE_UP                   :443    Rules out starting a deployment into
#                                          an already-broken environment.
#                                          Without it, a failure during the
#                                          deployment is ambiguous: was it the
#                                          new build, or was production already
#                                          down?
#
#   POST_TEST_TRAFFIC_SHIFT        :8443   The dark canary. A green revision
#                                          that starts but cannot reach
#                                          DynamoDB, or serves the wrong image,
#                                          is rejected before one user request
#                                          touches it.
#
#   POST_PRODUCTION_TRAFFIC_SHIFT  :443    Green is now serving real traffic;
#                                          confirm the promotion worked before
#                                          the five-minute bake begins.
#
# The hooks are NOT VPC-attached. The production ALB is internet-facing and
# network already opens :8443 on the prod ALB security group, so they reach both
# listeners over the public internet. Attaching them to the private subnets
# would buy nothing — the endpoints are public either way — and would cost an
# ENI per concurrent execution, an ENI attachment delay on cold start inside a
# synchronous deployment gate, and a NAT dependency for a function whose whole
# job is to run when the deployment is in a fragile state. Plan §D6.

locals {
  # Written out here rather than inline in the three module blocks, so the one
  # difference that actually matters between them — which listener each probes —
  # is three adjacent lines a reviewer can read at once.
  #
  # BGD_EXPECT_DIGEST is deliberately absent from all three. Plan §D12: the
  # runbook sets it by hand for exit criterion 3 and unsets it again, so there
  # is no failure toggle in the committed infrastructure to forget about.
  hook_environments = {
    pre_scale = {
      BGD_STAGE     = "PRE_SCALE_UP"
      BGD_PROBE_URL = "https://${local.foundation.api_domain}"
    }

    post_test = {
      BGD_STAGE = "POST_TEST_TRAFFIC_SHIFT"
      # :8443, and this single line is the dark canary. Pointed at :443 this
      # hook would validate the colour that is already serving and approve every
      # bad build — the worst failure this layer can have, and the reason two
      # tests assert it from opposite ends.
      BGD_PROBE_URL = "https://${local.foundation.api_domain}:8443"
    }

    post_prod = {
      BGD_STAGE     = "POST_PRODUCTION_TRAFFIC_SHIFT"
      BGD_PROBE_URL = "https://${local.foundation.api_domain}"
    }
  }

  # Relative to this layer, which is where terraform test runs from. archive is
  # not mocked, so a wrong path here fails the offline gate loudly rather than
  # at the first invocation of a production deployment gate. Plan §F4.
  hook_source_file = "${path.module}/../../../lambdas/lifecycle_hook/handler.py"
}

module "pre_scale_hook" {
  source = "../../modules/lambda"

  function_name      = local.hook_function_names.pre_scale
  source_file        = local.hook_source_file
  environment        = local.hook_environments.pre_scale
  timeout_seconds    = var.hook_timeout_seconds
  log_retention_days = var.log_retention_days
}

module "post_test_hook" {
  source = "../../modules/lambda"

  function_name      = local.hook_function_names.post_test
  source_file        = local.hook_source_file
  environment        = local.hook_environments.post_test
  timeout_seconds    = var.hook_timeout_seconds
  log_retention_days = var.log_retention_days
}

module "post_prod_hook" {
  source = "../../modules/lambda"

  function_name      = local.hook_function_names.post_prod
  source_file        = local.hook_source_file
  environment        = local.hook_environments.post_prod
  timeout_seconds    = var.hook_timeout_seconds
  log_retention_days = var.log_retention_days
}
