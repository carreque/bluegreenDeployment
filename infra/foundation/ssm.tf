# Which image tag each environment layer deploys.
#
# The two environment layers declare image_tag with no default, deliberately —
# a stale default would silently deploy an old image (Phase 5 §D3). Locally the
# value comes from terraform.tfvars, which .gitignore excludes, so a CodeBuild
# workspace has no value at all and `terraform plan -input=false` fails before
# it authenticates to anything. Plan §F7.
#
# Keeping it here rather than in the environment layers is what makes the infra
# pipeline image-preserving: an infra/** merge plans with the tag already
# recorded, so it cannot change what is running. Design §1.5's separation —
# Terraform owns the service shape, the app pipeline owns images — enforced by
# mechanism rather than by convention. Plan §D8.
#
# In foundation rather than in an environment layer for the second reason too:
# `make teardown` destroys prod, staging and network, and a Phase 10 rebuild has
# to plan against the tag that was deployed before the teardown.

resource "aws_ssm_parameter" "image_tag" {
  # checkov:skip=CKV2_AWS_34:SecureString for a value that is printed in every build log, every task definition and every /version response. Encrypting it would imply it is a secret, and the two places that read it — scripts/pipeline-terraform.sh and the app pipeline — would need a KMS grant to read a container image tag. Plan §F9.
  for_each = toset(local.image_tag_environments)

  name = "/bgd/${each.key}/image_tag"
  type = "String"

  # `unset` rather than a plausible-looking tag. scripts/pipeline-terraform.sh
  # refuses this value by name and says to run `make seed-ecr`, which is a
  # better failure than passing a tag that was never pushed to
  # data.aws_ecr_image and failing one layer deeper.
  value = "unset"

  description = "ECR tag the ${each.key} layer deploys. Written by scripts/seed-ecr.sh and, from Phase 8, by the application pipeline."

  lifecycle {
    # The whole point. seed-ecr.sh and Phase 8 write this value; without
    # ignore_changes the next foundation apply reverts it to "unset" and the
    # following environment apply deploys whatever that resolves to. Both
    # applies succeed, which is what makes it worth a lifecycle block rather
    # than a comment.
    ignore_changes = [value]
  }
}

# ---------------------------------------------------------------------------
# Phase 10 — how deep the platform is currently applied
# ---------------------------------------------------------------------------
#
# One of foundation | network | staging | all — the same four values
# DEPLOY_SCOPE uses, deliberately. pipeline-terraform.sh already ranks them and
# locals.tf's pipeline_layers already orders them; a second vocabulary for the
# same idea would be a second thing to keep in step. Plan §D2.
#
# Written ONLY by scripts/teardown.sh and scripts/rebuild.sh, and read by both
# pipeline drivers, which clamp their own scope to it. What that buys is a merge
# to main after a teardown that validates, applies this layer, builds and pushes
# an image — and creates no network, no ALB and no Fargate task. What it costs
# is that a merge can no longer rebuild a torn-down layer: `make rebuild` is the
# only thing that raises this value. That is the point rather than a side
# effect. Plan §D5.
#
# In THIS layer because it has to survive what it describes. Anywhere else and
# the record of "the platform is torn down" is destroyed by the teardown — the
# same argument image_tag above makes, and the same one Phase 9's D2 makes for
# the whole observability plane.
#
# `platform` occupies the position `staging` and `prod` occupy in the two
# parameters above, and is deliberately not an environment: it names the whole
# thing.

resource "aws_ssm_parameter" "deployed_scope" {
  # checkov:skip=CKV2_AWS_34:SecureString for a value printed in every pipeline skip message and read by two pipeline roles. Encrypting it would imply it is a secret and cost both roles a KMS grant to read the word "staging". Same trade as image_tag above.
  name = "/bgd/platform/deployed_scope"
  type = "String"

  # `all`, not the more literally-honest `foundation`, and the difference is
  # what happens on a fresh account. Layers are applied in order and this one is
  # first; a marker defaulting to `foundation` would clamp `network` on an
  # account nobody had ever torn down, and every runbook from Phase 4 onward
  # would need a step it does not have. Defaulting to `all` means the marker
  # only ever RESTRICTS, and only after somebody explicitly ran teardown.
  # Plan §D4.
  value = "all"

  description = "How deep the platform is currently applied: foundation, network, staging or all. Written by scripts/teardown.sh and scripts/rebuild.sh; read by both pipeline drivers, which clamp their scope to it."

  lifecycle {
    # The whole point, and the same reason image_tag carries it. Without this
    # the next foundation apply resets the marker to `all` and the following
    # merge deploys into a torn-down account — with both applies green.
    ignore_changes = [value]
  }
}
