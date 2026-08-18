#!/usr/bin/env bash
#
# Prove that the same source produces the same image.
#
# Two clean builds, identical inputs, compared on the manifest digest — the
# identifier ECR stores and ECS deploys against, not a local image ID. Both
# builds use the same tag, because the tag appears in the OCI index annotations
# and a differing name would show up as a difference that is not image content.
#
# --no-cache on both, or the second build would return the first one's layers
# and prove only that the cache works.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker
require_cmd git
require_cmd jq

ROOT="$(repo_root)"
APP="$ROOT/app"
WORK="$APP/dist/repeatability"
BUILDER="bgd-repro"

# The identical derivation build-image.sh uses. Sharing it is the point: if the
# two computed the tag differently, this would prove a property of an image
# nobody ships.
image_build_identity

if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null
fi

rm -rf "$WORK"
mkdir -p "$WORK"

build_once() {
  local label="$1"
  info "build $label of 2" >&2
  docker buildx build \
    --builder "$BUILDER" \
    --platform linux/arm64 \
    --no-cache \
    --provenance=false \
    --build-arg "APP_VERSION=$APP_VERSION" \
    --build-arg "GIT_SHA=$GIT_SHA" \
    --build-arg "BUILT_AT=$BUILT_AT" \
    --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
    --output "type=oci,dest=$WORK/$label.tar,rewrite-timestamp=true,name=$IMAGE_REF" \
    "$APP" >/dev/null 2>&1
  tar -xOf "$WORK/$label.tar" index.json | jq -r '.manifests[0].digest'
}

first="$(build_once one)"
second="$(build_once two)"

# Two uncached builds is the heaviest thing this repository does to the Docker
# Desktop disk, and none of what they cached will ever be read again.
prune_repro_cache

printf '\n'
dim "  build 1  $first"
dim "  build 2  $second"
printf '\n'

if [[ "$first" == "$second" ]]; then
  ok "reproducible — both builds produced the same manifest digest"
  rm -rf "$WORK"
  exit 0
fi

fail "NOT reproducible — the two builds differ"
dim "  the archives are kept in ${WORK#"$ROOT"/} for diagnosis:"
dim "    tar -xf $WORK/one.tar -C <dir> && tar -xf $WORK/two.tar -C <dir2> && diff -r <dir> <dir2>"
exit 1
