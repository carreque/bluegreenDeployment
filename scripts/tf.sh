#!/usr/bin/env bash
#
# Per-layer terraform driver.
#
#   scripts/tf.sh <fmt|validate|test|plan|apply|destroy|init> <layer> [args...]
#
# Layer names are the ones the runbook and roadmap use — bootstrap, foundation,
# network, staging, prod — not directory paths, so a caller never has to know
# that staging and prod are the same root module told apart by a var file.
#
# The init mode matters. fmt, validate and test need no AWS session and no state
# bucket, so they init with -backend=false and work on a machine that has never
# logged in (Phase 3 §F2). plan, apply and destroy need the real backend.
#
# The two modes do NOT share a data directory, and until 2026-09-03 they did.
# -backend=false does not mean "no backend": it means "keep whatever backend
# .terraform/ already remembers", and then loads it. So once a root had been
# planned against the bucket, every later validate or test still reached for
# the bucket — and failed to init the day it was gone, after a teardown.
# -reconfigure does not help; it also loads the remembered state. The offline
# mode therefore inits in .terraform-offline/, a directory plan and apply
# never touch, so it cannot inherit a backend from them. The price is a
# second provider download per root; TF_PLUGIN_CACHE_DIR would share it.
#
# ---------------------------------------------------------------------------
# Why this script is now the thing that keeps staging and prod apart
# ---------------------------------------------------------------------------
#
# Until 2026-09-02 each environment was its own directory with its own literal
# `backend "s3"` block, so the state key could not be mismatched with the
# configuration — they were the same file. The environments merge made
# infra/ one root module applied twice, which means the key moved into
# environments/<env>.backend.hcl and the environment's shape into
# environments/<env>.tfvars, and NOTHING in the Terraform binds the two.
#
# This script is the binding. It takes one layer name and derives both, so the
# pair cannot come apart for any caller that goes through `make` or through the
# pipeline scripts. The shape that can still get it wrong is a hand-typed
# `terraform -chdir=infra ...`, which is why the runbooks spell out both flags
# together and why -reconfigure is unconditional below.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform

ROOT="$(repo_root)"

command="${1:-}"
layer="${2:-}"
[[ -n "$command" && -n "$layer" ]] || die "usage: tf.sh <command> <layer> [args...]"
shift 2

# The map moved to lib/common.sh in Phase 10, when rebuild.sh would have been
# the fourth copy. The original comment here recorded why it was inline rather
# than in a helper — die() wrote to stdout, so a failure inside "$(...)" was
# captured instead of shown. die() writes to stderr now, which is what makes
# the shared helper safe to call this way.
dir="$(layer_dir "$layer")"
var_file="$(layer_var_file "$layer")"
backend_config="$(layer_backend_config "$layer")"

[[ -d "$dir" ]] || die "layer '$layer' has no directory yet: ${dir#"$ROOT"/}"

info "terraform $command — $layer"

# fmt parses HCL and nothing else — no provider, no backend, no state. Running
# init first would make formatting fail on a layer whose providers cannot be
# downloaded, which is the one moment formatting is most likely to be needed.
if [[ "$command" != "fmt" ]]; then
  case "$command" in
    validate | test)
      init_args=(-backend=false)
      # Exported, not passed: the validate or test below must read the same
      # data directory this init writes. Absolute, because terraform resolves
      # a relative TF_DATA_DIR against its -chdir target, and spelling that
      # out is clearer than relying on it. See the note at the top.
      export TF_DATA_DIR="$dir/.terraform-offline"
      ;;
    *)
      init_args=()

      # -reconfigure, always, and this is not defensive tidiness. infra/ holds
      # ONE .terraform directory and it remembers whichever environment's
      # backend was initialised last. Without this, `tf.sh plan prod` straight
      # after `tf.sh apply staging` either reuses staging's state silently or
      # stops to ask an interactive question that -input=false turns into a
      # failure. Re-initialising costs a second against an already-populated
      # plugin cache.
      #
      # It is deliberately NOT paired with -migrate-state: the two keys are
      # different environments, not a moved backend, and migrating would copy
      # one environment's state over the other's.
      [[ -n "$backend_config" ]] &&
        init_args+=(-reconfigure -backend-config="$backend_config")
      ;;
  esac
  terraform -chdir="$dir" init -input=false ${init_args[@]+"${init_args[@]}"} >/dev/null
fi

# The var file goes only to the commands that accept one.
#
# `terraform apply <saved.tfplan>` REJECTS -var-file, because a saved plan
# already carries the values it was made with — and that rejection is a feature
# the infra and app pipelines both depend on (their Apply stage applies the plan
# a human approved, not a fresh one). So an apply is given the var file only
# when no plan file was passed, which is detected by looking for a .tfplan
# argument rather than by asking the caller to say which mode it is in.
#
# test is excluded for a different reason: -var-file applies to every file in
# the run, and infra/tests/ holds both the staging and production suites. Each
# suite sets environment and enable_prod in its own `variables` block; forcing
# one environment's values over the whole directory would make one of them
# assert against a plan it was not written for.
tf_args=()
if [[ -n "$var_file" ]]; then
  case "$command" in
    plan | destroy | refresh | console | import)
      tf_args+=(-var-file="$var_file")
      ;;
    apply)
      applying_saved_plan=false
      for arg in ${@+"$@"}; do
        [[ "$arg" == *.tfplan ]] && applying_saved_plan=true
      done
      [[ "$applying_saved_plan" == false ]] && tf_args+=(-var-file="$var_file")
      ;;
  esac
fi

terraform -chdir="$dir" "$command" ${tf_args[@]+"${tf_args[@]}"} ${@+"$@"}
