#!/usr/bin/env bash
#
# The application pipeline's Terraform driver: one script, three modes.
#
#   scripts/pipeline-deploy.sh deploy staging   apply, then record the tag
#   scripts/pipeline-deploy.sh plan   prod      plan, export what the approval shows
#   scripts/pipeline-deploy.sh apply  prod      apply the saved plan, then record
#
# Called only from CodeBuild, by pipelines/app-deploy.yml, app-plan.yml and
# app-apply.yml. Local work still goes through `make apply-staging` and
# `make apply-prod`, which call scripts/tf.sh — and so does this, which is why
# the layer-name-to-directory map appears here nowhere. It already exists in
# three places (tf.sh, lint-infra.sh, teardown.sh) and a fourth copy would be a
# fourth thing to forget.
#
# ---------------------------------------------------------------------------
# Why this runs Terraform rather than the standard ECS deploy action
# ---------------------------------------------------------------------------
#
# The CodePipeline ECS deploy action takes imagedefinitions.json and replaces
# container image URIs ONLY, copying every other field — the container
# environment included — from the current task definition revision. Both of
# this project's task definitions set
#
#     { name = "BGD_IMAGE_DIGEST", value = data.aws_ecr_image.api.image_digest }
#
# so a revision produced by that action would carry the new image alongside the
# PREVIOUS image's digest. /version would report a digest that is not what is
# running, scripts/smoke.sh's fourth assertion would fail on every deploy, and
# the registered revision would be one Terraform does not know about — so the
# next infra/** merge would revert it, mid-deployment, on production.
#
# Running `terraform apply -var image_tag=...` instead lets data.aws_ecr_image
# resolve the tag to a digest ONCE, feeding both the container's image field
# and BGD_IMAGE_DIGEST from the same expression. There is one identifier for
# "what is running" and it cannot disagree with itself. Plan §D2 and §F1.
#
# What design §1.5 actually cares about is preserved: only images flow through
# this pipeline. The environment layers' Terraform is whatever is on main, and
# the single input supplied here is a tag.
#
# ---------------------------------------------------------------------------
# Two things it does that scripts/tf.sh deliberately does not
# ---------------------------------------------------------------------------
#
#  1. It enforces APP_SCOPE itself. The pipeline already skips out-of-scope
#     stages with a before_entry condition, so this is the second of two
#     independent gates. The redundancy is deliberate and the asymmetry is the
#     point: if the condition is wrong in the direction of entering a stage it
#     should have skipped, this refuses and the cost is an approval nobody
#     wanted. If this were absent and the condition were wrong that way, an
#     APP_SCOPE=staging run would deploy to production. Plan §D4, and Phase 7
#     §F2 for why MATCHES cannot be confirmed offline.
#
#  2. It records the tag in SSM — AFTER the apply returns 0, never before.
#     Plan §D9, argued at the call itself.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform
require_cmd aws

ROOT="$(repo_root)"
REGION="${AWS_REGION:-us-east-1}"

# Relative to the layer directory, because scripts/tf.sh runs terraform with
# -chdir. Named to match .gitignore's *.tfplan, so a copy pulled down for
# debugging cannot be committed.
PLAN_FILE="pipeline.tfplan"
VARS_FILE="$ROOT/plan-vars.env"
DEPLOY_VARS_FILE="$ROOT/deploy-vars.env"

mode="${1:-}"
env_name="${2:-}"
[[ -n "$mode" && -n "$env_name" ]] || die "usage: pipeline-deploy.sh <deploy|plan|apply> <staging|prod>"

# Cumulative scope: the value names where a run STOPS, so a rank comparison is
# the whole rule. `build` builds and pushes without deploying, which is what
# Phase 11 needs to put a deliberately broken image in the registry before
# deciding to deploy it.
#
# An unrecognised scope ranks 0, which is below every environment, so nothing
# runs — and it is rejected by name below rather than being allowed to behave
# like a silent `build`. Plan §D3.
scope_rank() {
  case "$1" in
    build) echo 1 ;;
    staging) echo 2 ;;
    all) echo 3 ;;
    *) echo 0 ;;
  esac
}

env_rank() {
  case "$1" in
    staging) echo 2 ;;
    prod) echo 3 ;;
    *) echo 99 ;;
  esac
}

# The marker's four values mapped onto env_rank's scale.
#
# The marker speaks DEPLOY_SCOPE's vocabulary — foundation, network, staging,
# all — and this script ranks environments, not layers. `foundation` and
# `network` both mean "neither environment exists", so both map below staging.
#
# Deliberately a mapping rather than a shared rank table: the two scales
# measure different things and collapsing them would put `build` and `network`
# on the same number, which is true of nothing. Plan §D5.
marker_env_rank() {
  case "$1" in
    foundation | network) echo 1 ;;
    staging) echo 2 ;;
    all) echo 3 ;;
    *) echo 0 ;;
  esac
}

