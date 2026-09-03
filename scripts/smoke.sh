#!/usr/bin/env bash
#
# Smoke test one environment over TLS.
#
#   scripts/smoke.sh <staging|prod>
#
# Asserts six things, in order of what they rule out:
#
#   1. /health answers 200 over TLS          the ALB, the certificate, the
#                                            target group and the task are all up
#   2. /ready answers 200                    ping() in dynamodb.py is a single
#                                            get_item against the accounts
#                                            table, so this proves only
#                                            dynamodb:GetItem on that one
#                                            table over the gateway endpoint —
#                                            not Query on the LSI, and not the
#                                            write path
#   3. /version answers 200
#   4. /version's image_digest equals the     the image Terraform intended is the
#      digest Terraform deployed              image actually serving traffic
#   5. / answers 200 as text/html             the demonstration page is being
#                                             served by the task itself, which
#                                             is what Phase 12 puts on a screen
#   6. /version's release_color is blue       the image carries a release
#      or green, never slate                  identity; "slate" is the default a
#                                             container reports when the build
#                                             argument never reached it, so a
#                                             deployed slate is a colourless
#                                             demo behind a green pipeline
#
# The fourth is the one that makes this a deployment check rather than a
# liveness check, and it is why Phase 8 runs this exact script after deploying
# to staging rather than inventing a smoke stage of its own. The sixth is the
# same idea applied to Phase 12's build input.
#
# Five and six WARN rather than fail on an image that predates Phase 12, which
# is a different thing from a broken one. Such an image has no release_color at
# all and serves no page, and putting one back is a legitimate operation: a
# rebuild takes its tag from /bgd/<env>/image_tag, the last thing deployed, so
# the first rebuild after Phase 12 merged restores exactly such an image — and
# Phase 11's rollbacks restore them on purpose. Failing there reported a
# correct restore as a broken deploy, and stopped scripts/rebuild.sh before it
# reached prod. "slate" stays a hard failure: that is a Phase 12-aware image
# built without the build argument, which is the defect check 6 exists for.
#
# The URL and digest come from Terraform outputs by default. Both can be
# overridden by environment variable so Phase 8's CodeBuild can pass them
# directly rather than needing the state backend:
#
#   BGD_SMOKE_URL=https://…  BGD_SMOKE_DIGEST=sha256:…  scripts/smoke.sh staging

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd curl
require_cmd jq

# terraform is required only where it is actually used, not unconditionally
# up front like curl and jq. If the caller supplies both BGD_SMOKE_URL and
# BGD_SMOKE_DIGEST, the block below never invokes terraform at all — and a
# later phase's CI is exactly the caller who would do that, passing both
# values directly from a build pipeline that legitimately has no Terraform
# binary installed. Requiring it unconditionally would fail that caller for
# no reason; the require_cmd calls are placed with the terraform invocations
# themselves instead, so the check only fires on the path that needs it.

env_name="${1:-}"
case "$env_name" in
  staging | prod) ;;
  *) die "usage: smoke.sh <staging|prod>" ;;
esac

# layer_dir() rather than the path spelled out, so this cannot drift from
# tf.sh's idea of where a layer lives. The case above has already rejected
# anything but staging and prod, so layer_dir's own refusal is unreachable
# here — it is the shared map that is wanted, not a second gate.
#
# Since the environments merge this resolves to infra/ for BOTH environments,
# which is why the reads below are preceded by layer_init_backend: the directory
# no longer identifies the state.
dir="$(layer_dir "$env_name")"
[[ -d "$dir" ]] || die "layer '$env_name' has no directory yet"

# Read both values from Terraform unless the caller supplied them. terraform
# output is used directly rather than through tf.sh, matching seed-ecr.sh: this
# reads state, it does not run a Terraform command against the layer.
BASE_URL="${BGD_SMOKE_URL:-}"
EXPECTED_DIGEST="${BGD_SMOKE_DIGEST:-}"

# Both reads come from one environment's state, so the backend is configured
# once here rather than inside each branch. Skipped entirely when the caller
# supplied both values — Phase 8's smoke build has no AWS credentials at all and
# must not be made to need them (plan §D6).
if [[ -z "$BASE_URL" || -z "$EXPECTED_DIGEST" ]]; then
  require_cmd terraform
  layer_init_backend "$env_name" 2>/dev/null ||
    die "cannot initialise the $env_name backend — check your AWS session, or set BGD_SMOKE_URL and BGD_SMOKE_DIGEST to skip reading state"
fi

if [[ -z "$BASE_URL" ]]; then
  require_cmd terraform
  BASE_URL="$(terraform -chdir="$dir" output -raw api_url 2>/dev/null)" ||
    die "cannot read the $env_name outputs — apply the layer first, or set BGD_SMOKE_URL"
fi

if [[ -z "$EXPECTED_DIGEST" ]]; then
  require_cmd terraform
  EXPECTED_DIGEST="$(terraform -chdir="$dir" output -raw image_digest 2>/dev/null)" ||
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
    # Both failure branches in this function must clear LAST_BODY, not just
    # the non-2xx one below. The digest check after all three probes reads
    # whatever LAST_BODY holds and assumes it is /version's response; leaving
    # a stale value here means a timed-out /version probe silently reuses
    # /ready's body from the previous probe, and the digest check then fails
    # jq against the wrong JSON with a message that names the wrong cause.
    LAST_BODY=""
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

