#!/usr/bin/env bash
# Shared helpers for this repository's scripts.
# Source this file; do not execute it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

set -euo pipefail

# Colour only when stdout is a terminal, so piped and CodeBuild output stay clean.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_DIM=$'\033[2m'
else
  C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_DIM=''
fi

# A second palette, keyed on stderr. Progress goes to stdout and diagnostics go
# to stderr (see below), and the two are redirected independently: `script > log`
# leaves stderr on the terminal, where colour is still wanted.
if [[ -t 2 ]]; then
  E_RESET=$'\033[0m'
  E_RED=$'\033[31m'
  E_YELLOW=$'\033[33m'
else
  E_RESET='' E_RED='' E_YELLOW=''
fi

# Progress and results go to stdout; diagnostics go to stderr.
#
# The split is not cosmetic. A helper that writes a failure to stdout and is
# called inside "$(...)" has that failure captured into the variable being
# assigned rather than shown, and under `set -e` the script then exits non-zero
# in complete silence — no message on any stream. That cost real debugging time
# in Phase 3 (scripts/tf.sh), and the fix belongs here rather than in each
# caller that has to remember to avoid the shape.
#
# Anything added below keeps this rule: if it reports a problem, it writes >&2.
info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$E_YELLOW" "$E_RESET" "$*" >&2; }
fail() { printf '%s  ✗%s %s\n' "$E_RED" "$E_RESET" "$*" >&2; }
dim() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

die() {
  fail "$*"
  exit 1
}

# Inline status marks, for the last column of a table row. Unlike ok()/fail()
# these emit no leading padding and no trailing space — and unlike fail() they
# stay on **stdout**, because the row they complete was printed there. Sending
# only the mark to stderr would split every table row across two streams and
# scramble the alignment the moment either one is redirected.
mark_ok() { printf '%s✓%s\n' "$C_GREEN" "$C_RESET"; }
mark_fail() { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET"; }
mark_warn() { printf '%s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# repo_root — absolute path to the repository root, wherever the script is called from.
repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
  }
}

# extract_version <string> — first dotted numeric version found in the string.
# Handles "git version 2.50.1 (Apple Git-155)", "Terraform v1.15.7",
# "aws-cli/2.35.4 Python/3.14.5", "jq-1.7.1", "GNU Make 3.81".
#
# Always succeeds, returning the empty string when nothing matches. Callers run
# under `set -euo pipefail`, where a bare failing grep inside a command
# substitution would abort the script instead of reporting a missing version.
extract_version() {
  printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true
}

# try <command...> — run a command, capture its first line of output, and
# never propagate a non-zero exit. For probing tools that report information
# through a failure, such as `pyenv version` on an uninstalled pin.
try() {
  "$@" 2>&1 | head -1 || true
}

# version_gte <have> <want> — true when have >= want.
# Uses a numeric field sort rather than `sort -V`, which BSD sort on macOS
# does not reliably provide.
version_gte() {
  local have="$1" want="$2" lowest
  [[ "$have" == "$want" ]] && return 0
  lowest="$(printf '%s\n%s\n' "$have" "$want" |
    sort -t. -k1,1n -k2,2n -k3,3n | head -1)"
  [[ "$lowest" == "$want" ]]
}

# ---------------------------------------------------------------------------
# Phase 2 — image build identity
# ---------------------------------------------------------------------------

# image_build_identity — set the variables that identify an image build.
#
# Sets APP_VERSION, GIT_SHA, BUILT_AT, RELEASE_COLOR, IMAGE_REF and exports
# SOURCE_DATE_EPOCH.
#
# This lives here rather than in build-image.sh because verify-image-repeatability.sh
# needs the identical derivation: if the two computed a tag differently — say one
# applied the -dirty suffix and the other did not — the repeatability check would
# prove a property of an image nobody ships. Phase 8's buildspec reads the same
# VERSION file for the same reason.
#
# Both timestamps come from the last commit rather than the wall clock, which is
# what makes the digest a function of the source. git does the formatting because
# BSD date and GNU date disagree about rendering an epoch, and this runs on macOS
# locally and Linux in CI.
# prune_repro_cache — discard the bgd-repro builder's BuildKit cache.
#
# Every build in this repository runs --no-cache, because an artifact of record
# should not be assembled from layers built at some other time. That makes the
# cache the builder writes pure dead weight: never read, but still consuming the
# Docker Desktop VM disk at roughly a gigabyte per build until it fills and
# builds start failing with "no space left on device".
#
# Only ever prunes the bgd-repro builder, never the default one, so nothing
# outside this project is touched.
prune_repro_cache() {
  docker buildx prune --all --force --builder bgd-repro >/dev/null 2>&1 || true
}

