#!/usr/bin/env bash
#
# Build the application image reproducibly and record what was built.
#
# The artifact of record is the OCI archive, not the image in the local Docker
# daemon. Only the OCI exporter honours rewrite-timestamp; the docker exporter
# accepts the option and ignores it, producing a different digest every time
# (Phase 2 §F1). The daemon copy exists so `make run-image` and the image test
# suite have something to run, and it is a convenience, not the artifact.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker
require_cmd git
require_cmd jq

ROOT="$(repo_root)"
APP="$ROOT/app"
DIST="$APP/dist"
BUILDER="bgd-repro"
PLATFORM="linux/arm64"

# Sets APP_VERSION, GIT_SHA, BUILT_AT, IMAGE_REF and exports SOURCE_DATE_EPOCH.
# Shared with verify-image-repeatability.sh so the two cannot derive a tag
# differently — see lib/common.sh.
image_build_identity

[[ "$GIT_SHA" == *-dirty ]] && warn "working tree is dirty — tagging as ${GIT_SHA}"

# The docker-container driver is required, not preferred: the default driver's
# exporter ignores rewrite-timestamp. Creating it is idempotent, so no runbook
# gains a manual setup step.
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  info "creating the $BUILDER buildx builder"
  docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null
fi

mkdir -p "$DIST"

info "building $IMAGE_REF"
dim "  platform           $PLATFORM"
dim "  release colour     $RELEASE_COLOR"
dim "  SOURCE_DATE_EPOCH  $SOURCE_DATE_EPOCH ($BUILT_AT)"

# Two exporters, one build. The OCI archive is the artifact; the docker export
# loads the same content into the daemon for running and testing.
#
# --provenance=false: a provenance attestation records build-time metadata and
# turns the output into an index carrying an extra unknown/unknown manifest.
# Neither is wanted here.
docker buildx build \
  --builder "$BUILDER" \
  --platform "$PLATFORM" \
  --no-cache \
  --provenance=false \
  --build-arg "APP_VERSION=$APP_VERSION" \
  --build-arg "GIT_SHA=$GIT_SHA" \
  --build-arg "BUILT_AT=$BUILT_AT" \
  --build-arg "RELEASE_COLOR=$RELEASE_COLOR" \
  --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
  --output "type=oci,dest=$DIST/image.oci.tar,rewrite-timestamp=true,name=$IMAGE_REF" \
  --output "type=docker,name=$IMAGE_REF" \
  "$APP"

# From inside $DIST, by a relative name. GNU tar reads a colon in an archive
# path as host:file and tries to reach that host — so an absolute Windows
# path like C:/… fails with "Cannot connect to C: resolve failed". The GNU
# answer is --force-local, but bsdtar on macOS has no such flag; a relative
# path has no colon to misread and needs nothing from either tar.
DIGEST="$(cd "$DIST" && tar -xOf image.oci.tar index.json | jq -r '.manifests[0].digest')"

# The build ran --no-cache, so what BuildKit just cached will never be read,
# and this build has just orphaned the previous one's image layers.
prune_repro_cache
prune_orphaned_images

printf '%s\n' "$DIGEST" >"$DIST/image-digest.txt"
printf '%s\n' "$IMAGE_REF" >"$DIST/image-ref.txt"

ok "built $IMAGE_REF"
dim "  digest    $DIGEST"
dim "  archive   ${DIST#"$ROOT"/}/image.oci.tar"
