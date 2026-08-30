#!/usr/bin/env bash
#
# The three operator scripts' guards: scope parsing, the confirmation, the
# order in which the marker is written, and the preconditions.
#
# Nothing here runs a destroy or an apply — every case exits at a guard. What
# an offline suite can prove is that the guards are right; that a real cycle
# works is the runbook's job, and is why the runbook exists. Plan §D1.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

source "$HERE/lib.sh"

export PATH="$HERE/fake-bin:$PATH"
export FAKE_SSM_DEPLOYED_SCOPE=all

TEARDOWN="$ROOT/scripts/teardown.sh"

# --- scope parsing -----------------------------------------------------------

run_capture env SCOPE=sideways "$TEARDOWN"
check          "an unrecognised SCOPE is fatal"  "1" "$STATUS"
check_contains "…listing the three it accepts"   "expected one of prod, staging, network" "$OUTPUT"

# There is no value that reaches foundation. The five-layer split exists so the
# certificate, the images, the artifact history, the pipelines and the
# CodeConnections authorisation survive a routine command. Plan §D16.
run_capture env SCOPE=foundation "$TEARDOWN"
check          "SCOPE=foundation is refused"     "1" "$STATUS"
check_contains "…as an unrecognised value"       "expected one of prod, staging, network" "$OUTPUT"

run_capture env SCOPE=bootstrap "$TEARDOWN"
check "SCOPE=bootstrap is refused" "1" "$STATUS"

# --- the confirmation --------------------------------------------------------

# The marker assertions name the whole line, not just the value: "network"
# appears in the survivor sentence too, so a bare substring would pass on the
# wrong half of the output.
run_capture env SCOPE=prod BGD_TEARDOWN_DRY_RUN=1 "$TEARDOWN"
check          "a dry run exits 0 without destroying"     "0" "$STATUS"
check_contains "…listing the layer it would destroy"      "prod" "$OUTPUT"
check_contains "…naming what survives"                    "foundation and bootstrap are never destroyed" "$OUTPUT"
check_contains "…and the marker value it would write"     "/bgd/platform/deployed_scope = staging" "$OUTPUT"

run_capture env SCOPE=staging BGD_TEARDOWN_DRY_RUN=1 "$TEARDOWN"
check_contains "SCOPE=staging destroys prod first"      "prod" "$OUTPUT"
check_contains "…then staging"                          "staging" "$OUTPUT"
check_contains "…and would leave the marker at network" "/bgd/platform/deployed_scope = network" "$OUTPUT"

run_capture env SCOPE=network BGD_TEARDOWN_DRY_RUN=1 "$TEARDOWN"
check_contains "the default scope would leave the marker at foundation" "/bgd/platform/deployed_scope = foundation" "$OUTPUT"

# A confirmation that is not the word `destroy` aborts, and aborts BEFORE the
# marker is written — otherwise declining the prompt would still tell both
# pipelines the platform is down.
FAKE_AWS_LOG="$(mktemp)"
export FAKE_AWS_LOG
run_capture env SCOPE=prod "$TEARDOWN" <<<"yes"
check "a confirmation other than the word destroy aborts" "1" "$STATUS"
check "…and writes no marker" "" "$(grep -o put-parameter "$FAKE_AWS_LOG" || true)"
rm -f "$FAKE_AWS_LOG"
unset FAKE_AWS_LOG

# --- verify-idle -------------------------------------------------------------

IDLE="$ROOT/scripts/verify-idle.sh"

run_capture env SCOPE=sideways "$IDLE"
check          "an unrecognised SCOPE is fatal"  "1" "$STATUS"
check_contains "…listing the three it accepts"   "expected one of prod, staging, network" "$OUTPUT"

# The script must never read a state file: state is exactly what is wrong in
# the three cases it exists for — a resource created by hand, a drifted state,
# and a destroy that failed part-way. Plan §D9.
check "verify-idle opens no state file" "" \
  "$(grep -n 'terraform_remote_state\|terraform output\|state list\|\.tfstate' "$IDLE" || true)"

check "verify-idle requires the AWS CLI" "0" \
  "$(if grep -q 'require_cmd aws' "$IDLE"; then echo 0; else echo 1; fi)"

# The four ephemeral services are the ones in which this project owns nothing
# that survives a full teardown, which is what makes the rule expressible
# without an allowlist of the fourteen kinds of thing that do. Plan §D9.
for service in ec2 elasticloadbalancing ecs dynamodb; do
  check "the sweep covers $service" "0" \
    "$(if grep -q "$service" "$IDLE"; then echo 0; else echo 1; fi)"
done

report
