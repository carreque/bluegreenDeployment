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
CHECKOV="bridgecrew/checkov@sha256:c5fb7154bed784fc19a69779c308fddba564f19a37c25d306c0e9765c4f0aa1d"

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

# The tflint image ships no rulesets. Without a mounted plugin directory the AWS
# ruleset is re-downloaded on every invocation, and a network failure then fails
# the lint run rather than the download.
info "tflint — installing rulesets"
tflint_run --init >/dev/null

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