# Written on every path out of deploy mode, including the skip.
#
# The skip case is not optional. pipelines/app-deploy.yml sources this file,
# and a missing file would fail the build — turning a correct skip into a red
# stage, which is the exact failure the ordering below exists to prevent.
write_deploy_vars() {
  {
    printf 'SMOKE_URL=%q\n' "$1"
    printf 'SMOKE_DIGEST=%q\n' "$2"
  } >"$DEPLOY_VARS_FILE"
}

# The tag reaching Terraform comes from #{Build.IMAGE_TAG}, never from SSM.
# D9's corollary: SSM is the record of what IS deployed, not the channel by
# which a run discovers what it is deploying. Reading it here would let an
# infra/** merge landing mid-run change what this run deploys.
require_image_tag() {
  [[ -n "${IMAGE_TAG:-}" ]] ||
    die "IMAGE_TAG is unset — the pipeline action must pass it as #{Build.IMAGE_TAG}"
  [[ "$IMAGE_TAG" != "unset" && "$IMAGE_TAG" != "None" ]] ||
    die "IMAGE_TAG is '$IMAGE_TAG' — the Build stage did not export a tag, and deploying that literal would fail one layer deeper in data.aws_ecr_image"
}

# Only after the apply returned 0, and this is the whole of D9.
#
# The parameter records what IS deployed rather than what someone intended to
# deploy. Two consequences, and the first is a genuine hole the other ordering
# opens:
#
#   - if the Build stage wrote both parameters up front, an infra/** merge
#     landing between Build and the production approval would plan production
#     against the new tag and deploy it. The approval that stands between a
#     merge and production would have been bypassed by a DIFFERENT pipeline,
#     with every stage of both runs green.
#
#   - a production deployment that bakes badly and rolls back fails the apply.
#     This is not reached, and the parameter still names the image actually
#     serving — so the next infra/** plan is a no-op rather than a re-attempt
#     of the deployment that just rolled back.
record_image_tag() {
  aws ssm put-parameter \
    --region "$REGION" \
    --name "/bgd/${1}/image_tag" \
    --value "$IMAGE_TAG" \
    --type String \
    --overwrite >/dev/null
  ok "/bgd/${1}/image_tag now records $IMAGE_TAG"
}

# ---------------------------------------------------------------------------
# Gate 1 of 1 in this script, and gate 2 of 2 in the pipeline.
# ---------------------------------------------------------------------------

scope="${APP_SCOPE:-}"
[[ -n "$scope" ]] ||
  die "APP_SCOPE is unset — the pipeline action must pass it as an EnvironmentVariables override"

(($(scope_rank "$scope") > 0)) ||
  die "APP_SCOPE is '$scope'; expected one of build, staging, all"

(($(env_rank "$env_name") < 99)) ||
  die "unknown environment: $env_name (expected staging or prod)"

case "$mode" in
  deploy | plan | apply) ;;
  *) die "unknown mode: $mode (expected deploy, plan or apply)" ;;
esac

# Before the saved-plan check below, deliberately, and repeated here rather
# than referenced because getting it backwards turns a correct skip into a red
# stage: an out-of-scope apply would die on a plan file the skipped plan never
# wrote, and the operator would read `no saved plan` where the truth is
# `nothing to do`.
if (($(env_rank "$env_name") > $(scope_rank "$scope"))); then
  info "$env_name is outside APP_SCOPE=$scope — nothing to do"
  case "$mode" in
    deploy) write_deploy_vars "" "" ;;
    plan) write_vars "skipped" "Skipped. $env_name is outside APP_SCOPE=$scope." "$(build_url)" ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Gate 2: the platform marker
# ---------------------------------------------------------------------------
#
# APP_SCOPE says how far this run wants to go; the marker says how far the
# platform actually is. Deploying an image into an environment `make teardown`
# destroyed fails at the remote-state read — which since Phase 9 also sends an
# email and counts in change-failure-rate. Skipping green instead costs a line
# in the console and tells the truth. Plan §D5.
#
# Unlike pipeline-terraform.sh there is no exemption: both environments are
# above the marker's floor, and the Build stage — which legitimately runs while
# the platform is down, and whose image is waiting when it comes back — is a
# different script that never reaches here.
deployed="$(read_deployed_scope)"

