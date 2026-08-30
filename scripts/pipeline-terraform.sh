#!/usr/bin/env bash
#
# The infra pipeline's Terraform driver: one script, two modes.
#
#   scripts/pipeline-terraform.sh plan  <layer>
#   scripts/pipeline-terraform.sh apply <layer>
#
# Called only from CodeBuild, by pipelines/infra-plan.yml and
# pipelines/infra-apply.yml. Local work still goes through `make plan-<layer>`
# and `make apply-<layer>`, which call scripts/tf.sh — and so does this, which
# is why the layer-name-to-directory mapping appears here nowhere. Phase 10
# moved that map into lib/common.sh as layer_dir(), when rebuild.sh would have
# been its fourth copy; lint-infra.sh keeps a variant of its own because its
# contract differs (Phase 10 §D13, §F6).
#
# Three things it does that scripts/tf.sh deliberately does not:
#
#  1. It enforces DEPLOY_SCOPE itself. The pipeline already skips out-of-scope
#     stages with a before_entry condition, so this is the second of two
#     independent gates. The redundancy is deliberate and the asymmetry is the
#     point: if the condition is wrong in the direction of entering a stage it
#     should have skipped, this refuses and the cost is an approval nobody
#     wanted. If this were absent and the condition were wrong that way, a
#     DEPLOY_SCOPE=network run would apply production. Plan §D4.
#
#  2. It supplies image_tag from SSM for the two environment layers, because
#     terraform.tfvars is gitignored and does not exist in a CodeBuild
#     workspace. Plan §D8.
#
#  3. It exports the plan summary the manual approval displays, so the approval
#     is an informed decision rather than a reflex.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform
require_cmd aws

ROOT="$(repo_root)"

# Relative to the layer directory, because scripts/tf.sh runs terraform with
# -chdir. Named to match .gitignore's *.tfplan, so a copy pulled down for
# debugging cannot be committed.
PLAN_FILE="pipeline.tfplan"
VARS_FILE="$ROOT/plan-vars.env"

mode="${1:-}"
layer="${2:-}"
[[ -n "$mode" && -n "$layer" ]] || die "usage: pipeline-terraform.sh <plan|apply> <layer>"

# scope_rank and layer_rank moved to lib/common.sh in Phase 10, as
# platform_scope_rank and platform_layer_rank — rebuild.sh, teardown.sh and
# this script all rank the same four names, and three copies of a rank table
# that decides whether production is applied is three chances to disagree.
#
# The names gained a platform_ prefix rather than moving as-is: pipeline-deploy.sh
# defines a scope_rank of its own over build/staging/all, and bash redefines a
# function silently. Plan §F7.
#
# Cumulative scope: the value names the LAST layer a run applies, so a rank
# comparison is the whole rule. An unrecognised scope ranks 0, which is below
# every layer, so nothing runs — and it is rejected by name below rather than
# being allowed to behave like a silent `foundation`. Plan §D3.

# write_vars, build_url and plan_summary come from lib/common.sh. They lived
# here until Phase 8, whose pipeline-deploy.sh needs all three identically —
# and a plan summary formatted one way in this pipeline's approval and another
# way in that one's would be a difference nobody chose. Same rule
# image_build_identity carries.

# ---------------------------------------------------------------------------
# Gate 1 of 1 in this script, and gate 2 of 2 in the pipeline.
# ---------------------------------------------------------------------------

scope="${DEPLOY_SCOPE:-}"
[[ -n "$scope" ]] ||
  die "DEPLOY_SCOPE is unset — the pipeline action must pass it as an EnvironmentVariables override"

(($(platform_scope_rank "$scope") > 0)) ||
  die "DEPLOY_SCOPE is '$scope'; expected one of foundation, network, staging, all"

(($(platform_layer_rank "$layer") < 99)) ||
  die "unknown layer: $layer (expected foundation, network, staging or prod)"

# Before the saved-plan check below, deliberately. An out-of-scope apply must
# report a skip, not die on a plan file the skipped plan never wrote.
if (($(platform_layer_rank "$layer") > $(platform_scope_rank "$scope"))); then
  info "$layer is outside DEPLOY_SCOPE=$scope — nothing to do"
  if [[ "$mode" == "plan" ]]; then
    write_vars "skipped" "Skipped. $layer is outside DEPLOY_SCOPE=$scope." "$(build_url)"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Gate 2: the platform marker
