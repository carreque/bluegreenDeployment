#!/usr/bin/env bash
#
# Per-layer terraform driver.
#
#   scripts/tf.sh <fmt|validate|test|plan|apply|destroy|init> <layer> [args...]
#
# Layer names are the ones the runbook and roadmap use — bootstrap, foundation,
# network, staging, prod — not directory paths, so a caller never has to know
# that the environment layers live one level deeper than the others.
#
# The init mode matters. fmt, validate and test need no AWS session and no state
# bucket, so they init with -backend=false and work on a machine that has never
# logged in (Phase 3 §F2). plan, apply and destroy need the real backend.
# Terraform re-initialises cleanly when switching between the two.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform

ROOT="$(repo_root)"

command="${1:-}"
layer="${2:-}"
[[ -n "$command" && -n "$layer" ]] || die "usage: tf.sh <command> <layer> [args...]"
shift 2

# Mapped inline rather than through a helper called in "$(...)". The original
# draft used a helper and lost its own error message: lib/common.sh's die() then
# wrote to stdout, so the message was captured into the variable being assigned
# and the script exited 1 in silence. die() now writes to stderr, so the shape
# would work — but an inline case is still the simpler thing, and it does not
# depend on that fix holding.
case "$layer" in
  bootstrap | foundation | network) dir="$ROOT/infra/$layer" ;;
  staging | prod) dir="$ROOT/infra/environments/$layer" ;;
  *) die "unknown layer: $layer (expected bootstrap, foundation, network, staging or prod)" ;;
esac

[[ -d "$dir" ]] || die "layer '$layer' has no directory yet: ${dir#"$ROOT"/}"

info "terraform $command — $layer"

# fmt parses HCL and nothing else — no provider, no backend, no state. Running
# init first would make formatting fail on a layer whose providers cannot be
# downloaded, which is the one moment formatting is most likely to be needed.
if [[ "$command" != "fmt" ]]; then
  case "$command" in
    validate | test) init_args=(-backend=false) ;;
    *) init_args=() ;;
  esac
  terraform -chdir="$dir" init -input=false ${init_args[@]+"${init_args[@]}"} >/dev/null
fi

terraform -chdir="$dir" "$command" ${@+"$@"}
