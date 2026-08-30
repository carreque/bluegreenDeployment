#!/usr/bin/env bash
#
# lib/common.sh's Phase 10 additions: the layer map, the two rank vocabularies,
# and the marker read and write.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

source "$HERE/lib.sh"
source "$ROOT/scripts/lib/common.sh"

# --- layer_dir ---------------------------------------------------------------
#
# The map lived in three scripts and was about to live in a fourth. tf.sh's own
# comment asked for this. Plan §D13.

check "layer_dir foundation"   "$ROOT/infra/foundation"           "$(layer_dir foundation)"
check "layer_dir bootstrap"    "$ROOT/infra/bootstrap"            "$(layer_dir bootstrap)"
check "layer_dir network"      "$ROOT/infra/network"              "$(layer_dir network)"
check "layer_dir staging"      "$ROOT/infra/environments/staging" "$(layer_dir staging)"
check "layer_dir prod"         "$ROOT/infra/environments/prod"    "$(layer_dir prod)"

run_capture layer_dir nonsense
check          "layer_dir refuses an unknown layer"          "1" "$STATUS"
check_contains "…and names what it expected"  "expected bootstrap, foundation, network, staging or prod" "$OUTPUT"

report
