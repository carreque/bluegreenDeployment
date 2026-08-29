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
