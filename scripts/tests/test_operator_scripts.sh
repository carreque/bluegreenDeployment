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

# --- rebuild -----------------------------------------------------------------

REBUILD="$ROOT/scripts/rebuild.sh"

run_capture env SCOPE=sideways "$REBUILD"
check          "an unrecognised SCOPE is fatal"  "1" "$STATUS"
check_contains "…listing the three it accepts"   "expected one of network, staging, prod" "$OUTPUT"

# foundation is not a rebuild target: it survived the teardown, by construction.
run_capture env SCOPE=foundation "$REBUILD"
check "SCOPE=foundation is refused" "1" "$STATUS"

# Every case below runs with BGD_REBUILD_DRY_RUN=1, which stops AFTER the
# preconditions and before the first apply. That is what lets the suite exercise
# all six preconditions without terraform ever being invoked — and it is why
# the flag stops where it does rather than before them.
export FAKE_SSM_IMAGE_TAG=1.0.0-abc1234

run_capture env SCOPE=network BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check          "a dry run exits 0"                     "0" "$STATUS"
check_contains "…listing what it would apply"          "network" "$OUTPUT"
check_contains "…and the marker value it would record" "/bgd/platform/deployed_scope = network" "$OUTPUT"
check_contains "…having actually checked something"    "preconditions pass" "$OUTPUT"

run_capture env SCOPE=prod BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check_contains "the default applies network first"  "network" "$OUTPUT"
check_contains "…then staging"                      "staging" "$OUTPUT"
check_contains "…then prod"                         "prod"    "$OUTPUT"
check_contains "…finishing at the marker value all" "/bgd/platform/deployed_scope = all" "$OUTPUT"

# The account check is first, because a rebuild into the wrong account is not
# recoverable by re-running it. Plan §D10.
export FAKE_ACCOUNT_ID=111122223333
run_capture env SCOPE=network BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check          "a wrong account is fatal"     "1" "$STATUS"
check_contains "…naming both account numbers" "111122223333" "$OUTPUT"
unset FAKE_ACCOUNT_ID

export FAKE_S3_MISSING=1
run_capture env SCOPE=network BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check          "an unreachable state bucket is fatal" "1" "$STATUS"
check_contains "…and names it"  "bgd-us-east-1-tfstate" "$OUTPUT"
unset FAKE_S3_MISSING

# An unset image tag is caught before the NAT gateway exists, not at the
# staging layer after it does. Plan §D10.
export FAKE_SSM_IMAGE_TAG=unset
run_capture env SCOPE=staging BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check          "an unset image tag is fatal" "1" "$STATUS"
check_contains "…and says how to set it"     "make seed-ecr" "$OUTPUT"
export FAKE_SSM_IMAGE_TAG=1.0.0-abc1234

# The check that moves the failure from after the NAT gateway to before it.
export FAKE_ECR_MISSING=1
run_capture env SCOPE=staging BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check          "a tag that is not in ECR is fatal"   "1" "$STATUS"
check_contains "…and says why it is caught here"     "after the network already exists and is billing" "$OUTPUT"
unset FAKE_ECR_MISSING

# SCOPE=network needs no image tag at all — there is no container in that layer,
# so an absent parameter must not stop a network-only rebuild.
export FAKE_SSM_IMAGE_TAG=""
run_capture env SCOPE=network BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check "SCOPE=network needs no image tag" "0" "$STATUS"
unset FAKE_SSM_IMAGE_TAG

report