# ---------------------------------------------------------------------------
# Readiness gate — wait for the environment to answer before judging it.
#
# Found 2026-09-03, on the first from-scratch rebuild. prod's apply returned
# with ECS reporting the service steady; this script ran at once; all six
# checks failed with the listener's default 503. Nothing was misconfigured:
# green held two healthy tasks and the production rule already weighted them
# at 100 — the ALB simply had not finished settling, and the identical checks
# passed minutes later. Staging never showed it because a rolling deployment
# reports steady only once its one target group is healthy; a first BLUE_GREEN
# deployment reports steady before its listener does.
#
# So a one-shot check seconds after an apply is a race, and it fails in the
# same shape as a real blue/green fault. The gate below closes the race without
# weakening the checks: it polls /health until it answers 200, within a bound,
# and the six checks then run exactly once, as before. If the bound passes the
# checks still run — that failure keeps the 503 and body that name its cause,
# which is what the runbook tells the operator to read.
#
# /health rather than /ready: this is asking whether the listener reaches a
# task at all, not whether the task reaches DynamoDB. The 40-second /ready
# case below stays where it is.
# ---------------------------------------------------------------------------
READY_TIMEOUT="${BGD_SMOKE_READY_TIMEOUT:-120}"
READY_INTERVAL="${BGD_SMOKE_READY_INTERVAL:-5}"

wait_until_serving() {
  local started=$SECONDS attempts=0 status
  while :; do
    attempts=$((attempts + 1))
    status="$(curl --silent --max-time 10 --output /dev/null \
      --write-out '%{http_code}' "$BASE_URL/health" 2>/dev/null)" || status=""
    if [[ "$status" == "200" ]]; then
      ((attempts > 1)) && dim "  waited $((SECONDS - started))s for /health ($attempts attempts)"
      return 0
    fi
    ((SECONDS - started >= READY_TIMEOUT)) && return 1
    sleep "$READY_INTERVAL"
  done
}

wait_until_serving ||
  warn "$env_name is not serving after ${READY_TIMEOUT}s — running the checks anyway, so the failure names its cause"

LAST_BODY=""

probe /health 200 10
probe /ready 200 40
probe /version 200 10

# Held separately because LAST_BODY belongs to whichever probe ran last, and
# the digest check below already depends on that being /version's. The colour
# check needs the same body after further output has been written, so it takes
# its own copy rather than adding a second reader of a shared variable.
VERSION_BODY="$LAST_BODY"

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

# Whether this image predates Phase 12 — the one signal checks 5 and 6 share.
#
# /version's release_color is authoritative: an image built before the phase
# has no such field, one built since always has one. Derived once, here,
# because the two checks must agree — a pre-Phase-12 image legitimately serves
# no page AND reports no colour, and letting each decide for itself would
# report one old image as two unrelated defects.
pre_phase12=false
reported=""
if [[ -n "$VERSION_BODY" ]]; then
  reported="$(printf '%s' "$VERSION_BODY" | jq -r '.release_color // empty')"
  if [[ -z "$reported" ]]; then
    pre_phase12=true
  fi
fi

# 5. The demonstration page is being served. Phase 12.
#
# --output /dev/null and a --write-out format, rather than probe(): this is the
# one check that cares about the content type, because X-Content-Type-Options
# is nosniff and a page served as anything but text/html renders as source.
printf '  %-10s ' "page"
page="$(curl --silent --show-error --max-time 10 --output /dev/null \
  --write-out '%{http_code} %{content_type}' "$BASE_URL/" 2>/dev/null)" || page=""
case "$page" in
  "200 text/html"*) mark_ok ;;
  "") mark_fail "no response within 10s"
     failures=$((failures + 1)) ;;
  *) if [[ "$pre_phase12" == true ]]; then
       mark_warn "no page — this image predates Phase 12 (got '$page')"
     else
       mark_fail "expected 200 text/html, got '$page'"
       failures=$((failures + 1))
     fi ;;
esac

# 6. The image carries a release identity, and it is not the local default.
#
# This is the useful half. A deployed container reporting "slate" means the
# build argument never reached the image and the deployment succeeded anyway —
# a green pipeline over a colourless demo, discovered in front of an audience.
# Here it is a failed smoke test on the deploy that caused it.
printf '  %-10s ' "colour"
if [[ -z "$VERSION_BODY" ]]; then
  mark_fail "no /version response to check"
  failures=$((failures + 1))
else
  case "$reported" in
    blue | green) mark_ok ;;
    "") mark_warn "no release_color — this image predates Phase 12; a restore or a rollback is entitled to put one back" ;;
    slate) mark_fail "/version reports 'slate' — RELEASE_COLOR never reached the image; check both --build-arg lines"
       failures=$((failures + 1)) ;;
    *) mark_fail "/version reports '$reported', which is not a release colour"
       failures=$((failures + 1)) ;;
  esac
fi

echo
if ((failures > 0)); then
  die "$failures smoke check(s) failed against $env_name"
fi
ok "$env_name is serving $EXPECTED_DIGEST"
