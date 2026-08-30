#!/usr/bin/env bash
#
# Push the Phase 2 image into ECR and record it as the tag both environment
# layers deploy. Roadmap §0: seed with the real application image, built
# locally, before the first ECS apply.
#
# The push itself moved to scripts/push-image.sh in Phase 8, unchanged — the
# skopeo copy, the already-pushed check, the -dirty refusal and the digest
# assertion are all there, and the reasoning for each with them. It moved
# because the application pipeline's build needs exactly that and must NOT
# write the two parameters below: they record what *is* deployed, so they are
# written after a successful apply (Phase 8 plan §D9 and §D13).
#
# What is left here is the seeding path's own business: a laptop pushing an
# image and declaring, in the same command, that this is the tag to deploy.
# `make seed-ecr` behaves exactly as it did.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd aws

ROOT="$(repo_root)"
DIST="$ROOT/app/dist"

PROFILE="${AWS_PROFILE:-bootcamp-administrator-access}"
REGION="${AWS_REGION:-us-east-1}"

# Record the tag as the one both environment layers should deploy.
#
# The environment layers declare image_tag with no default and read it from
# terraform.tfvars, which is gitignored — so a CodeBuild workspace has no value
# and the infra pipeline cannot plan staging or prod without this (Phase 7
# §D8). Writing it here rather than in a separate step means the parameter is
# populated by the same command that makes the tag real.
#
# --overwrite because the parameter is created holding "unset" and every
# subsequent seed replaces the previous tag. Terraform ignores changes to the
# value, so this does not create drift.
record_image_tag_parameters() {
  local env
  for env in staging prod; do
    aws ssm put-parameter \
      --profile "$PROFILE" --region "$REGION" \
      --name "/bgd/${env}/image_tag" \
      --value "$IMAGE_TAG" \
      --type String \
      --overwrite >/dev/null
    dim "  /bgd/${env}/image_tag  ->  $IMAGE_TAG"
  done
}

"$ROOT/scripts/push-image.sh"

# Written by push-image.sh on both its paths — the pushed one and the
# already-pushed early exit. Sourced rather than re-derived so the tag recorded
# here cannot disagree with the tag that was pushed.
[[ -f "$DIST/pushed.env" ]] ||
  die "push-image.sh did not write $DIST/pushed.env — nothing to record"

# shellcheck source=/dev/null
. "$DIST/pushed.env"

record_image_tag_parameters

ok "seeded $IMAGE_TAG"
dim "  digest  $IMAGE_DIGEST"
dim "  Phases 5 and 6 set BGD_IMAGE_DIGEST to this value in the task definition,"
dim "  and the infra pipeline plans both environments against /bgd/<env>/image_tag."
