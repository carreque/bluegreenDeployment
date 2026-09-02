#!/usr/bin/env bash
#
# scripts/tf.sh's flag derivation, against a terraform that records rather than
# runs.
#
# This file exists because of what the 2026-09-02 environments merge gave up.
# Until then each environment was its own directory with its own literal
# `backend "s3"` block, so a configuration and its state key were the same file
# and could not be mismatched. Now infra/ is one root module applied twice, the
# key lives in environments/<env>.backend.hcl, the shape lives in
# environments/<env>.tfvars, and NOTHING in the Terraform binds the two.
#
# tf.sh is the binding. If it derives the pair wrongly, the failure is not a
# broken build — it is planning one environment's configuration against the
# other environment's state, which on the wrong pairing proposes destroying
# production. There is no offline way to observe that except this: assert on the
# arguments tf.sh actually passes.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

source "$HERE/lib.sh"
source "$ROOT/scripts/lib/common.sh"

# Through repo_root() for the same reason test_common.sh does it: git answers
# C:/Users/... under Git Bash while cd+pwd answers /c/Users/... , and every
# assertion below compares a path tf.sh built against one spelled out here.
ROOT="$(repo_root)"

export PATH="$HERE/fake-bin:$PATH"

TF="$ROOT/scripts/tf.sh"

# run_tf <args...> — invoke tf.sh with the recording terraform and leave the
# transcript in $LOG. Progress output is discarded; the transcript is the
# subject.
LOG=""
run_tf() {
  LOG="$(mktemp)"
  FAKE_TF_LOG="$LOG" "$TF" "$@" >/dev/null 2>&1
}

# init_line / cmd_line — the two invocations tf.sh makes, in order.
init_line() { grep -m1 ' init ' "$LOG" || true; }
cmd_line() { tail -1 "$LOG"; }

# --- the pairing, which is the whole point -----------------------------------

run_tf plan prod
check_contains "prod plan inits prod's backend" \
  "-backend-config=$ROOT/infra/environments/prod.backend.hcl" "$(init_line)"
check_contains "prod plan passes prod's var file" \
  "-var-file=$ROOT/infra/environments/prod.tfvars" "$(cmd_line)"
check_contains "…in the merged root module" "-chdir=$ROOT/infra" "$(cmd_line)"

run_tf plan staging
check_contains "staging plan inits staging's backend" \
  "-backend-config=$ROOT/infra/environments/staging.backend.hcl" "$(init_line)"
check_contains "staging plan passes staging's var file" \
  "-var-file=$ROOT/infra/environments/staging.tfvars" "$(cmd_line)"

# The failure this file exists to catch. A prod invocation must not name any
# staging file anywhere in either invocation, and vice versa — a crossed pair is
# not a degraded plan, it is a plan against the wrong state.
run_tf plan prod
check "a prod plan never mentions staging" "" \
  "$(grep -o 'staging' "$LOG" | head -1 || true)"

run_tf plan staging
check "a staging plan never mentions prod" "" \
  "$(grep -o '/prod' "$LOG" | head -1 || true)"

# --- -reconfigure, which is not optional here --------------------------------
#
# infra/ holds ONE .terraform directory and it remembers whichever environment's
# backend was configured last. Without -reconfigure, planning prod straight
# after applying staging either silently reuses staging's state or stops on an
# interactive prompt that -input=false turns into a failure.
run_tf plan prod
check_contains "the environment init is -reconfigure" "-reconfigure" "$(init_line)"

# And never -migrate-state: the two keys are different environments, not a moved
# backend. Migrating would copy one environment's state over the other's.
check "the environment init never migrates state" "" \
  "$(grep -o 'migrate-state' "$LOG" || true)"

# --- a saved plan takes no variables -----------------------------------------
#
# `terraform apply <saved.tfplan>` REJECTS -var-file, because the plan already
# carries the values it was made with. Both pipelines depend on that: their
# Apply stage applies the plan a human approved, not a fresh one. tf.sh detects
# the saved plan by the .tfplan argument rather than being told which mode it is
# in, so this asserts the detection rather than the intent.
run_tf apply prod pipeline-prod.tfplan
check "applying a saved plan passes no var file" "" \
  "$(grep -o 'var-file' "$LOG" || true)"
check_contains "…but still inits prod's backend" \
  "-backend-config=$ROOT/infra/environments/prod.backend.hcl" "$(init_line)"
check_contains "…and still names the plan file" "pipeline-prod.tfplan" "$(cmd_line)"

# An apply with no plan file is a direct apply and DOES need the variables.
run_tf apply prod -auto-approve
check_contains "a direct apply passes the var file" \
  "-var-file=$ROOT/infra/environments/prod.tfvars" "$(cmd_line)"

# --- the offline gate reaches no backend and forces no environment -----------
#
# validate and test must run on a machine that has never logged in (Phase 3
# §F2), so they init with -backend=false and must never be handed a backend
# config.
for offline in validate test; do
  run_tf "$offline" prod
  check_contains "$offline inits with -backend=false" "-backend=false" "$(init_line)"
  check "$offline is given no backend config" "" \
    "$(grep -o 'backend-config' "$LOG" || true)"
done

# test in particular must be given NO var file. infra/tests/ holds both the
# staging and the production suites, each setting environment and enable_prod in
# its own per-file variables block; -var-file applies to every file in the run,
# so forcing one environment's values over the directory would make the other
# suite assert against a plan it was not written for.
run_tf test prod
check "test forces no environment on the suites" "" \
  "$(grep -o 'var-file' "$LOG" || true)"

# --- the three single-environment layers are unaffected ----------------------
#
# bootstrap, foundation and network keep their literal backend blocks and have
# no environment to select, so both helpers return empty and tf.sh must pass
# neither flag. This is the case that proves tf.sh stayed ONE code path rather
# than growing a branch per layer kind.
for layer in foundation network bootstrap; do
  run_tf plan "$layer"
  check "$layer gets no backend config" "" "$(grep -o 'backend-config' "$LOG" || true)"
  check "$layer gets no var file" "" "$(grep -o 'var-file' "$LOG" || true)"
  check_contains "$layer plans in its own directory" "-chdir=$ROOT/infra/$layer" "$(cmd_line)"
done

# --- fmt still runs before any init ------------------------------------------
#
# fmt parses HCL and nothing else. Running init first would make formatting fail
# on a layer whose providers cannot be downloaded, which is the one moment
# formatting is most likely to be needed.
run_tf fmt prod
check "fmt does not init at all" "" "$(grep -o ' init ' "$LOG" || true)"

# --- an unknown layer is refused before terraform is invoked -----------------
run_capture "$TF" plan nonsense
check          "an unknown layer is fatal"  "1" "$STATUS"
check_contains "…and is named"              "unknown layer: nonsense" "$OUTPUT"

report