# prune_orphaned_images — drop images this project has orphaned.
#
# Each build loads a new image under the same tag, which untags the previous one
# and leaves its layers behind as a dangling image of roughly 220 MB. Twenty
# builds is four gigabytes, and the Docker Desktop VM disk fills silently until
# builds start failing with "no space left on device" — which is a confusing way
# to discover it, because the error names a COPY line rather than a full disk.
#
# Filtered on the image's own label, so it can only ever match images built from
# this repository's Dockerfile. A bare `docker image prune` would also discard
# unrelated dangling images belonging to whatever else is on the machine.
#
# Deleting a child exposes its parent as newly dangling, so this iterates rather
# than assuming one pass suffices.
prune_orphaned_images() {
  local pass
  for pass in 1 2 3 4 5; do
    docker image prune --force \
      --filter "label=org.opencontainers.image.title=bgd-api" >/dev/null 2>&1 || true
  done
}

image_build_identity() {
  local root major_minor
  root="$(repo_root)"

  major_minor="$(tr -d '[:space:]' <"$root/app/VERSION")"
  APP_VERSION="${major_minor}.${CODEBUILD_BUILD_NUMBER:-0}"

  # Phase 12. Read from the repository rather than the environment, because a
  # build input that comes from the operator's shell is not a function of the
  # source — and design §4.1 requires that two clean builds of one commit
  # produce the same digest. A colour flip is therefore a commit that flows
  # through the real pipeline, not a setting somebody exports. Plan D3.
  RELEASE_COLOR="$(tr -d '[:space:]' <"$root/app/RELEASE_COLOR")"

  GIT_SHA="$(git -C "$root" rev-parse --short=7 HEAD)"
  if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
    GIT_SHA="${GIT_SHA}-dirty"
  fi

  SOURCE_DATE_EPOCH="$(git -C "$root" log -1 --format=%ct)"
  BUILT_AT="$(TZ=UTC git -C "$root" log -1 \
    --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format=%cd)"
  IMAGE_REF="bgd-us-east-1-api:${APP_VERSION}-${GIT_SHA}"

  export SOURCE_DATE_EPOCH
}

# ---------------------------------------------------------------------------
# Phases 7 and 8 — CodeBuild pipeline helpers
# ---------------------------------------------------------------------------
#
# These three are here for the same rule image_build_identity above carries:
# two scripts that must not derive the same value differently. Phase 7's
# pipeline-terraform.sh defined them locally and was the only caller; Phase 8's
# pipeline-deploy.sh needs all three identically, and a plan summary formatted
# one way in the infra pipeline's approval and another way in the application
# pipeline's would be a difference nobody chose.
#
# All three are CodeBuild-shaped and harmless outside it: build_url returns
# empty when the CodeBuild variables are absent, which is what a local
# debugging run wants.

# write_vars <status> <summary> <url> — the three exported variables, written
# for the buildspec to source.
#
# Called on every path out of plan mode, including the skip. Without the skip
# case the approval action would interpolate the previous execution's summary,
# which is a worse failure than an empty one — it describes changes that are
# not in this run.
#
# %q quoting is what makes `set -a && . <file>` safe for a summary containing
# spaces. VARS_FILE is the caller's: both pipeline scripts set it to a
# repository-root path that .gitignore already excludes.
write_vars() {
  local status="$1" summary="$2" url="$3"
  {
    printf 'PLAN_STATUS=%q\n' "$status"
    printf 'PLAN_SUMMARY=%q\n' "$summary"
    printf 'PLAN_URL=%q\n' "$url"
  } >"$VARS_FILE"
}

# build_url — the CodeBuild console deep link for this build, so an approval
# message can offer the full plan behind the truncated summary.
#
# Built from the build ARN because that is the only place the account id
# appears in a CodeBuild environment. Empty outside CodeBuild, which is
# harmless — the field is optional.
build_url() {
  [[ -n "${CODEBUILD_BUILD_ARN:-}" ]] || return 0
  local _ arn_region arn_account project
  IFS=':' read -r _ _ _ arn_region arn_account _ <<<"$CODEBUILD_BUILD_ARN"
  project="${CODEBUILD_BUILD_ID%%:*}"
  printf 'https://%s.console.aws.amazon.com/codesuite/codebuild/%s/projects/%s/build/%s/?region=%s' \
    "$arn_region" "$arn_account" "$project" "${CODEBUILD_BUILD_ID//:/%3A}" "$arn_region"
}

