#!/usr/bin/env bash
#
# Every relative link in the documentation resolves to a file that exists.
#
# These documents cross-reference heavily — a phase record cites its plan, its
# runbook, the roadmap amendment and often another phase's finding — and nothing
# checked any of it. Six links were broken for weeks before a review found them,
# in exactly the way a broken link is always found: not at all, until somebody
# follows one.
#
# Deliberately NOT part of `make tf-check` and NOT run by the pipeline's Validate
# stage. A dead link is a documentation defect, not a deployment risk, and a
# Validate stage that fails on prose would train people to skip it. Run it when
# you touch the documentation.
#
# Pure bash on purpose: no virtualenv, no ambient python3, nothing to install.
# The whole point is that it works on any machine that can read the repository.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(repo_root)"
cd "$ROOT"

failures=0
checked=0
files=0

# Anything tracked, plus untracked markdown that is not ignored — so a record
# written but not yet committed is checked before it lands, which is the moment
# the links are easiest to fix.
while IFS= read -r file; do
  files=$((files + 1))
  dir="$(dirname "$file")"

  # grep -n and -o together yield "LINENO:](target)", one per link on the line.
  while IFS= read -r hit; do
    lineno="${hit%%:*}"
    target="${hit#*:}"
    target="${target#](}"
    target="${target%)}"

    # Drop the anchor; an anchor-only link points inside the same file.
    target="${target%%#*}"
    [[ -n "$target" ]] || continue

    case "$target" in
      http://* | https://* | mailto:* | tel:*) continue ;;
      /*) resolved="$ROOT$target" ;;
      *) resolved="$dir/$target" ;;
    esac

    checked=$((checked + 1))

    # No normalisation needed: the filesystem resolves ../ for us.
    if [[ ! -e "$resolved" ]]; then
      fail "$file:$lineno -> $target"
      failures=$((failures + 1))
    fi
  done < <(grep -nEo '\]\([^)]+\)' "$file" 2>/dev/null || true)
done < <(git ls-files '*.md'; git ls-files --others --exclude-standard '*.md')

echo
if ((failures > 0)); then
  die "$failures broken link(s) across $files files ($checked relative links checked)"
fi

ok "$checked relative links across $files files all resolve"
