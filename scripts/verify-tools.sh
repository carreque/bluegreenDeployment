#!/usr/bin/env bash
#
# Phase 0 / task A1 — check the local toolchain against the minimums the
# design documents depend on, and confirm the repository's version pins are
# actually the versions in use.
#
# Deliberately resolves every tool through PATH rather than asking a version
# manager directly. The bug this guards against was a PATH resolution
# difference between interactive and non-interactive shells; a check that
# bypasses PATH would not have caught it.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(repo_root)"
failures=0

# name  minimum  why
TOOLS=(
  "terraform|1.10.0|use_lockfile on the S3 backend (design §1.8)"
  "python3|3.14.0|parity with the container (design §1.6)"
  "docker|24.0.0|BuildKit"
  "aws|2.15.0|recorded baseline (design §2)"
  "git|2.39.0|recorded baseline (design §2)"
  "make|3.81|see note in the Phase 0 plan, §5"
  "jq|1.6|Terraform provider schema inspection"
)

version_of() {
  case "$1" in
  terraform) try terraform version ;;
  make) try make --version ;;
  *) try "$1" --version ;;
  esac
}

ROW='  %-19s %-10s %-10s '

info "Toolchain"
printf "$ROW%s\n" "TOOL" "REQUIRED" "FOUND" "STATUS"

for entry in "${TOOLS[@]}"; do
  IFS='|' read -r name min why <<<"$entry"

  if ! command -v "$name" >/dev/null 2>&1; then
    printf "$ROW" "$name" ">= $min" "-"
    mark_fail "not installed — $why"
    failures=$((failures + 1))
    continue
  fi

  found="$(extract_version "$(version_of "$name")")"
  printf "$ROW" "$name" ">= $min" "${found:-?}"

  if [[ -z "$found" ]]; then
    mark_warn "version could not be parsed"
  elif version_gte "$found" "$min"; then
    mark_ok
  else
    mark_fail "below minimum — $why"
    failures=$((failures + 1))
  fi
done

# ---------------------------------------------------------------------------
# Repository version pins.
#
# A pin that PATH does not honour is worse than no pin, because it reads as a
# guarantee. This is exactly the failure mode found in Phase 0: pyenv had the
# right version selected while non-interactive shells resolved another one.
# ---------------------------------------------------------------------------
#
# check_pin <file> <tool> [diagnostic command...]
#
# The diagnostic matters. A pyenv shim whose pinned version is not installed
# does NOT fail: it falls through to the next interpreter on PATH and exits 0.
# Comparing against PATH catches that, but only `pyenv version` explains it,
# so the diagnostic is printed on mismatch to turn a confusing result into an
# obvious fix.
check_pin() {
  local file="$1" tool="$2"
  shift 2
  local pinned actual diag
  [[ -f "$ROOT/$file" ]] || return 0

  pinned="$(tr -d '[:space:]' <"$ROOT/$file")"
  actual="$(extract_version "$(version_of "$tool")")"

  printf "$ROW" "$file" "$pinned" "${actual:-?}"
  if [[ "$pinned" == "$actual" ]]; then
    mark_ok
    return 0
  fi

  mark_fail "pin not honoured — '$tool' on PATH is ${actual:-none}, not $pinned"
  if (($# > 0)) && command -v "$1" >/dev/null 2>&1; then
    diag="$(try "$@")"
    [[ -n "$diag" ]] && dim "                      $diag"
  fi
  failures=$((failures + 1))
}

echo
info "Version pins"
printf "$ROW%s\n" "FILE" "PINNED" "ON PATH" "STATUS"
check_pin ".terraform-version" terraform tfenv version-name
check_pin ".python-version" python3 pyenv version

echo
if ((failures > 0)); then
  die "$failures check(s) failed."
fi
ok "toolchain verified"
