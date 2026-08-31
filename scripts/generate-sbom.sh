#!/usr/bin/env bash
#
# Generate the image's SBOM with syft, per design §4.1.
#
# syft runs from a digest-pinned container rather than a host install: nothing
# to install, nothing for verify-tools.sh to check, and the identical command
# works in Phase 8's CodeBuild.
#
# It reads the OCI archive, not the Docker daemon. That keeps the daemon socket
# out of a third-party container — mounting it would hand that image
# root-equivalent control of this machine — and it describes the artifact of
# record rather than whatever the daemon happens to have tagged.
#
# Pinned 2026-08-12, anchore/syft:v1.51.0. Re-record with:
#   docker buildx imagetools inspect anchore/syft:v1.51.0 --format '{{.Manifest.Digest}}'

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker
require_cmd jq

ROOT="$(repo_root)"
DIST="$ROOT/app/dist"
# ghcr.io, not Docker Hub, and the digest is UNCHANGED — same bytes, different
# registry. Moved 2026-08-31 for the reason lint-infra.sh's CHECKOV records:
# Docker Hub rate-limits unauthenticated pulls per IP, and CodeBuild shares a NAT
# address with every other AWS customer. This one had not failed yet; it runs in
# the application pipeline's Build stage and would have, eventually, on a
# deployment rather than on a lint.
SYFT="ghcr.io/anchore/syft@sha256:678bfa565b60f747aac0f8e964fe5588a24445b8d0a480e91f6efd70020dfbb0"
OUTPUT="$DIST/sbom.spdx.json"

[[ -f "$DIST/image.oci.tar" ]] || die "no image archive — run 'make build' first"

info "generating the SBOM with syft"
docker run --rm \
  --volume "$DIST:/work:ro" \
  "$SYFT" \
  "oci-archive:/work/image.oci.tar" \
  --output spdx-json >"$OUTPUT"

# jq rather than grep: syft emits compact JSON, so any pattern assuming
# pretty-printed keys silently counts zero and reports an empty SBOM as a
# successful one.
count="$(jq '.packages | length' "$OUTPUT")"
[[ "$count" -gt 0 ]] || die "syft produced an SBOM with no packages"

ok "SBOM written — $count packages"
dim "  ${OUTPUT#"$ROOT"/}"
dim "  image digest $(cat "$DIST/image-digest.txt" 2>/dev/null || echo unknown)"
