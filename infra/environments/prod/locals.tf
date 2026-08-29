# Unlike network, this layer reads remote state — it consumes real ARNs and ids
# that cannot be reconstructed from the naming convention. See the plan's D2.
# What it deliberately does NOT read is name_prefix and common_tags: foundation
# exports both, but its common_tags says environment = "shared" and this layer
# is prod. Derived strings are rebuilt locally; only real identifiers cross
# the layer boundary.
data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "foundation/terraform.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "network/terraform.tfstate"
    region = var.region
  }
}

# Resolves a tag to the digest ECR actually holds. The task definition then
# deploys the digest, so there is exactly one identifier for "what is running"
# and /version cannot disagree with it. Plan §D3.
#
# This is NOT the one data source in the layer that reaches AWS at plan
# time — the two terraform_remote_state blocks above read the S3 backend at
# plan time as well. The distinction that actually matters is narrower: this
# is the only data source that reaches an AWS *service* API rather than the
# state backend, and correspondingly the only one whose failure means "the
# image you asked for is not in the registry" rather than "state could not be
# read." It fails loudly when var.image_tag is not in the registry — which is
# better than applying a task definition ECS cannot pull.
data "aws_ecr_image" "api" {
  repository_name = local.ecr_repository_name
  image_tag       = var.image_tag
}

locals {
  environment = "prod"
  env_prefix  = "${var.project_name}-${var.region}-${local.environment}"

  common_tags = {
    environment = local.environment
    projectName = var.project_name
    region      = var.region
    owner       = var.owner
  }

  foundation = data.terraform_remote_state.foundation.outputs
  network    = data.terraform_remote_state.network.outputs

  # Derived from the URL rather than rebuilt from the convention, so this layer
  # and foundation cannot disagree about which repository is meant.
  ecr_repository_url  = local.foundation.ecr_repository_url
  ecr_repository_name = split("/", local.ecr_repository_url)[1]

  # The name the ALB target group and the service's load_balancer block both
  # reference. A mismatch between the two is an apply-time error with a message
  # that does not name this as the cause, so it is written once.
  container_name = "api"

  # Read from network rather than restated, so the security group rules opened
  # there and the port declared here cannot drift. network exports it for
  # exactly this reason.
  container_port = local.network.container_port

  image_reference = "${local.ecr_repository_url}@${data.aws_ecr_image.api.image_digest}"

  # Slashes, not hyphens — the one deliberate deviation in the naming
  # convention (§3). The console builds its navigation tree from the hierarchy.
  log_group_name = "/${var.project_name}/${var.region}/${local.environment}/api"

  # The three hook function names, in one place, because three separate things
  # depend on them agreeing: hooks.tf names the functions, iam.tf builds the
  # invoke role's resource list from them, and outputs.tf publishes them so the
  # runbook can tail the right log groups.
  #
  # iam.tf composes ARNs from these rather than reading module.*.function_arn,
  # and that is a testing decision as much as a graph one. mock_provider fills
  # every aws_lambda_function.arn with the same string, so a policy built from
  # the module outputs cannot be asserted to name three *distinct* functions —
  # the assertion that a wildcard has not crept in would pass vacuously. Names
  # are real strings under mocks. tests/bluegreen.tftest.hcl closes the loop by
  # asserting each module's own function_name equals the entry here, so the
  # composed ARN cannot drift from the function it is meant to permit.
  hook_function_names = {
    pre_scale = "${local.env_prefix}-pre-scale-hook"
    post_test = "${local.env_prefix}-post-test-hook"
    post_prod = "${local.env_prefix}-post-prod-hook"
  }

  hook_function_arns = {
    for key, name in local.hook_function_names :
    key => "arn:aws:lambda:${var.region}:${var.account_id}:function:${name}"
  }
}
