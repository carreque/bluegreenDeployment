#!/usr/bin/env bash
# Shared helpers for this repository's scripts.
# Source this file; do not execute it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

set -euo pipefail

# Colour only when stdout is a terminal, so piped and CodeBuild output stay clean.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_DIM=$'\033[2m'
else
  C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_DIM=''
fi

info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$*"; }
dim() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

die() {
  fail "$*"
  exit 1
}

# Inline status marks, for the last column of a table row. Unlike ok()/fail()
# these emit no leading padding and no trailing space.
mark_ok() { printf '%s✓%s\n' "$C_GREEN" "$C_RESET"; }
mark_fail() { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET"; }
mark_warn() { printf '%s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# repo_root — absolute path to the repository root, wherever the script is called from.
repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
  }
}

# extract_version <string> — first dotted numeric version found in the string.
# Handles "git version 2.50.1 (Apple Git-155)", "Terraform v1.15.7",
# "aws-cli/2.35.4 Python/3.14.5", "jq-1.7.1", "GNU Make 3.81".
#
# Always succeeds, returning the empty string when nothing matches. Callers run
# under `set -euo pipefail`, where a bare failing grep inside a command
# substitution would abort the script instead of reporting a missing version.
extract_version() {
  printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true
}

# try <command...> — run a command, capture its first line of output, and
# never propagate a non-zero exit. For probing tools that report information
# through a failure, such as `pyenv version` on an uninstalled pin.
try() {
  "$@" 2>&1 | head -1 || true
}

# version_gte <have> <want> — true when have >= want.
# Uses a numeric field sort rather than `sort -V`, which BSD sort on macOS
# does not reliably provide.
version_gte() {
  local have="$1" want="$2" lowest
  [[ "$have" == "$want" ]] && return 0
  lowest="$(printf '%s\n%s\n' "$have" "$want" |
    sort -t. -k1,1n -k2,2n -k3,3n | head -1)"
  [[ "$lowest" == "$want" ]]
}
