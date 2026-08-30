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

# --- the two rank vocabularies -----------------------------------------------
#
# Named platform_* and NOT scope_rank, because pipeline-deploy.sh already
# defines scope_rank over a DIFFERENT vocabulary (build/staging/all) and bash
# redefines a function without complaint. Plan §F7.

check "scope rank: foundation" "1" "$(platform_scope_rank foundation)"
check "scope rank: network"    "2" "$(platform_scope_rank network)"
check "scope rank: staging"    "3" "$(platform_scope_rank staging)"
check "scope rank: all"        "4" "$(platform_scope_rank all)"
check "scope rank: unknown ranks 0, below every layer" "0" "$(platform_scope_rank prod)"

check "layer rank: foundation" "1"  "$(platform_layer_rank foundation)"
check "layer rank: network"    "2"  "$(platform_layer_rank network)"
check "layer rank: staging"    "3"  "$(platform_layer_rank staging)"
check "layer rank: prod"       "4"  "$(platform_layer_rank prod)"
check "layer rank: unknown ranks 99, above every scope" "99" "$(platform_layer_rank all)"

check "min_rank takes the smaller" "2" "$(min_rank 2 4)"
check "min_rank is symmetric"      "2" "$(min_rank 4 2)"
check "min_rank of equals"         "3" "$(min_rank 3 3)"

# The property the clamp rests on: foundation is in scope under every valid
# marker value, so the layer that CREATES the marker can always be applied.
# Plan §D6.
for marker in foundation network staging all; do
  check "foundation is in scope when the marker is $marker" \
    "yes" \
    "$(if (($(platform_layer_rank foundation) <= $(min_rank "$(platform_scope_rank all)" "$(platform_scope_rank "$marker")"))); then echo yes; else echo no; fi)"
done

# --- the marker --------------------------------------------------------------

export PATH="$HERE/fake-bin:$PATH"

check "the parameter name is the one foundation creates" \
  "/bgd/platform/deployed_scope" "$DEPLOYED_SCOPE_PARAM"

FAKE_SSM_DEPLOYED_SCOPE=staging
export FAKE_SSM_DEPLOYED_SCOPE
check "read_deployed_scope returns the value" "staging" "$(read_deployed_scope)"

FAKE_SSM_DEPLOYED_SCOPE=nonsense
run_capture read_deployed_scope
check          "read_deployed_scope refuses a value outside the vocabulary" "1" "$STATUS"
check_contains "…and names the four it accepts" "expected one of foundation, network, staging, all" "$OUTPUT"

# A missing parameter is a hard failure, never an assumed `all`. A gate that
# fails open is not a gate. Plan §D6.
FAKE_SSM_DEPLOYED_SCOPE=""
run_capture read_deployed_scope
check          "a missing parameter is fatal, not assumed" "1" "$STATUS"
check_contains "…and says to apply foundation" "apply the foundation layer" "$OUTPUT"

# write_deployed_scope READS first, so a put-parameter --overwrite cannot create
# a parameter outside Terraform's state. Plan §F5.
FAKE_SSM_DEPLOYED_SCOPE=""
run_capture write_deployed_scope network
check          "write refuses when the parameter does not exist" "1" "$STATUS"
check_contains "…for the reason --overwrite would otherwise create it" "apply the foundation layer" "$OUTPUT"

FAKE_SSM_DEPLOYED_SCOPE=all
run_capture write_deployed_scope sideways
check          "write refuses a value outside the vocabulary" "1" "$STATUS"
check_contains "…and names it" "refusing to write 'sideways'" "$OUTPUT"

FAKE_AWS_LOG="$(mktemp)"
export FAKE_AWS_LOG
FAKE_SSM_DEPLOYED_SCOPE=all
run_capture write_deployed_scope foundation
check "write succeeds on a valid value" "0" "$STATUS"
check_contains "…and calls put-parameter with it" "put-parameter" "$(cat "$FAKE_AWS_LOG")"
check_contains "…carrying the new value" "foundation" "$(cat "$FAKE_AWS_LOG")"
rm -f "$FAKE_AWS_LOG"
unset FAKE_AWS_LOG

report