# plan_summary <layer-dir> <plan-file> — one line describing a saved plan.
#
# `terraform show` on the saved plan rather than scraping the plan output, so
# the summary describes the artifact the Apply action will consume rather than
# the text that scrolled past. The Plan: line first, then the resource
# addresses, which is the order someone reads an approval in.
#
# One line, and short. A CodePipeline variable and a manual approval's
# CustomData are both capped at 1000 characters, and a newline inside a
# KEY=value line would break the `. <file>` the buildspec does. The full plan is
# one click away through PLAN_URL, which is the point of exporting it.
plan_summary() {
  local dir="$1" planfile="$2" summary
  summary="$(
    terraform -chdir="$dir" show -no-color "$planfile" |
      grep -E '^(Plan:|  # )' |
      sed 's/^  # //'
  )"
  summary="$(printf '%s' "$summary" | tr '\n' ' ' | tr -s ' ')"
  if ((${#summary} > 900)); then
    summary="${summary:0:880} … (truncated; full plan in the build log)"
  fi
  printf '%s' "$summary"
}

# ---------------------------------------------------------------------------
# Phase 10 — layers, and the platform scope marker
# ---------------------------------------------------------------------------

# layer_dir <layer> — absolute path to a layer's root module.
#
# NOTE, 2026-09-02: staging and prod now BOTH return $root/infra. The two
# environment directories were merged into one root module driven by
# environments/<env>.tfvars, so a layer name no longer identifies a directory on
# its own — see layer_var_file and layer_backend_config below.
#
# The map that tf.sh, teardown.sh and lint-infra.sh each carried a copy of, and
# that rebuild.sh would have been the fourth to copy. tf.sh's own comment asked
# for this. Plan §D13.
#
# lint-infra.sh is deliberately NOT converted: its layer_path returns a path
# relative to infra/ and has to pass an already-relative path through unchanged,
# which is a different contract from this one. Plan §F6.
#
# Errors go to stderr through die(), which matters here more than usual: this is
# always called inside "$(...)", and a die() writing to stdout would be captured
# into the variable being assigned and the caller would exit 1 in silence. That
# cost real debugging time in Phase 3; see die()'s own comment above.
layer_dir() {
  local root
  root="$(repo_root)"
  case "$1" in
    bootstrap | foundation | network) printf '%s/infra/%s\n' "$root" "$1" ;;
    staging | prod) printf '%s/infra\n' "$root" ;;
    *) die "unknown layer: $1 (expected bootstrap, foundation, network, staging or prod)" ;;
  esac
}

# staging and prod share a directory, which is the whole of the environments
# merge. What still separates them is a var file and a backend key, and the two
# helpers below are the other half of a layer's identity.
#
# They are SEPARATE functions rather than one returning both, because they are
# consumed at different moments: the backend config goes to `terraform init` and
# the var file to plan/apply, and `terraform apply <planfile>` takes the first
# and REJECTS the second — a saved plan already carries the values it was made
# with. tf.sh is what knows which moment it is in.
#
# Both print nothing for the three single-environment layers, whose backend
# blocks are still literal and which have no environment to select. Callers
# treat empty as "pass no flag" rather than as an error, which is what lets
# tf.sh stay one code path for all five layers.

# layer_var_file <layer> — absolute path to a layer's committed .tfvars, or empty.
layer_var_file() {
  local root
  root="$(repo_root)"
  case "$1" in
    staging | prod) printf '%s/infra/environments/%s.tfvars\n' "$root" "$1" ;;
    bootstrap | foundation | network) printf '' ;;
    *) die "unknown layer: $1 (expected bootstrap, foundation, network, staging or prod)" ;;
  esac
}

# layer_backend_config <layer> — absolute path to a layer's backend .hcl, or empty.
#
# This is what replaces the literal `key = "prod/terraform.tfstate"` that used to
# sit in a per-environment versions.tf. The pairing of this file with the var
# file above is the guarantee the literal block used to give for free, and it is
# why both are derived HERE from one layer name rather than typed by a caller:
# initialising prod's backend and then applying staging's variables is a valid
# sequence of commands and a catastrophic one.
layer_backend_config() {
  local root
  root="$(repo_root)"
  case "$1" in
    staging | prod) printf '%s/infra/environments/%s.backend.hcl\n' "$root" "$1" ;;
    bootstrap | foundation | network) printf '' ;;
    *) die "unknown layer: $1 (expected bootstrap, foundation, network, staging or prod)" ;;
  esac
}

