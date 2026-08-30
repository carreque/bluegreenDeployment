#!/usr/bin/env bash
# Assertions for the shell suite. Sourced by every scripts/tests/test_*.sh;
# do not execute it.
#
# Deliberately not bats. A harness that has to be installed is a harness the
# offline gate cannot depend on: `make test-scripts` must run on a laptop that
# has bash and nothing else, and in CodeBuild with no install step. Forty
# lines buys the three things a framework would provide here. Plan §D12.

CHECKS_RUN=0
CHECKS_FAILED=0

# Counters are incremented as X=$((X + 1)) and never as ((X++)).
#
# ((X++)) evaluates to the value BEFORE the increment, so on a zero counter it
# returns status 1 — and every script under test sources lib/common.sh, which
# sets -e. The suite would then exit at the first failing check, reporting one
# failure where there are nine, at the one moment it most needs to survive.
# Plan §F4.

# check <description> <expected> <actual>
check() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  if [[ "$2" == "$3" ]]; then
    printf '  ✓ %s\n' "$1"
  else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    printf '  ✗ %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
  fi
}

# check_contains <description> <needle> <haystack>
check_contains() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  if [[ "$3" == *"$2"* ]]; then
    printf '  ✓ %s\n' "$1"
  else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    printf '  ✗ %s\n      expected to contain: %s\n      actual:              %s\n' "$1" "$2" "$3"
  fi
}

# run_capture <command...> — run it, capture stdout+stderr into OUTPUT and the
# exit status into STATUS, without letting a non-zero status abort the suite.
#
# The set +e is the whole point. A refusal path is a NON-ZERO exit this suite
# needs to assert on rather than die from, and every script under test inherits
# set -e from lib/common.sh. Plan §F4.
run_capture() {
  set +e
  OUTPUT="$("$@" 2>&1)"
  STATUS=$?
  set -e
}

# report — the trailing summary and this file's exit status.
report() {
  printf '\n  %s: %d checks, %d failed\n' "$(basename "$0")" "$CHECKS_RUN" "$CHECKS_FAILED"
  ((CHECKS_FAILED == 0))
}
