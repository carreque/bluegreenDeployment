#!/usr/bin/env bash
#
# Static analysis for infra/, from digest-pinned containers.
#
# Nothing is installed on the host — the precedent generate-sbom.sh set for
# syft, for the same three reasons: there is no version for verify-tools.sh to
# drift against, the pin is a digest like every other dependency here, and the
# identical command works in Phase 7's CodeBuild.
#
# Pinned 2026-08-24. Re-record with:
#   docker buildx imagetools inspect <tag> --format '{{.Manifest.Digest}}'
#
#   tflint   ghcr.io/terraform-linters/tflint:v0.60.0
#   checkov  bridgecrew/checkov:3.3.13

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker

ROOT="$(repo_root)"
INFRA="$ROOT/infra"
PLUGINS="$INFRA/.tflint.d"

# Layer names to paths, relative to infra/. The makefile's TF_LAYERS passes bare
# names — bootstrap, foundation, network, staging, prod — while the discovery
# branch below already yields relative paths, so both forms must work.
#
# staging and prod live one level deeper, at infra/environments/<layer>. Its
# absence here was invisible until Phase 5 put a layer below infra/ for the first
# time: tflint failed with "chdir staging: no such file or directory" the moment
# staging entered TF_LAYERS. checkov was never affected — it scans infra/ whole.
#
# Phase 10 moved that shared map into lib/common.sh as layer_dir(), and this
# function is deliberately NOT it: layer_dir returns an ABSOLUTE path, while
# docker's -w needs one relative to infra/ — and this has to pass an
# already-relative path through unchanged, because the discovery branch below
# yields those. Plan §D13 and §F6.
layer_path() {
  case "$1" in
    staging | prod) echo "environments/$1" ;;
    *) echo "$1" ;;
  esac
}

TFLINT="ghcr.io/terraform-linters/tflint@sha256:cef181224b4a9cea521d8f785d50957ea3215b449e2d97e7793f222e2808d188"
# ghcr.io, not Docker Hub, and the digest is UNCHANGED — ghcr.io/bridgecrewio/checkov:3.3.13
# and bridgecrew/checkov:3.3.13 are the same bytes, so this swaps the registry
# without swapping the artifact.
#
# Docker Hub rate-limits unauthenticated pulls per source IP. Same shape as the
# tflint ruleset problem above and the same reason it is invisible locally: a
# laptop has its own budget, while CodeBuild pulls from a shared AWS NAT address
# whose allowance belongs to every AWS customer behind it. Observed 2026-08-31,
# on the run that came directly after the tflint fix:
#
#   docker: Error response from daemon: toomanyrequests:
#   You have reached your unauthenticated pull rate limit.
#
# ghcr.io applies no anonymous pull limit, which is why the tflint image beside
# this one had already been pulling cleanly all along.
CHECKOV="ghcr.io/bridgecrewio/checkov@sha256:c5fb7154bed784fc19a69779c308fddba564f19a37c25d306c0e9765c4f0aa1d"