# layer_init_backend <layer> — initialise a layer's REAL backend, quietly.
#
# For the callers that run `terraform output` or `terraform state list` directly
# rather than through tf.sh — smoke.sh and teardown.sh both do, deliberately,
# because they read state rather than running a Terraform command against a
# layer.
#
# Since the environments merge this is no longer optional for them. infra/ holds
# ONE .terraform directory and it remembers whichever environment's backend was
# initialised last, so reading an output without this first returns the OTHER
# environment's values — silently, with nothing on any stream to notice. A smoke
# test that read production's URL while claiming to test staging would pass, and
# be meaningless.
#
# Prints nothing on success. Failures are the caller's to interpret: teardown
# tolerates them (a layer that was never applied has no backend to read), and
# smoke turns them into a message naming the override to set instead.
layer_init_backend() {
  local dir backend_config args=()
  dir="$(layer_dir "$1")" || return 1
  backend_config="$(layer_backend_config "$1")" || return 1
  [[ -n "$backend_config" ]] && args=(-reconfigure -backend-config="$backend_config")
  terraform -chdir="$dir" init -input=false ${args[@]+"${args[@]}"} >/dev/null
}

# layer_dir_rel <layer> — a layer's root module, relative to the repository root.
#
# layer_dir's answer with the root stripped, so the two can never disagree about
# where a layer lives. Both pipeline scripts want this shape rather than the
# absolute one, for two reasons that happen to point the same way: the path is
# printed in operator-facing messages ("no saved plan at
# infra/pipeline.tfplan — the Plan action in this stage must
# run first"), where an absolute path would name a CodeBuild container's scratch
# directory rather than something the reader can act on; and it is compared
# against "$ROOT/$dir", which wants the tail.
#
# Added on 2026-09-02, when the map turned out to have SIX open-coded copies
# rather than the three Phase 10 §D13 set out to remove. Two are byte-identical
# case blocks 57 lines apart in pipeline-terraform.sh; three more are in
# pipeline-deploy.sh, whose own header comment claimed "the
# layer-name-to-directory map appears here nowhere". Phase 10 converted tf.sh
# and teardown.sh and stopped there, because the remaining callers wanted a
# relative path and layer_dir only offered an absolute one — so they kept their
# copies. This closes that gap rather than widening the map's blast radius a
# seventh time.
#
# lint-infra.sh's layer_path stays its own function, for the reason recorded
# above: it returns a path relative to infra/ rather than to the root, and has
# to pass an already-relative path through unchanged. A different contract.
#
# The `|| return 1` is load-bearing. layer_dir die()s on an unknown layer, and
# die() exits the subshell this command substitution runs in — so without it the
# non-zero status would be discarded and the caller handed an empty path, which
# under -chdir means "the current directory" and would plan the wrong layer.
layer_dir_rel() {
  local root dir
  root="$(repo_root)"
  dir="$(layer_dir "$1")" || return 1
  printf '%s\n' "${dir#"$root"/}"
}

# The four values /bgd/platform/deployed_scope holds, ranked. The SAME four
# DEPLOY_SCOPE uses, deliberately — pipeline-terraform.sh already ranks them and
# foundation/locals.tf already orders them, so a second vocabulary for the same
# idea would be a second thing to keep in step. Plan §D2.
#
# Named platform_scope_rank rather than scope_rank because pipeline-deploy.sh
# defines a scope_rank of its own over build/staging/all, and bash redefines a
# function silently. Plan §F7.
#
# An unrecognised value ranks 0, below every layer, so it can only ever produce
# "nothing is deployed" rather than a partial and unintended one.
platform_scope_rank() {
  case "$1" in
    foundation) echo 1 ;;
    network) echo 2 ;;
    staging) echo 3 ;;
    all) echo 4 ;;
    *) echo 0 ;;
  esac
}

# The layers, ranked on the same scale. `all` is not a layer, so it ranks 99
# here — above every scope — which is what makes an unknown name skip rather
# than apply.
platform_layer_rank() {
  case "$1" in
    foundation) echo 1 ;;
    network) echo 2 ;;
    staging) echo 3 ;;
    prod) echo 4 ;;
    *) echo 99 ;;
  esac
}

min_rank() {
  if (($1 < $2)); then echo "$1"; else echo "$2"; fi
}

# The marker: how deep the platform is currently applied.
#
# Written ONLY by scripts/teardown.sh and scripts/rebuild.sh, and defaulted to
# `all` by Terraform so that it can only ever restrict, and only after somebody
# explicitly ran a teardown. It is a teardown marker, not a deployment registry:
# it does not know that `make apply-prod` was run by hand. Plan §D2 and §D4.
DEPLOYED_SCOPE_PARAM="/bgd/platform/deployed_scope"

