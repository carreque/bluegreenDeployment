#!/usr/bin/env bash
#
# scripts/smoke.sh's readiness gate.
#
# Found on 2026-09-03, on the first from-scratch rebuild: prod's apply returned
# with the service steady, smoke.sh ran at once, and all six checks failed with
# the listener's default 503 — the green target group had healthy tasks and the
# rule already weighted them at 100, but the ALB had not finished settling.
# Minutes later the identical checks passed. A one-shot check against an
# environment that was applied seconds ago is a race, and it fails in the same
# shape as a real blue/green misconfiguration.
#
# What the gate must do: wait, within a bound, for the environment to start
# answering; then run the six checks exactly once, as before. What it must NOT
# do is retry the checks themselves, or hide an environment that never comes
# up — that failure keeps its original diagnostic.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

source "$HERE/lib.sh"

export PATH="$HERE/fake-bin:$PATH"

SMOKE="$ROOT/scripts/smoke.sh"
DIGEST="sha256:39a4fec5950b86791f2fc6c3cd3c76cfe38c917ac03318ccb90980476e0f16cb"

# Both overrides, so the script never reaches for terraform; the fake curl
# answers the URL. The gate polls at no interval and gives up fast, so the
# never-ready case costs the suite seconds rather than the real two minutes.
export BGD_SMOKE_URL="https://fake.test"
export BGD_SMOKE_DIGEST="$DIGEST"
export FAKE_CURL_DIGEST="$DIGEST"
export BGD_SMOKE_READY_INTERVAL=0
export BGD_SMOKE_READY_TIMEOUT=2

smoke_with() {
  # smoke_with <calls answering 503 before the environment is up>
  FAKE_CURL_COUNT_FILE="$(mktemp)"
  export FAKE_CURL_COUNT_FILE
  export FAKE_CURL_503_UNTIL="$1"
  run_capture "$SMOKE" prod
  CALLS="$(cat "$FAKE_CURL_COUNT_FILE")"
  rm -f "$FAKE_CURL_COUNT_FILE"
}

# --- an environment that is already up ---------------------------------------
#
# The common case, and its output must not change: no waiting line, six ticks.

smoke_with 0
check          "an environment that is up passes"     "0" "$STATUS"
check_contains "…serving the expected digest"          "prod is serving $DIGEST" "$OUTPUT"
check          "…without mentioning a wait"            "" "$(grep -o "waited" <<<"$OUTPUT" || true)"

# --- an environment that is still settling -----------------------------------
#
# The race. Three 503s, then healthy: the old script failed here on the first
# call. The gate absorbs them and the six checks then run against a serving
# environment. The call count proves the probes were not what retried.

smoke_with 3
check          "an environment still settling passes once it is up" "0" "$STATUS"
check_contains "…and says how long it waited"          "waited" "$OUTPUT"
check_contains "…serving the expected digest"          "prod is serving $DIGEST" "$OUTPUT"
check          "…with the checks run exactly once after the gate" "8" "$CALLS"

# --- an environment that never comes up --------------------------------------
#
# The bound. The gate gives up, and the six checks still run so the failure
# names its cause — the same 503 and body the old script would have shown.
# A gate that died on its own would hide exactly the diagnostic the runbook
# tells the operator to read.

smoke_with 1000
check          "an environment that never comes up fails"   "1" "$STATUS"
check_contains "…after the gate gives up"                    "not serving after" "$OUTPUT"
check_contains "…with the original diagnostic on /health"   "HTTP 503 (expected 200)" "$OUTPUT"
check_contains "…and the ALB's own body"                     "no listener rule matched" "$OUTPUT"
check_contains "…counting every failed check"                "6 smoke check(s) failed" "$OUTPUT"

report