# Layers come from the caller — the makefile passes $(TF_LAYERS), which is the
# single source of truth. With no arguments they are discovered from the tree,
# so a layer added in Phase 4, 5 or 6 is linted whether or not anyone remembers
# to update a list here. A hard-coded list in two files is a list that drifts,
# and the failure mode is a layer that is silently never scanned.
#
# .terraform/ is excluded: it holds downloaded module sources, which are not
# this repository's code to lint.
if (($# > 0)); then
  LAYERS=("$@")
else
  LAYERS=()
  while IFS= read -r dir; do
    LAYERS+=("${dir#"$INFRA/"}")
  done < <(find "$INFRA" -name '*.tf' -not -path '*/.terraform/*' \
    -exec dirname {} \; | sort -u)
fi

((${#LAYERS[@]} > 0)) || die "no Terraform layers found under ${INFRA#"$ROOT"/}"

mkdir -p "$PLUGINS"

tflint_run() {
  docker run --rm \
    --volume "$INFRA:/data" \
    --volume "$PLUGINS:/plugins" \
    --env TFLINT_PLUGIN_DIR=/plugins \
    "$TFLINT" "$@"
}

# ---------------------------------------------------------------------------
# The AWS ruleset, installed WITHOUT `tflint --init`.
#
# The tflint image ships no rulesets, so one has to be fetched. `--init` is the
# obvious way and is what this script used until 2026-08-31 — but it resolves
# the release through **api.github.com**, which allows 60 unauthenticated
# requests per hour PER SOURCE IP.
#
# On a laptop that budget is private and $PLUGINS persists between runs, so the
# call is made once and never again. In CodeBuild both halves of that are
# false: the workspace is fresh on every build, so `--init` runs every time,
# and the source IP is a shared AWS NAT address whose 60 requests belong to
# every AWS customer sitting behind it. The result is a 403 at random —
#
#   Failed to fetch GitHub releases: 403 API rate limit exceeded for
#   34.228.4.223 (rate reset in 25m20s)
#
# — which fails Validate, and therefore the whole infra pipeline, for a reason
# that has nothing to do with the code being linted. Observed on the first real
# pipeline run; see docs/phases/phase7/2026-08-31-tflint-ruleset-install.md.
#
# Release ASSETS are served by a CDN and carry no such limit, so the asset is
# downloaded directly and placed where tflint looks for it. tflint then finds an
# installed plugin and makes no network call at all — which also means the lint
# runs fully offline once the plugin is present, on the laptop and in CodeBuild
# alike. A GITHUB_TOKEN would also have fixed it, and was rejected: it is a
# secret to store and rotate, and creating it is a fourth irreducibly manual
# step in a project whose documents claim there are exactly three.
#
# The version is read from .tflint.hcl rather than repeated here — that file is
# what tflint enforces, so a second copy could disagree with it. The checksums
# cannot be derived, so they are pinned, and the guard below refuses a version
# they were not recorded for rather than letting the mismatch surface as a
# confusing checksum failure.
#
# Re-record both lines together with:
#   curl -sS https://github.com/terraform-linters/tflint-ruleset-aws/releases/download/v<version>/checksums.txt
# ---------------------------------------------------------------------------

require_cmd curl
require_cmd unzip

# macOS ships shasum, Linux ships sha256sum, and this script runs on both.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

RULESET_VERSION="$(sed -n '/plugin "aws"/,/^}/s/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' \
  "$INFRA/.tflint.hcl" | head -1)"
[[ -n "$RULESET_VERSION" ]] ||
  die "could not read the aws ruleset version from infra/.tflint.hcl"

CHECKSUMS_RECORDED_FOR="0.44.0"
[[ "$RULESET_VERSION" == "$CHECKSUMS_RECORDED_FOR" ]] ||
  die "infra/.tflint.hcl pins aws ruleset $RULESET_VERSION but the checksums here were recorded for $CHECKSUMS_RECORDED_FOR — re-record them together"

PLUGIN_DIR="$PLUGINS/github.com/terraform-linters/tflint-ruleset-aws/$RULESET_VERSION"
PLUGIN_BIN="$PLUGIN_DIR/tflint-ruleset-aws"

if [[ -x "$PLUGIN_BIN" ]]; then
  ok "aws ruleset $RULESET_VERSION already installed"
else
  # The plugin is a native binary run BY the container, so it must match the
  # container's architecture, not the host's. Those differ routinely here:
  # Docker Desktop on Apple silicon runs this image as arm64 while CodeBuild's
  # LINUX_CONTAINER is amd64 (Phase 7 §D7). Asking the image itself is the only
  # answer that is right in both places.
  container_arch="$(docker run --rm --entrypoint uname "$TFLINT" -m | tr -d '[:space:]')"
  case "$container_arch" in
    x86_64 | amd64)
      asset="linux_amd64"
      expected_sha256="2257966e97ef08fd55ef460b054ed46aa8b7196b094e15edeb45ac8f7213df2d"
      ;;
    aarch64 | arm64)
      asset="linux_arm64"
      expected_sha256="bc595e871fd1df0c7cba1efb73e16aaaebb623b290ecfcc64af0f22cc42d1ff3"
      ;;
    *) die "unsupported tflint container architecture '$container_arch'" ;;
  esac

  info "tflint — installing the aws ruleset $RULESET_VERSION ($asset)"

  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' EXIT

  curl -fsSL --retry 3 --retry-delay 2 -o "$workdir/ruleset.zip" \
    "https://github.com/terraform-linters/tflint-ruleset-aws/releases/download/v${RULESET_VERSION}/tflint-ruleset-aws_${asset}.zip"

  unzip -q -o "$workdir/ruleset.zip" -d "$workdir"

  actual_sha256="$(sha256_of "$workdir/tflint-ruleset-aws")"
  [[ "$actual_sha256" == "$expected_sha256" ]] ||
    die "checksum mismatch for tflint-ruleset-aws_${asset} — expected $expected_sha256, got $actual_sha256"

  mkdir -p "$PLUGIN_DIR"
  install -m 0755 "$workdir/tflint-ruleset-aws" "$PLUGIN_BIN"
  ok "aws ruleset $RULESET_VERSION installed"
fi

failures=0

for layer in "${LAYERS[@]}"; do
  path="$(layer_path "$layer")"
  info "tflint — $layer"
  if tflint_run --chdir="$path" --format=compact; then
    ok "$layer clean"
  else
    failures=$((failures + 1))
  fi
done

# --quiet suppresses the per-check passed list; --compact drops the code
# snippets. Together they leave findings and nothing else, which is what makes
# the output readable when there are none.
info "checkov — infra/"
if docker run --rm --volume "$INFRA:/infra:ro" "$CHECKOV" \
  --directory /infra \
  --framework terraform \
  --quiet --compact; then
  ok "checkov clean"
else
  failures=$((failures + 1))
fi

echo
if ((failures > 0)); then
  die "$failures static analysis check(s) failed."
fi
ok "static analysis passed"
