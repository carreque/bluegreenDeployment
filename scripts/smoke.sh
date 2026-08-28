#!/usr/bin/env bash
#
# Smoke test one environment over TLS.
#
#   scripts/smoke.sh <staging|prod>
#
# Asserts four things, in order of what they rule out:
#
#   1. /health answers 200 over TLS          the ALB, the certificate, the
#                                            target group and the task are all up
#   2. /ready answers 200                    the task role, the security groups
#                                            and the DynamoDB gateway endpoint
#                                            are all correct
#   3. /version answers 200
#   4. /version's image_digest equals the     the image Terraform intended is the
#      digest Terraform deployed              image actually serving traffic
#
# The fourth is the one that makes this a deployment check rather than a
# liveness check, and it is why Phase 8 runs this exact script after deploying
# to staging rather than inventing a smoke stage of its own.
#
# The URL and digest come from Terraform outputs by default. Both can be
# overridden by environment variable so Phase 8's CodeBuild can pass them
# directly rather than needing the state backend:
#
#   BGD_SMOKE_URL=https://…  BGD_SMOKE_DIGEST=sha256:…  scripts/smoke.sh staging

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd curl
require_cmd jq

ROOT="$(repo_root)"

env_name="${1:-}"
case "$env_name" in
  staging | prod) ;;
  *) die "usage: smoke.sh <staging|prod>" ;;
esac

layer_dir="$ROOT/infra/environments/$env_name"
[[ -d "$layer_dir" ]] || die "layer '$env_name' has no directory yet"

# Read both values from Terraform unless the caller supplied them. terraform
# output is used directly rather than through tf.sh, matching seed-ecr.sh: this
# reads state, it does not run a Terraform command against the layer.
BASE_URL="${BGD_SMOKE_URL:-}"
EXPECTED_DIGEST="${BGD_SMOKE_DIGEST:-}"

if [[ -z "$BASE_URL" ]]; then
  BASE_URL="$(terraform -chdir="$layer_dir" output -raw api_url 2>/dev/null)" ||
    die "cannot read the $env_name outputs — apply the layer first, or set BGD_SMOKE_URL"
fi

if [[ -z "$EXPECTED_DIGEST" ]]; then
  EXPECTED_DIGEST="$(terraform -chdir="$layer_dir" output -raw image_digest 2>/dev/null)" ||
    die "cannot read the $env_name image digest — apply the layer first, or set BGD_SMOKE_DIGEST"
fi

echo
info "smoke — $env_name"
dim "  url     $BASE_URL"
dim "  digest  $EXPECTED_DIGEST"
echo

failures=0

# --max-time 40, not the conventional 10. Measured: when DynamoDB is
# unreachable, /ready takes 25.6 seconds to return its 503, because botocore
# retries with backoff before giving up. A 10-second timeout would report a
# connection failure and hide the 503 that names the actual cause — on exactly
# the misconfiguration this check exists to catch. See the Phase 5 plan §F5.
#
# --fail is deliberately NOT used: a non-2xx body is the most useful thing on
# the screen when this fails, and --fail discards it.
probe() {
  local path="$1" expected="$2" timeout="$3" body status
  body="$(curl --silent --show-error --max-time "$timeout" \
    --write-out '\n%{http_code}' "$BASE_URL$path" 2>&1)" || {
    printf '  %-10s ' "$path"
    mark_fail "no response within ${timeout}s"
    failures=$((failures + 1))
    return
  }

  status="${body##*$'\n'}"
  body="${body%$'\n'*}"

  printf '  %-10s ' "$path"
  if [[ "$status" == "$expected" ]]; then
    mark_ok
    LAST_BODY="$body"
  else
    mark_fail "HTTP $status (expected $expected)"
    dim "    $body"
    failures=$((failures + 1))
    LAST_BODY=""
  fi
}

LAST_BODY=""

probe /health 200 10
probe /ready 200 40
probe /version 200 10

# The assertion that makes this a deployment check. LAST_BODY holds /version's
# response, because it was the last probe to succeed.
printf '  %-10s ' "digest"
if [[ -z "$LAST_BODY" ]]; then
  mark_fail "no /version response to check"
  failures=$((failures + 1))
else
  reported="$(printf '%s' "$LAST_BODY" | jq -r '.image_digest')"
  if [[ "$reported" == "$EXPECTED_DIGEST" ]]; then
    mark_ok
  elif [[ "$reported" == "unknown" ]]; then
    mark_fail "/version reports 'unknown' — BGD_IMAGE_DIGEST is missing from the task definition"
    failures=$((failures + 1))
  else
    mark_fail "serving $reported, Terraform deployed $EXPECTED_DIGEST"
    failures=$((failures + 1))
  fi
fi

echo
if ((failures > 0)); then
  die "$failures smoke check(s) failed against $env_name"
fi
ok "$env_name is serving $EXPECTED_DIGEST"
