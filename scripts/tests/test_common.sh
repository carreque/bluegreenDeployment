#!/usr/bin/env bash
#
# lib/common.sh's Phase 10 additions: the layer map, the two rank vocabularies,
# and the marker read and write.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

source "$HERE/lib.sh"
source "$ROOT/scripts/lib/common.sh"

# Recomputed through repo_root() now that common.sh is loaded, and not merely
# tidier: repo_root asks git, which on Windows answers C:/Users/... , while
# cd+pwd under Git Bash answers /c/Users/... . Every assertion below compares a
# path this library BUILT from repo_root against one this file spells out, so
# deriving both the same way is what makes the comparison about the layer map
# rather than about path syntax. On Linux and macOS the two forms are identical
# and this line changes nothing.
ROOT="$(repo_root)"

# --- layer_dir ---------------------------------------------------------------
#
# The map lived in three scripts and was about to live in a fourth. tf.sh's own
# comment asked for this. Plan §D13.

check "layer_dir foundation"   "$ROOT/infra/foundation"           "$(layer_dir foundation)"
check "layer_dir bootstrap"    "$ROOT/infra/bootstrap"            "$(layer_dir bootstrap)"
check "layer_dir network"      "$ROOT/infra/network"              "$(layer_dir network)"

# Both environments, one directory, since the 2026-09-02 merge. This pair of
# assertions is the whole contract change: a layer name identified a directory
# before it and identifies a directory PLUS a var file PLUS a backend key now.
check "layer_dir staging is the merged root" "$ROOT/infra" "$(layer_dir staging)"
check "layer_dir prod is the merged root"    "$ROOT/infra" "$(layer_dir prod)"

run_capture layer_dir nonsense
check          "layer_dir refuses an unknown layer"          "1" "$STATUS"
check_contains "…and names what it expected"  "expected bootstrap, foundation, network, staging or prod" "$OUTPUT"

# --- layer_dir_rel -----------------------------------------------------------
#
# The same map, relative to the repository root. Added because layer_dir's
# absolute answer was the wrong shape for three callers and they each open-coded
# the map instead: pipeline-terraform.sh twice (two byte-identical case blocks
# 57 lines apart) and pipeline-deploy.sh twice more. Those paths are printed in
# operator-facing messages — "no saved plan at infra/…" — so
# an absolute path there would name a CodeBuild container's scratch directory
# rather than a path the reader can act on.

check "layer_dir_rel foundation" "infra/foundation"           "$(layer_dir_rel foundation)"
check "layer_dir_rel bootstrap"  "infra/bootstrap"            "$(layer_dir_rel bootstrap)"
check "layer_dir_rel network"    "infra/network"              "$(layer_dir_rel network)"
check "layer_dir_rel staging"    "infra"                     "$(layer_dir_rel staging)"
check "layer_dir_rel prod"       "infra"                     "$(layer_dir_rel prod)"

# The refusal has to survive the extra layer of command substitution: layer_dir
# die()s in a subshell, and a wrapper that swallowed that status would hand the
# caller an empty path instead of stopping.
run_capture layer_dir_rel nonsense
check          "layer_dir_rel refuses an unknown layer"       "1" "$STATUS"
check_contains "…and names what it expected"  "expected bootstrap, foundation, network, staging or prod" "$OUTPUT"

# Never absolute, and never with a leading slash — the whole reason it exists.
check_contains "layer_dir_rel is relative" "infra/" "$(layer_dir_rel foundation)"
run_capture eval '[[ "$(layer_dir_rel prod)" != /* ]]'
check "layer_dir_rel does not return an absolute path" "0" "$STATUS"

# --- the map has exactly one home --------------------------------------------
#
# The regression test for the claim in pipeline-deploy.sh's header, which
# asserted this property while the file carried three copies of the map. A
# comment nobody checks is how a property gets lost.
#
# lib/common.sh is where the map lives. lint-infra.sh keeps layer_path, a
# deliberate variant whose contract differs — it returns a path relative to
# infra/ and passes an already-relative path through unchanged (Phase 10 §F6).
# Every other script must go through layer_dir or layer_dir_rel.
offenders="$(grep -rl 'infra/\$\|infra/environments/\$' "$ROOT/scripts" \
  --exclude-dir=tests --exclude=common.sh --exclude=lint-infra.sh 2>/dev/null || true)"
check "no script open-codes the layer-to-directory map" "" "${offenders//$ROOT\//}"

# --- the other half of a layer's identity ------------------------------------
#
# staging and prod are one directory now, so layer_dir alone can no longer tell
# an apply which environment it is. These two are what does, and they are
# checked together with layer_dir because the three must agree: initialising
# prod's backend and then applying staging's variables is a valid sequence of
# commands and a catastrophic one, and tf.sh deriving all three from one
# argument is the only thing preventing it.

check "layer_var_file staging" "$ROOT/infra/environments/staging.tfvars" "$(layer_var_file staging)"
check "layer_var_file prod"    "$ROOT/infra/environments/prod.tfvars"    "$(layer_var_file prod)"

check "layer_backend_config staging" "$ROOT/infra/environments/staging.backend.hcl" "$(layer_backend_config staging)"
check "layer_backend_config prod"    "$ROOT/infra/environments/prod.backend.hcl"    "$(layer_backend_config prod)"

# The three single-environment layers keep their literal backend blocks and have
# no environment to select, so both helpers print nothing. Callers treat empty
# as "pass no flag" — an error here would make tf.sh need two code paths.
check "layer_var_file is empty for foundation"       "" "$(layer_var_file foundation)"
check "layer_var_file is empty for network"          "" "$(layer_var_file network)"
check "layer_backend_config is empty for bootstrap"  "" "$(layer_backend_config bootstrap)"

run_capture layer_var_file nonsense
check "layer_var_file refuses an unknown layer" "1" "$STATUS"
run_capture layer_backend_config nonsense
check "layer_backend_config refuses an unknown layer" "1" "$STATUS"

# The files the two helpers name must actually be there. A path helper that
# returns a plausible name for a file nobody created is the failure this whole
# refactor could most easily introduce, and it would surface as a terraform
# error several layers away from the cause.
for _env in staging prod; do
  check "environments/$_env.tfvars exists"      "yes" "$([[ -f "$(layer_var_file "$_env")" ]] && echo yes || echo no)"
  check "environments/$_env.backend.hcl exists" "yes" "$([[ -f "$(layer_backend_config "$_env")" ]] && echo yes || echo no)"
done

# The two backend files must name DIFFERENT state keys. Identical keys would
# point both environments at one state file, and the first apply of the second
# environment would plan the destruction of the first.
check "the two environments use different state keys" "2" \
  "$(grep -h '^key' "$(layer_backend_config staging)" "$(layer_backend_config prod)" | sort -u | wc -l | tr -d ' ')"

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
