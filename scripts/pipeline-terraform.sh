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
# is why the layer-name-to-directory mapping appears here nowhere. That map
# already exists in three places (tf.sh, lint-infra.sh, teardown.sh) and a
# fourth copy would be a fourth thing to forget.
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

# Cumulative scope: the value names the LAST layer a run applies, so a rank
# comparison is the whole rule. An unrecognised scope ranks 0, which is below
# every layer, so nothing runs — and it is rejected by name below rather than
# being allowed to behave like a silent `foundation`. Plan §D3.
scope_rank() {
  case "$1" in
    foundation) echo 1 ;;
    network) echo 2 ;;
    staging) echo 3 ;;
    all) echo 4 ;;
    *) echo 0 ;;
  esac
}

layer_rank() {
  case "$1" in
    foundation) echo 1 ;;
    network) echo 2 ;;
    staging) echo 3 ;;
    prod) echo 4 ;;
    *) echo 99 ;;
  esac
}

# Written on every path out of plan mode, including the skip. Without the skip
# case the approval action would interpolate the previous execution's summary,
# which is a worse failure than an empty one — it describes changes that are
# not in this run.
write_vars() {
  local status="$1" summary="$2" url="$3"
  {
    printf 'PLAN_STATUS=%q\n' "$status"
    printf 'PLAN_SUMMARY=%q\n' "$summary"
    printf 'PLAN_URL=%q\n' "$url"
  } >"$VARS_FILE"
}

# The CodeBuild console deep link for this build, so the approval message can
# offer the full plan behind the truncated summary. Built from the build ARN
# because that is the only place the account id appears in a CodeBuild
# environment. Empty outside CodeBuild, which is harmless — the field is
# optional.
build_url() {
  [[ -n "${CODEBUILD_BUILD_ARN:-}" ]] || return 0
  local _ arn_region arn_account project
  IFS=':' read -r _ _ _ arn_region arn_account _ <<<"$CODEBUILD_BUILD_ARN"
  project="${CODEBUILD_BUILD_ID%%:*}"
  printf 'https://%s.console.aws.amazon.com/codesuite/codebuild/%s/projects/%s/build/%s/?region=%s' \
    "$arn_region" "$arn_account" "$project" "${CODEBUILD_BUILD_ID//:/%3A}" "$arn_region"
}

# ---------------------------------------------------------------------------
# Gate 1 of 1 in this script, and gate 2 of 2 in the pipeline.
# ---------------------------------------------------------------------------

scope="${DEPLOY_SCOPE:-}"
[[ -n "$scope" ]] ||
  die "DEPLOY_SCOPE is unset — the pipeline action must pass it as an EnvironmentVariables override"

(($(scope_rank "$scope") > 0)) ||
  die "DEPLOY_SCOPE is '$scope'; expected one of foundation, network, staging, all"

(($(layer_rank "$layer") < 99)) ||
  die "unknown layer: $layer (expected foundation, network, staging or prod)"

# Before the saved-plan check below, deliberately. An out-of-scope apply must
# report a skip, not die on a plan file the skipped plan never wrote.
if (($(layer_rank "$layer") > $(scope_rank "$scope"))); then
  info "$layer is outside DEPLOY_SCOPE=$scope — nothing to do"
  if [[ "$mode" == "plan" ]]; then
    write_vars "skipped" "Skipped. $layer is outside DEPLOY_SCOPE=$scope." "$(build_url)"
  fi
  exit 0
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
    # `terraform show` on the saved plan rather than scraping the plan output,
    # so the summary describes the artifact Apply will consume rather than the
    # text that scrolled past. The Plan: line first, then the resource
    # addresses, which is the order someone reads an approval in.
    summary="$(
      terraform -chdir="$ROOT/$dir" show -no-color "$PLAN_FILE" |
        grep -E '^(Plan:|  # )' |
        sed 's/^  # //'
    )"
    ;;
  *)
    die "terraform plan failed for $layer (exit $status)"
    ;;
esac

# One line, and short. A CodePipeline variable and a manual approval's
# CustomData are both capped at 1000 characters, and a newline inside a
# KEY=value line would break the `. plan-vars.env` the buildspec does. The
# full plan is one click away through PLAN_URL, which is the point of
# exporting it.
summary="$(printf '%s' "$summary" | tr '\n' ' ' | tr -s ' ')"
if ((${#summary} > 900)); then
  summary="${summary:0:880} … (truncated; full plan in the build log)"
fi

write_vars "$status" "$summary" "$(build_url)"

info "plan summary: $summary"