if (($(env_rank "$env_name") > $(marker_env_rank "$deployed"))); then
  info "$env_name is torn down ($DEPLOYED_SCOPE_PARAM = $deployed) — nothing to do"
  info "run \`make rebuild\` to bring it back"
  case "$mode" in
    deploy) write_deploy_vars "" "" ;;
    plan) write_vars "skipped" "Skipped. $env_name is torn down ($DEPLOYED_SCOPE_PARAM = $deployed); run make rebuild." "$(build_url)" ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# deploy — staging applies directly, because staging IS the gate
#
# One action, not plan-then-approve. Staging's stated job is to fail fast
# (roadmap §Phase 5), its circuit breaker reverts a task that never becomes
# healthy, and there is nobody to approve anything at that point in the run. A
# human gate in front of the environment whose purpose is to be the gate would
# be a strange shape. Plan §D11.
# ---------------------------------------------------------------------------

if [[ "$mode" == "deploy" ]]; then
  require_image_tag

  info "deploying $IMAGE_TAG to $env_name"

  # -auto-approve, and only here. Without it the apply blocks on a prompt until
  # the build times out; with it on production, D11's approval becomes
  # decorative.
  "$ROOT/scripts/tf.sh" apply "$env_name" \
    -input=false \
    -auto-approve \
    -lock-timeout=5m \
    -var "image_tag=$IMAGE_TAG"

  record_image_tag "$env_name"

  # Read after the apply, from the layer that just ran, and handed to the smoke
  # action as action-level environment variables. That is what lets the smoke
  # build hold no AWS credentials at all — plan §D6 — and it is why
  # scripts/smoke.sh has carried the BGD_SMOKE_URL / BGD_SMOKE_DIGEST
  # overrides since Phase 5.
  layer_dir="$ROOT/infra/environments/$env_name"
  url="$(terraform -chdir="$layer_dir" output -raw api_url)"
  digest="$(terraform -chdir="$layer_dir" output -raw image_digest)"
  write_deploy_vars "$url" "$digest"

  ok "$env_name is running $IMAGE_TAG"
  dim "  url     $url"
  dim "  digest  $digest"
  exit 0
fi

# ---------------------------------------------------------------------------
# apply — the saved plan, and only the saved plan
# ---------------------------------------------------------------------------

if [[ "$mode" == "apply" ]]; then
  require_image_tag

  dir="infra/environments/$env_name"

  [[ -f "$ROOT/$dir/$PLAN_FILE" ]] ||
    die "no saved plan at $dir/$PLAN_FILE — the Plan action in this stage must run first"

  # No -var, and none is permitted: terraform rejects variables when applying a
  # saved plan, because the plan already holds the values it was made with.
  # This is also what makes the approval meaningful — the plan a human read is
  # the plan that runs. Plan §D11.
  #
  # A stale-plan error here means the layer's state moved between the plan and
  # this apply, almost always a local `make apply-prod` racing the pipeline.
  # Failing is correct; the runbook says what to do about it.
  #
  # This is also the call that blocks. The production service sets
  # wait_for_steady_state, so it does not return until green has been
  # provisioned, tested by three hooks, promoted and baked for five minutes
  # under the alarms — and a rollback fails it, which is the point.
  info "applying the saved plan for $env_name"
  "$ROOT/scripts/tf.sh" apply "$env_name" -input=false -lock-timeout=5m "$PLAN_FILE"

  record_image_tag "$env_name"

  ok "$env_name applied"
  exit 0
fi

# ---------------------------------------------------------------------------
# plan — the new tag, a saved plan, and the summary the approval displays
# ---------------------------------------------------------------------------

require_image_tag

# -detailed-exitcode is what separates "no changes" from "changes" without
# parsing prose: 0 means empty, 2 means there is a diff, 1 means the plan
# failed. Under `set -e` the 2 has to be caught, hence the `|| status=$?`.
info "planning $env_name against $IMAGE_TAG"

status=0
"$ROOT/scripts/tf.sh" plan "$env_name" \
  -input=false \
  -lock-timeout=5m \
  -detailed-exitcode \
  -out="$PLAN_FILE" \
  -var "image_tag=$IMAGE_TAG" || status=$?

dir="infra/environments/$env_name"

case "$status" in
  0)
    # Reachable, and not an error: a re-run on the same commit produces a new
    # tag for the identical manifest (plan §F6), and if that tag is already
    # deployed there is nothing to change.
    summary="No changes. $env_name is already running $IMAGE_TAG."
    ok "$summary"
    ;;
  2)
    summary="$(plan_summary "$ROOT/$dir" "$PLAN_FILE")"
    ;;
  *)
    die "terraform plan failed for $env_name (exit $status)"
    ;;
esac

write_vars "$status" "$summary" "$(build_url)"

info "plan summary: $summary"
