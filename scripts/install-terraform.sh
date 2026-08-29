#!/usr/bin/env bash
#
# Install the pinned Terraform into a CodeBuild container.
#
# CodeBuild's standard images ship language runtimes, not Terraform. The
# version comes from .terraform-version — the same file tfenv reads on the
# development machine — so the pipeline and that machine cannot drift, which is
# the property a `hashicorp/terraform` image would lose by putting the version
# in a second place. Plan §D14.
#
# The checksum is pinned here beside the version. Re-record both together with:
#
#   curl -sS https://releases.hashicorp.com/terraform/<version>/terraform_<version>_SHA256SUMS \
#     | grep linux_amd64
#
# linux_amd64 because all three infra CodeBuild projects are LINUX_CONTAINER
# (plan §D7). Phase 8's app build is ARM and does not use this script.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd curl
require_cmd unzip
require_cmd sha256sum

ROOT="$(repo_root)"

VERSION="$(tr -d '[:space:]' <"$ROOT/.terraform-version")"

# Pinned 2026-08-29 for 1.15.7. A version bump that does not bump this line
# fails the checksum rather than installing something unverified.
EXPECTED_SHA256="73bbb8f5188ad75d4fb853fd100ae4d7e146ef7af7db18776109642fdb7759d2"

ZIP="terraform_${VERSION}_linux_amd64.zip"
URL="https://releases.hashicorp.com/terraform/${VERSION}/${ZIP}"
DEST="${TERRAFORM_INSTALL_DIR:-/usr/local/bin}"

# Idempotent: CodeBuild caches nothing between actions, but a local run of this
# script for debugging should not re-download.
if command -v terraform >/dev/null 2>&1 &&
  [[ "$(extract_version "$(terraform version)")" == "$VERSION" ]]; then
  ok "terraform $VERSION already installed"
  exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

info "downloading terraform $VERSION"
curl -fsSL --retry 3 --retry-delay 2 -o "$workdir/$ZIP" "$URL"

actual="$(sha256sum "$workdir/$ZIP" | cut -d' ' -f1)"
[[ "$actual" == "$EXPECTED_SHA256" ]] ||
  die "checksum mismatch for $ZIP — expected $EXPECTED_SHA256, got $actual"

unzip -q -o "$workdir/$ZIP" -d "$workdir"
install -m 0755 "$workdir/terraform" "$DEST/terraform"

ok "terraform $("$DEST/terraform" version | head -1)"
