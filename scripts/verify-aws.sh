#!/usr/bin/env bash
#
# Phase 0 / task A2 — confirm there is a usable AWS session on the expected
# profile, in the expected account and region.
#
# Fails with the literal command to run rather than a description of it, so a
# stale SSO token costs one paste instead of a trip to the runbook.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd aws

PROFILE="${AWS_PROFILE:-bootcamp-administrator-access}"
EXPECTED_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT="${AWS_ACCOUNT_ID:-590184028094}"

info "AWS session"
dim "  profile: $PROFILE"

if ! identity="$(aws sts get-caller-identity --profile "$PROFILE" --output json 2>&1)"; then
  fail "no usable session on profile '$PROFILE'"
  echo
  dim "$identity"
  echo
  echo "  Run:"
  echo "      aws sso login --profile $PROFILE"
  echo
  exit 1
fi

account="$(printf '%s' "$identity" | sed -n 's/.*"Account": *"\([^"]*\)".*/\1/p')"
arn="$(printf '%s' "$identity" | sed -n 's/.*"Arn": *"\([^"]*\)".*/\1/p')"
region="$(aws configure get region --profile "$PROFILE" 2>/dev/null || true)"
region="${region:-$EXPECTED_REGION}"

failures=0

ROW='  %-10s %-16s '

printf "$ROW" "account" "$account"
if [[ "$account" == "$EXPECTED_ACCOUNT" ]]; then
  mark_ok
else
  mark_fail "expected $EXPECTED_ACCOUNT"
  failures=$((failures + 1))
fi

printf "$ROW" "region" "$region"
if [[ "$region" == "$EXPECTED_REGION" ]]; then
  mark_ok
else
  mark_fail "expected $EXPECTED_REGION"
  failures=$((failures + 1))
fi

dim "  arn:       $arn"

echo
if ((failures > 0)); then
  die "$failures check(s) failed."
fi
ok "AWS session verified"