# read_deployed_scope — the marker's current value, on stdout.
#
# Dies rather than assuming `all` on a read failure, and that is the decision
# rather than an oversight: assuming `all` would mean a lost ssm:GetParameter
# permission silently restores the behaviour the marker exists to remove, with
# nothing anywhere reporting it. Plan §D6.
read_deployed_scope() {
  local value err
  # stderr is captured rather than discarded, and the reason is a real incident
  # on 2026-08-31: a transient failure of this one call produced
  #
  #   ✗ cannot read /bgd/platform/deployed_scope — apply the foundation layer,
  #     which is what creates it
  #
  # …on an account where the parameter existed and foundation was applied. The
  # message names ONE cause for a call that fails many ways — an expired SSO
  # token, a throttle, a wrong region, a genuinely absent parameter — and
  # 2>/dev/null threw away the only evidence that distinguishes them. The
  # operator went looking for a missing parameter that was never missing.
  #
  # A missing parameter is still called out by name, because it is the cause
  # with a specific remedy. Anything else now reports what AWS actually said.
  err="$(mktemp)"
  if ! value="$(aws ssm get-parameter \
    --region "${AWS_REGION:-us-east-1}" \
    --name "$DEPLOYED_SCOPE_PARAM" \
    --query 'Parameter.Value' --output text 2>"$err")"; then
    local detail
    detail="$(tr -d '\n' <"$err" | sed 's/  */ /g')"
    rm -f "$err"
    case "$detail" in
      *ParameterNotFound*)
        die "$DEPLOYED_SCOPE_PARAM does not exist — apply the foundation layer, which is what creates it"
        ;;
      *)
        die "cannot read $DEPLOYED_SCOPE_PARAM: ${detail:-the AWS CLI failed with no message}. If this is a missing parameter, apply the foundation layer, which is what creates it; otherwise check the session and the region and retry"
        ;;
    esac
  fi
  rm -f "$err"

  (($(platform_scope_rank "$value") > 0)) ||
    die "$DEPLOYED_SCOPE_PARAM is '$value'; expected one of foundation, network, staging, all"

  printf '%s' "$value"
}

# resolve_image_tag <layer> — the ECR tag recorded for staging or prod.
#
# Added 2026-08-31, because teardown.sh did not have it and could not work
# without it. Both environment layers declare image_tag with NO default (Phase 5
# D3: a stale default silently deploys an old image), and Terraform requires
# every variable to have a value for a **destroy** just as much as for an apply.
# rebuild.sh resolved the tag from SSM and teardown.sh did not, so
# `make teardown` failed on the first layer it reached with
#
#   Error: No value for required variable ... variable "image_tag"
#
# — meaning neither environment layer had ever been destroyable by the command
# whose whole purpose is destroying them. Nothing caught it because Phase 10
# created no AWS resources and the shell suite drives a fake AWS CLI, which
# answers every call and therefore never reaches Terraform's own validation.
#
# The real recorded tag rather than a placeholder, because a destroy still
# refreshes data.aws_ecr_image, and a tag that is not in the registry fails the
# read before anything is destroyed.
resolve_image_tag() {
  local layer="$1" param tag
  param="/bgd/${layer}/image_tag"

  tag="$(aws ssm get-parameter \
    --region "${AWS_REGION:-us-east-1}" \
    --name "$param" \
    --query 'Parameter.Value' --output text 2>/dev/null)" ||
    die "cannot read $param — apply the foundation layer, which is what creates it"

  [[ -n "$tag" && "$tag" != "unset" && "$tag" != "None" ]] &&
    printf '%s' "$tag" ||
    die "$param is '$tag' — run 'make seed-ecr' to record a tag, or let the app pipeline set one"
}

# write_deployed_scope <value> — record how deep the platform is applied.
#
# The read first is not a courtesy check. `put-parameter --overwrite` CREATES a
# parameter that does not exist, so without it a write against an account where
# foundation was never applied would create one outside Terraform's state — and
# the next foundation apply would fail on a name that already exists. Plan §F5.
write_deployed_scope() {
  local value="$1"

  (($(platform_scope_rank "$value") > 0)) ||
    die "refusing to write '$value' to $DEPLOYED_SCOPE_PARAM; expected one of foundation, network, staging, all"

  read_deployed_scope >/dev/null

  aws ssm put-parameter \
    --region "${AWS_REGION:-us-east-1}" \
    --name "$DEPLOYED_SCOPE_PARAM" \
    --value "$value" \
    --type String \
    --overwrite >/dev/null ||
    die "could not write $DEPLOYED_SCOPE_PARAM"

  ok "$DEPLOYED_SCOPE_PARAM now records $value"
}
