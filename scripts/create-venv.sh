#!/usr/bin/env bash
#
# Phase 1 — create the project virtualenv on the interpreter named by
# .python-version, resolved by absolute path rather than through PATH.
#
# Phase 0 fixed pyenv's PATH export for every *zsh* invocation, but bash reads
# neither ~/.zshenv nor ~/.zprofile. A make recipe runs in bash and inherits
# whatever PATH its parent had: launched from a terminal it gets 3.14.6;
# launched from CI, a git hook or an editor task it silently gets the system
# 3.12. Addressing the interpreter by path removes the dependence entirely.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(repo_root)"
VENV="$ROOT/app/.venv"
PIN="$(tr -d '[:space:]' <"$ROOT/.python-version")"

# Ordered by how much they depend on the environment being set up correctly.
find_interpreter() {
  local candidate

  candidate="${PYENV_ROOT:-$HOME/.pyenv}/versions/$PIN/bin/python3"
  [[ -x "$candidate" ]] && {
    printf '%s' "$candidate"
    return 0
  }

  if command -v pyenv >/dev/null 2>&1; then
    candidate="$(pyenv root)/versions/$PIN/bin/python3"
    [[ -x "$candidate" ]] && {
      printf '%s' "$candidate"
      return 0
    }
  fi

  # PATH is accepted only when it is exactly the pinned version.
  if command -v python3 >/dev/null 2>&1; then
    candidate="$(command -v python3)"
    [[ "$(extract_version "$("$candidate" --version 2>&1)")" == "$PIN" ]] && {
      printf '%s' "$candidate"
      return 0
    }
  fi

  return 1
}

# pip is upgraded, but not past 25.x. pip-tools reaches into pip's private
# API — piptools.resolver calls RequirementCommand.make_requirement_preparer,
# whose signature changed in pip 26, and piptools.sync imports stdlib_pkgs,
# which pip 26 removed. pip-tools 7.6.0 is the newest release and has no fix,
# so `make deps-compile` is broken on pip 26 in both directions. The bound is
# expressed as a constraint rather than an exact version so patch releases
# still arrive. Recorded as Phase 1 finding F7.
#
# Nothing else needs the bound: `pip install --require-hashes` behaves
# identically on 25.x, and CI never compiles a lock.
PIP_CONSTRAINT_FOR_PIP_TOOLS="pip<26"

if [[ -x "$VENV/bin/python" ]]; then
  found="$(extract_version "$("$VENV/bin/python" --version 2>&1)")"
  if [[ "$found" == "$PIN" ]]; then
    # Still enforce the pip bound: an existing virtualenv may predate it, or
    # have been upgraded past it by hand.
    "$VENV/bin/python" -m pip install --quiet --upgrade "$PIP_CONSTRAINT_FOR_PIP_TOOLS"
    ok "virtualenv already on $PIN — pip $("$VENV/bin/pip" --version | awk '{print $2}')"
    exit 0
  fi
  warn "virtualenv is on $found but the pin is $PIN — recreating"
  rm -rf "$VENV"
fi

interpreter="$(find_interpreter)" ||
  die "no Python $PIN on this machine. Install it with: pyenv install $PIN"

info "creating $VENV on $interpreter"
"$interpreter" -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet --upgrade "$PIP_CONSTRAINT_FOR_PIP_TOOLS"
ok "virtualenv ready — $("$VENV/bin/python" --version)"
