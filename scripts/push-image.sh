#!/usr/bin/env bash
#
# Push the built image into ECR and prove the digest survived the trip.
#
#   scripts/push-image.sh
#
# Factored out of scripts/seed-ecr.sh in Phase 8, unchanged in behaviour. The
# application pipeline's build needs exactly this — the skopeo copy, the
# already-pushed check and the digest assertion — and must NOT write the two
# SSM parameters seed-ecr.sh writes, because those record what *is* deployed
# and are written after a successful apply (Phase 8 plan §D9). A second copy of
# the skopeo invocation in a build script would put two measured arguments in
# two places, where one can be fixed and the other forgotten.
#
# skopeo copies the OCI archive byte-for-byte, so the manifest digest ECR
# stores is the digest app/dist/image-digest.txt already names. `docker push`
# of the daemon's copy is not equivalent: the daemon holds a re-imported
# convenience copy, and a push may re-encode it into a digest that matches
# nothing recorded anywhere. See the Phase 3 plan §D6.
#
# The repository URL comes from $BGD_ECR_REPOSITORY_URL when set and from the
# foundation outputs otherwise — the same override shape scripts/smoke.sh has
# carried since Phase 5, and it is what lets a CodeBuild build push without a
# state backend.
#
# Writes app/dist/pushed.env holding IMAGE_TAG and IMAGE_DIGEST, on both the
# pushed and the already-pushed paths, so a caller reads the two values rather
# than deriving them a second time.
#
# Pinned 2026-08-24, quay.io/skopeo/stable:v1.20.0. Re-record with:
#   docker buildx imagetools inspect quay.io/skopeo/stable:v1.20.0 --format '{{.Manifest.Digest}}'

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker
require_cmd aws

ROOT="$(repo_root)"
DIST="$ROOT/app/dist"
SKOPEO="quay.io/skopeo/stable@sha256:47853bb9fb24202af9110531ebd6e43c5f97701254ca290596640290d17942f4"

REGION="${AWS_REGION:-us-east-1}"

# The makefile exports AWS_PROFILE for every local target and deliberately does
# NOT inside CodeBuild (Phase 7 §F6), where credentials come from the build
# project's service role and no such profile exists anywhere. This mirrors that
# rule rather than re-deciding it. seed-ecr.sh passed --profile unconditionally,
# which was correct while it only ever ran on a laptop and would have failed
# every call in the pipeline with "The config profile could not be found" — a
# credentials-shaped error with a profile-shaped cause. Phase 8 §F14.
if [[ -n "${CODEBUILD_BUILD_ID:-}" ]]; then
  AWS_ARGS=(--region "$REGION")
else
  AWS_ARGS=(--profile "${AWS_PROFILE:-bootcamp-administrator-access}" --region "$REGION")
fi

[[ -f "$DIST/image.oci.tar" ]] || die "no image archive — run 'make build' first"
[[ -f "$DIST/image-digest.txt" ]] || die "no recorded digest — run 'make build' first"
[[ -f "$DIST/image-ref.txt" ]] || die "no recorded image ref — run 'make build' first"

LOCAL_DIGEST="$(cat "$DIST/image-digest.txt")"
LOCAL_REF="$(cat "$DIST/image-ref.txt")"
TAG="${LOCAL_REF##*:}"

# A -dirty tag names a tree that is not any commit. Pushing one would put an
# unreproducible artifact in the registry every later phase deploys from, and
# ECR's tag immutability means it could never be corrected in place.
#
# Unreachable in the pipeline, where the workspace is a clone of a commit and
# is never dirty — which is the right place for a guard that costs nothing.
if [[ "$TAG" == *-dirty ]]; then
  die "refusing to push a dirty build ($TAG) — commit the tree and rebuild"
fi

# Terraform is required only where it is used, not unconditionally — the same
# placement, and the same reason, as scripts/smoke.sh. A CodeBuild build that
# supplies this value directly has no state backend to read and legitimately no
# terraform binary; requiring one would fail that caller for nothing.
REPO_URL="${BGD_ECR_REPOSITORY_URL:-}"
if [[ -z "$REPO_URL" ]]; then
  require_cmd terraform
  REPO_URL="$(terraform -chdir="$ROOT/infra/foundation" output -raw ecr_repository_url 2>/dev/null)" ||
    die "cannot read the foundation outputs — apply the foundation layer first, or set BGD_ECR_REPOSITORY_URL"
fi

REPO_NAME="${REPO_URL##*/}"
DEST="${REPO_URL}:${TAG}"

# Both values, for the caller. seed-ecr.sh sources this to record the two SSM
# parameters and pipeline-app-build.sh sources it to export IMAGE_TAG and
# IMAGE_DIGEST to the later stages. %q so a caller can `set -a && . pushed.env`
# safely, matching plan-vars.env.
record_pushed() {
  {
    printf 'IMAGE_TAG=%q\n' "$TAG"
    printf 'IMAGE_DIGEST=%q\n' "$1"
  } >"$DIST/pushed.env"
}

info "pushing $DEST"
dim "  local digest  $LOCAL_DIGEST"

# ECR tags are immutable, so a second push of the same tag is an error rather
# than a no-op. If the tag is already there with the digest we hold, the push
# has already happened and this is a success, not a failure.
#
# Two pipeline runs on the same commit differ only in CODEBUILD_BUILD_NUMBER,
# so they produce different tags and — by Phase 2's measurement — the identical
# manifest digest. This check queries by TAG, finds nothing for the new one and
# pushes; ECR adds a tag to the existing manifest and uploads no layers. Plan §F6.
existing="$(aws ecr describe-images \
  "${AWS_ARGS[@]}" \
  --repository-name "$REPO_NAME" \
  --image-ids "imageTag=$TAG" \
  --query 'imageDetails[0].imageDigest' \
  --output text 2>/dev/null || true)"

if [[ -n "$existing" && "$existing" != "None" ]]; then
  if [[ "$existing" == "$LOCAL_DIGEST" ]]; then
    ok "already pushed — $TAG is $existing"
    record_pushed "$existing"
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
DEST_PASSWORD="$(aws ecr get-login-password "${AWS_ARGS[@]}")"

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
  "${AWS_ARGS[@]}" \
  --repository-name "$REPO_NAME" \
  --image-ids "imageTag=$TAG" \
  --query 'imageDetails[0].imageDigest' \
  --output text)"

# The whole reason for using skopeo rather than docker push is that this holds.
# Asserting it turns the claim into a check.
[[ "$pushed" == "$LOCAL_DIGEST" ]] ||
  die "digest mismatch — ECR holds $pushed, the artifact of record is $LOCAL_DIGEST"

record_pushed "$pushed"

ok "pushed $DEST"
dim "  digest  $pushed"
