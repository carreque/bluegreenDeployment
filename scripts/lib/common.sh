#!/usr/bin/env bash
# Shared helpers for this repository's scripts.
# Source this file; do not execute it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

set -euo pipefail

# Colour only when stdout is a terminal, so piped and CodeBuild output stay clean.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_DIM=$'\033[2m'
else
  C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_DIM=''
fi

info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$*"; }
dim() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

die() {
  fail "$*"
  exit 1
}

# Inline status marks, for the last column of a table row. Unlike ok()/fail()
# these emit no leading padding and no trailing space.
mark_ok() { printf '%s✓%s\n' "$C_GREEN" "$C_RESET"; }
mark_fail() { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET"; }
mark_warn() { printf '%s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# repo_root — absolute path to the repository root, wherever the script is called from.
repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
  }
}

# extract_version <string> — first dotted numeric version found in the string.
# Handles "git version 2.50.1 (Apple Git-155)", "Terraform v1.15.7",
# "aws-cli/2.35.4 Python/3.14.5", "jq-1.7.1", "GNU Make 3.81".
#
# Always succeeds, returning the empty string when nothing matches. Callers run
# under `set -euo pipefail`, where a bare failing grep inside a command
# substitution would abort the script instead of reporting a missing version.
extract_version() {
  printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true
}

# try <command...> — run a command, capture its first line of output, and
# never propagate a non-zero exit. For probing tools that report information
# through a failure, such as `pyenv version` on an uninstalled pin.
try() {
  "$@" 2>&1 | head -1 || true
}

# version_gte <have> <want> — true when have >= want.
# Uses a numeric field sort rather than `sort -V`, which BSD sort on macOS
# does not reliably provide.
version_gte() {
  local have="$1" want="$2" lowest
  [[ "$have" == "$want" ]] && return 0
  lowest="$(printf '%s\n%s\n' "$have" "$want" |
    sort -t. -k1,1n -k2,2n -k3,3n | head -1)"
  [[ "$lowest" == "$want" ]]
}

# ---------------------------------------------------------------------------
# Phase 2 — image build identity
# ---------------------------------------------------------------------------

# image_build_identity — set the variables that identify an image build.
#
# Sets APP_VERSION, GIT_SHA, BUILT_AT, IMAGE_REF and exports SOURCE_DATE_EPOCH.
#
# This lives here rather than in build-image.sh because verify-image-repeatability.sh
# needs the identical derivation: if the two computed a tag differently — say one
# applied the -dirty suffix and the other did not — the repeatability check would
# prove a property of an image nobody ships. Phase 8's buildspec reads the same
# VERSION file for the same reason.
#
# Both timestamps come from the last commit rather than the wall clock, which is
# what makes the digest a function of the source. git does the formatting because
# BSD date and GNU date disagree about rendering an epoch, and this runs on macOS
# locally and Linux in CI.
# prune_repro_cache — discard the bgd-repro builder's BuildKit cache.
#
# Every build in this repository runs --no-cache, because an artifact of record
# should not be assembled from layers built at some other time. That makes the
# cache the builder writes pure dead weight: never read, but still consuming the
# Docker Desktop VM disk at roughly a gigabyte per build until it fills and
# builds start failing with "no space left on device".
#
# Only ever prunes the bgd-repro builder, never the default one, so nothing
# outside this project is touched.
prune_repro_cache() {
  docker buildx prune --all --force --builder bgd-repro >/dev/null 2>&1 || true
}

# prune_orphaned_images — drop images this project has orphaned.
#
# Each build loads a new image under the same tag, which untags the previous one
# and leaves its layers behind as a dangling image of roughly 220 MB. Twenty
# builds is four gigabytes, and the Docker Desktop VM disk fills silently until
# builds start failing with "no space left on device" — which is a confusing way
# to discover it, because the error names a COPY line rather than a full disk.
#
# Filtered on the image's own label, so it can only ever match images built from
# this repository's Dockerfile. A bare `docker image prune` would also discard
# unrelated dangling images belonging to whatever else is on the machine.
#
# Deleting a child exposes its parent as newly dangling, so this iterates rather
# than assuming one pass suffices.
prune_orphaned_images() {
  local pass
  for pass in 1 2 3 4 5; do
    docker image prune --force \
      --filter "label=org.opencontainers.image.title=bgd-api" >/dev/null 2>&1 || true
  done
}

image_build_identity() {
  local root major_minor
  root="$(repo_root)"

  major_minor="$(tr -d '[:space:]' <"$root/app/VERSION")"
  APP_VERSION="${major_minor}.${CODEBUILD_BUILD_NUMBER:-0}"

  GIT_SHA="$(git -C "$root" rev-parse --short=7 HEAD)"
  if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
    GIT_SHA="${GIT_SHA}-dirty"
  fi

  SOURCE_DATE_EPOCH="$(git -C "$root" log -1 --format=%ct)"
  BUILT_AT="$(TZ=UTC git -C "$root" log -1 \
    --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format=%cd)"
  IMAGE_REF="bgd-us-east-1-api:${APP_VERSION}-${GIT_SHA}"

  export SOURCE_DATE_EPOCH
}
