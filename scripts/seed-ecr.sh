#!/usr/bin/env bash
#
# Push the Phase 2 image into ECR, so the ECS services in Phases 5 and 6 have
# something to run. Roadmap §0: seed with the real application image, built
# locally, before the first ECS apply.
#
# skopeo copies the OCI archive byte-for-byte, so the manifest digest ECR stores
# is the digest app/dist/image-digest.txt already names. `docker push` of the
# daemon's copy is not equivalent: the daemon holds a re-imported convenience
# copy, and a push may re-encode it into a digest that matches nothing recorded
# anywhere. See the Phase 3 plan §D6.
#
# Pinned 2026-08-24, quay.io/skopeo/stable:v1.20.0. Re-record with:
#   docker buildx imagetools inspect quay.io/skopeo/stable:v1.20.0 --format '{{.Manifest.Digest}}'

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker
require_cmd aws
require_cmd terraform

ROOT="$(repo_root)"
DIST="$ROOT/app/dist"
SKOPEO="quay.io/skopeo/stable@sha256:47853bb9fb24202af9110531ebd6e43c5f97701254ca290596640290d17942f4"

PROFILE="${AWS_PROFILE:-bootcamp-administrator-access}"
REGION="${AWS_REGION:-us-east-1}"

[[ -f "$DIST/image.oci.tar" ]] || die "no image archive — run 'make build' first"
[[ -f "$DIST/image-digest.txt" ]] || die "no recorded digest — run 'make build' first"
[[ -f "$DIST/image-ref.txt" ]] || die "no recorded image ref — run 'make build' first"

LOCAL_DIGEST="$(cat "$DIST/image-digest.txt")"
LOCAL_REF="$(cat "$DIST/image-ref.txt")"
TAG="${LOCAL_REF##*:}"

# A -dirty tag names a tree that is not any commit. Seeding one would put an
# unreproducible artifact in the registry every later phase deploys from, and
# ECR's tag immutability means it could never be corrected in place.
if [[ "$TAG" == *-dirty ]]; then
  die "refusing to seed a dirty build ($TAG) — commit the tree and rebuild"
fi

REPO_URL="$(terraform -chdir="$ROOT/infra/foundation" output -raw ecr_repository_url 2>/dev/null)" ||
  die "cannot read the foundation outputs — apply the foundation layer first"
REPO_NAME="${REPO_URL##*/}"
DEST="${REPO_URL}:${TAG}"

info "seeding $DEST"
dim "  local digest  $LOCAL_DIGEST"

# ECR tags are immutable, so a second seed of the same tag is an error rather
# than a no-op. If the tag is already there with the digest we hold, the seed
# has already happened and this is a success, not a failure.
existing="$(aws ecr describe-images \
  --profile "$PROFILE" --region "$REGION" \
  --repository-name "$REPO_NAME" \
  --image-ids "imageTag=$TAG" \
  --query 'imageDetails[0].imageDigest' \
  --output text 2>/dev/null || true)"

if [[ -n "$existing" && "$existing" != "None" ]]; then
  if [[ "$existing" == "$LOCAL_DIGEST" ]]; then
    ok "already seeded — $TAG is $existing"
    exit 0
  fi
  die "tag $TAG already exists with a different digest ($existing); ECR tags are immutable"
fi

# Exported, then passed by NAME ONLY. `--env NAME=value` would put a live ECR
# token into docker's own argv, where `ps` shows it to every user on the machine
# for as long as the push runs — measured, not assumed:
#
#   docker run --env "P=$SECRET"  alpine sleep 8 &   ->  1 match in `ps -Ao args`
#   export P; docker run --env P  alpine sleep 8 &   ->  0 matches
#
# `--env NAME` makes docker read the value from its own environment instead.
export DEST_PASSWORD
DEST_PASSWORD="$(aws ecr get-login-password --profile "$PROFILE" --region "$REGION")"

# The escaped \$DEST_PASSWORD defers expansion to the shell inside the
# container. Unescaped it would expand on the host to the empty string — and
# skopeo would authenticate as "AWS:" and fail with an opaque 401.
docker run --rm \
  --volume "$DIST:/work:ro" \
  --env DEST_PASSWORD \
  --entrypoint sh \
  "$SKOPEO" -c \
  "skopeo copy --dest-creds \"AWS:\$DEST_PASSWORD\" \
     oci-archive:/work/image.oci.tar docker://$DEST"

unset DEST_PASSWORD

pushed="$(aws ecr describe-images \
  --profile "$PROFILE" --region "$REGION" \
  --repository-name "$REPO_NAME" \
  --image-ids "imageTag=$TAG" \
  --query 'imageDetails[0].imageDigest' \
  --output text)"

# The whole reason for using skopeo rather than docker push is that this holds.
# Asserting it turns the claim into a check.
[[ "$pushed" == "$LOCAL_DIGEST" ]] ||
  die "digest mismatch — ECR holds $pushed, the artifact of record is $LOCAL_DIGEST"

ok "seeded $DEST"
dim "  digest  $pushed"
dim "  Phases 5 and 6 set BGD_IMAGE_DIGEST to this value in the task definition."