# ---------------------------------------------------------------------------
#
# The scope above says how far this RUN wants to go. The marker says how far the
# platform actually is. A merge to main after `make teardown` must not recreate
# a NAT gateway, an ALB and two Fargate tasks because somebody fixed a typo in
# a README under infra/.
#
# So the effective scope is the smaller of the two, and a layer above it SKIPS
# — green, never failed. Since Phase 9 a failed run emails you and counts in
# change-failure-rate, and a run that correctly declined to deploy into a
# torn-down account must not look like a bad deployment. Plan §D5.
#
# foundation is exempt and must be: it is the layer that CREATES the marker, so
# on a fresh account the parameter does not exist at the moment it is first
# planned. It ranks 1 and every valid marker value ranks at least 1, so the
# clamp could never exclude it anyway — skipping the READ is what makes the
# bootstrap case work. Plan §D6.
if [[ "$layer" != "foundation" ]]; then
  deployed="$(read_deployed_scope)"

  if (($(platform_layer_rank "$layer") > $(platform_scope_rank "$deployed"))); then
    info "$layer is torn down ($DEPLOYED_SCOPE_PARAM = $deployed) — nothing to do"
    info "run \`make rebuild\` to bring it back"
    if [[ "$mode" == "plan" ]]; then
      write_vars "skipped" "Skipped. $layer is torn down ($DEPLOYED_SCOPE_PARAM = $deployed); run make rebuild." "$(build_url)"
    fi
    exit 0
  fi
fi

case "$mode" in
  plan) ;;
  apply) ;;
  *) die "unknown mode: $mode (expected plan or apply)" ;;
esac

# ---------------------------------------------------------------------------
# apply — the saved plan, and only the saved plan
# ---------------------------------------------------------------------------

if [[ "$mode" == "apply" ]]; then
  case "$layer" in
    foundation | network) dir="infra/$layer" ;;
    *) dir="infra/environments/$layer" ;;
  esac

  [[ -f "$ROOT/$dir/$PLAN_FILE" ]] ||
    die "no saved plan at $dir/$PLAN_FILE — the Plan action in this stage must run first"

  # No -var, and none is permitted: terraform rejects variables when applying a
  # saved plan, because the plan already holds the values it was made with.
  # This is also what makes the approval meaningful — the plan a human read is
  # the plan that runs. Plan §D9.
  #
  # A stale-plan error here means the layer's state moved between the plan and
  # this apply, almost always a local `make apply-<layer>` racing the pipeline.
  # Failing is correct; the runbook says what to do about it.
  info "applying the saved plan for $layer"
  "$ROOT/scripts/tf.sh" apply "$layer" -input=false -lock-timeout=5m "$PLAN_FILE"
  ok "$layer applied"
  exit 0
fi

# ---------------------------------------------------------------------------
# plan — resolve the image tag, plan, summarise
# ---------------------------------------------------------------------------

tf_vars=()

case "$layer" in
  staging | prod)
    param="/bgd/${layer}/image_tag"

    tag="$(aws ssm get-parameter --name "$param" --query 'Parameter.Value' --output text 2>/dev/null)" ||
      die "cannot read $param — apply the foundation layer before planning $layer"

    if [[ -z "$tag" || "$tag" == "unset" || "$tag" == "None" ]]; then
      die "$param is '$tag' — run 'make seed-ecr' to record the seeded tag, or let the app pipeline set it (Phase 8)"
    fi

    info "image_tag for $layer comes from $param → $tag"
    tf_vars=(-var "image_tag=$tag")
    ;;
esac

# -detailed-exitcode is what separates "no changes" from "changes" without
# parsing prose: 0 means empty, 2 means there is a diff, 1 means the plan
# failed. Under `set -e` the 2 has to be caught, hence the `|| status=$?`.
info "planning $layer"

status=0
"$ROOT/scripts/tf.sh" plan "$layer" \
  -input=false \
  -lock-timeout=5m \
  -detailed-exitcode \
  -out="$PLAN_FILE" \
  ${tf_vars[@]+"${tf_vars[@]}"} || status=$?

case "$layer" in
  foundation | network) dir="infra/$layer" ;;
  *) dir="infra/environments/$layer" ;;
esac

case "$status" in
  0)
    summary="No changes. $layer is up to date."
    ok "$summary"
    ;;
  2)
    summary="$(plan_summary "$ROOT/$dir" "$PLAN_FILE")"
    ;;
  *)
    die "terraform plan failed for $layer (exit $status)"
    ;;
esac

# The squeeze and the 900-character truncation are inside plan_summary. The
# exit-0 branch above needs neither: "No changes." is already one short line.

write_vars "$status" "$summary" "$(build_url)"

info "plan summary: $summary"
