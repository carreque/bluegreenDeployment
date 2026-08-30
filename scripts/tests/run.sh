#!/usr/bin/env bash
#
# The shell suite. Runs every scripts/tests/test_*.sh in its own process and
# sums the results.
#
#   make test-scripts
#
# Needs no AWS session, no Terraform state and no network: the scripts under
# test reach AWS only through the fake CLI in fake-bin/, which the individual
# test files put on PATH. Plan §D12.
#
# NOT set -e: a failing test file must be reported and the remaining files
# still run. A single red file that aborts the suite hides how much else broke.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failed=0
total=0

for file in "$HERE"/test_*.sh; do
  printf '\n\033[34m==>\033[0m %s\n' "$(basename "$file")"
  total=$((total + 1))
  bash "$file" || failed=$((failed + 1))
done

printf '\n'
if ((failed == 0)); then
  printf '\033[32m  ✓\033[0m %d test files passed\n\n' "$total"
else
  printf '\033[31m  ✗\033[0m %d of %d test files failed\n\n' "$failed" "$total"
fi

((failed == 0))
