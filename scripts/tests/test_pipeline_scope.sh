#!/usr/bin/env bash
#
# Both pipeline drivers' scope handling: their own scope variable, the marker
# clamp, and the difference between the two skip messages.
#
# Every case here exits before terraform is invoked, which is what lets the
# suite run with no AWS session and no state backend. A case that reached
# terraform would be testing terraform.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

source "$HERE/lib.sh"

export PATH="$HERE/fake-bin:$PATH"

TF="$ROOT/scripts/pipeline-terraform.sh"

# --- the marker clamp --------------------------------------------------------
#
# A merge to main while the platform is torn down must SKIP the layers that do
# not exist, green, and say why in words that are true. Plan §D5.

export DEPLOY_SCOPE=all
export FAKE_SSM_DEPLOYED_SCOPE=foundation

run_capture "$TF" plan network
check          "a torn-down network skips green"      "0" "$STATUS"
check_contains "…saying it is torn down"              "is torn down" "$OUTPUT"
check_contains "…naming the marker and its value"     "/bgd/platform/deployed_scope = foundation" "$OUTPUT"
check_contains "…and how to bring it back"            "make rebuild" "$OUTPUT"

run_capture "$TF" plan prod
check "a torn-down prod skips green too" "0" "$STATUS"

# The message must NOT blame DEPLOY_SCOPE, which is fine. An operator reading
# "outside DEPLOY_SCOPE=all" would go looking for a bug in scope handling.
check "the clamp does not blame the scope" \
  "" \
  "$(printf '%s' "$OUTPUT" | grep -o 'outside DEPLOY_SCOPE' || true)"

# foundation is exempt: it is the layer that CREATES the marker, so on a fresh
# account the parameter does not exist when it is first planned. Plan §D6.
#
# Exercised through `apply` rather than `plan`, deliberately. An exempt layer
# proceeds PAST the gates, and `plan foundation` would then run terraform — the
# one thing this suite must not do. `apply` stops at the missing saved-plan
# check, which sits immediately after the gates and before any terraform call,
# so the exemption is proved behaviourally and nothing is planned.
export FAKE_SSM_DEPLOYED_SCOPE=""
run_capture "$TF" apply foundation
check          "foundation never reads the marker" "1" "$STATUS"
check_contains "…it stops at the missing plan file, not at the marker" "no saved plan" "$OUTPUT"

# A marker that cannot be read is fatal for every layer above foundation. A gate
# that fails open is not a gate. Plan §D6.
export FAKE_SSM_DEPLOYED_SCOPE=""
run_capture "$TF" plan staging
check          "an unreadable marker is fatal above foundation" "1" "$STATUS"
check_contains "…and says which layer creates it" "apply the foundation layer" "$OUTPUT"

# --- DEPLOY_SCOPE itself, unchanged by this phase ----------------------------
#
# Phase 7's matrix, re-run against the clamped script. The marker is `all`
# throughout, so anything that skips here skips because of DEPLOY_SCOPE.

export FAKE_SSM_DEPLOYED_SCOPE=all

export DEPLOY_SCOPE=network
run_capture "$TF" plan staging
check          "DEPLOY_SCOPE=network still skips staging" "0" "$STATUS"
check_contains "…blaming the scope, not the marker" "outside DEPLOY_SCOPE=network" "$OUTPUT"

run_capture "$TF" plan prod
check "DEPLOY_SCOPE=network still skips prod" "0" "$STATUS"

unset DEPLOY_SCOPE
run_capture "$TF" plan network
check          "an unset DEPLOY_SCOPE is still fatal" "1" "$STATUS"
check_contains "…naming the override the action must pass" "EnvironmentVariables override" "$OUTPUT"

export DEPLOY_SCOPE=sideways
run_capture "$TF" plan network
check          "an unrecognised DEPLOY_SCOPE is still fatal" "1" "$STATUS"
check_contains "…listing the four it accepts" "expected one of foundation, network, staging, all" "$OUTPUT"

export DEPLOY_SCOPE=all
run_capture "$TF" plan nonsense
check          "an unknown layer is still fatal" "1" "$STATUS"
check_contains "…and named"  "unknown layer: nonsense" "$OUTPUT"

# --- the same clamp, over APP_SCOPE's vocabulary -----------------------------

DEPLOY="$ROOT/scripts/pipeline-deploy.sh"

export APP_SCOPE=all
export IMAGE_TAG=1.0.0-abc1234
export FAKE_SSM_DEPLOYED_SCOPE=network

run_capture "$DEPLOY" deploy staging
check          "a torn-down staging skips green"  "0" "$STATUS"
check_contains "…saying it is torn down"          "is torn down" "$OUTPUT"
check_contains "…and how to bring it back"        "make rebuild" "$OUTPUT"

# The skip must still write deploy-vars.env, or pipelines/app-deploy.yml fails
# sourcing a file that is not there — turning a correct skip into a red stage.
check "the skip still writes the deploy vars file" "0" \
  "$(if [[ -f "$ROOT/deploy-vars.env" ]]; then echo 0; else echo 1; fi)"
rm -f "$ROOT/deploy-vars.env"

export FAKE_SSM_DEPLOYED_SCOPE=staging
run_capture "$DEPLOY" plan prod
check          "staging deployed but prod torn down skips prod" "0" "$STATUS"
check_contains "…blaming the marker"  "is torn down" "$OUTPUT"
rm -f "$ROOT/plan-vars.env"

# …and with the same marker, staging is IN scope, so the run proceeds past the
# gate. Exercised through `apply` for the reason the foundation case above is:
# an in-scope `deploy` would run terraform, and `apply` stops at the missing
# saved-plan check immediately after the gates.
run_capture "$DEPLOY" apply staging
check          "staging is not skipped when the marker says staging" "" \
  "$(printf '%s' "$OUTPUT" | grep -o 'is torn down' || true)"
check_contains "…it stops at the missing plan file instead" "no saved plan" "$OUTPUT"

export FAKE_SSM_DEPLOYED_SCOPE=""
run_capture "$DEPLOY" deploy staging
check          "an unreadable marker is fatal here too" "1" "$STATUS"
check_contains "…and says which layer creates it" "apply the foundation layer" "$OUTPUT"

# APP_SCOPE itself, unchanged: Phase 8's behaviour asserted against the clamped
# script, with the marker at `all` so nothing skips because of it.
export FAKE_SSM_DEPLOYED_SCOPE=all
export APP_SCOPE=build
run_capture "$DEPLOY" deploy staging
check          "APP_SCOPE=build still skips staging" "0" "$STATUS"
check_contains "…blaming the scope, not the marker" "outside APP_SCOPE=build" "$OUTPUT"
rm -f "$ROOT/deploy-vars.env"

export APP_SCOPE=staging
run_capture "$DEPLOY" plan prod
check          "APP_SCOPE=staging still skips prod" "0" "$STATUS"
check_contains "…blaming the scope"  "outside APP_SCOPE=staging" "$OUTPUT"
rm -f "$ROOT/plan-vars.env"

unset APP_SCOPE
run_capture "$DEPLOY" deploy staging
check "an unset APP_SCOPE is still fatal" "1" "$STATUS"

export APP_SCOPE=all
run_capture "$DEPLOY" deploy nonsense
check          "an unknown environment is still fatal" "1" "$STATUS"
check_contains "…and named" "unknown environment: nonsense" "$OUTPUT"

report
