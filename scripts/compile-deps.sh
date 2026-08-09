#!/usr/bin/env bash
#
# Recompile the requirements locks with hashes. Runs pip-compile from inside
# the virtualenv so the resolution happens on the pinned interpreter — a lock
# compiled on 3.12 can select different wheels than 3.14 would.
#
# Two things here are not obvious.
#
# 1. pip-tools is bootstrapped rather than assumed. It lives in
#    requirements-dev.txt, which is the file this script produces, so on a
#    fresh virtualenv there is nothing to run yet. Installing it unpinned here
#    is safe: this script writes the lock, it does not consume it.
#
# 2. The `pip-compile` entry point is used rather than `python -m piptools
#    compile`. piptools/__main__.py imports piptools.sync unconditionally,
#    which drags in pip internals this project never uses. pip-compile does
#    not. create-venv.sh holds pip below 26 for the same family of reasons —
#    see the note there and Phase 1 finding F7.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(repo_root)"
APP="$ROOT/app"
PY="$ROOT/app/.venv/bin/python"
PIP_COMPILE="$ROOT/app/.venv/bin/pip-compile"

[[ -x "$PY" ]] || die "virtualenv missing — run 'make venv' first"

if [[ ! -x "$PIP_COMPILE" ]]; then
  info "bootstrapping pip-tools into the virtualenv"
  "$PY" -m pip install --quiet pip-tools
fi

# --allow-unsafe pins pip, setuptools and wheel like any other dependency.
# pip-tools calls them "unsafe" because pinning them in a general-purpose lock
# can fight the ambient environment; here it is the opposite of unsafe. A lock
# built with --generate-hashes that leaves a package unpinned is a lock that
# `pip install --require-hashes` can reject, and `make deps` and CI both run
# exactly that command.
for input in requirements.in requirements-dev.in; do
  info "compiling $input"
  (cd "$APP" && "$PIP_COMPILE" \
    --generate-hashes \
    --strip-extras \
    --allow-unsafe \
    --quiet \
    --output-file "${input%.in}.txt" \
    "$input")
done

ok "locks recompiled"
