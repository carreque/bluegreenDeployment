#!/usr/bin/env bash
#
# The way back: network, then staging, then prod.
#
#   make rebuild                   all three, and smoke both environments
#   make rebuild SCOPE=staging     network and staging only
#   make rebuild SCOPE=network     the network only
#
# The mirror of teardown.sh, and the order is load-bearing in the same way:
# staging and prod both read network's outputs through remote state, so applying
# either against a network that does not exist is the failure the ordering
# exists to prevent.
#
# ---------------------------------------------------------------------------
# Two things this does that `make apply-network && make apply-staging` does not
# ---------------------------------------------------------------------------
#
#  1. It takes image_tag from SSM, exactly as scripts/pipeline-terraform.sh
#     does. Both environment layers declare image_tag with no default and the
#     local value lives in a gitignored terraform.tfvars — which is the right
#     input when you are CHANGING the tag, and the wrong one when you are
#     restoring what was deployed before a teardown. infra/foundation/ssm.tf
#     put the parameter in the surviving layer for this exact moment.
#
#     `make apply-staging` and `make apply-prod` are deliberately unchanged:
#     making tf.sh read SSM would take the by-hand override away. Plan §D10.
#
#  2. It raises /bgd/platform/deployed_scope, and it is the ONLY thing that
#     does. Written after each layer applies rather than once at the end, so a
#     rebuild that dies at prod leaves the marker reading `staging` — which is
#     true. The marker may lag reality downward; never upward. Plan §D3.
#
# Environment variables:
#   SCOPE                 network | staging | prod   (default: prod)
#   BGD_REBUILD_DRY_RUN=1 print the plan, run every precondition, and stop before
#                         the first apply. Answers "could I rebuild right now?"

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform
require_cmd aws

ROOT="$(repo_root)"
REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT="${AWS_ACCOUNT_ID:-590184028094}"
STATE_BUCKET="${BGD_STATE_BUCKET:-bgd-us-east-1-tfstate-${EXPECTED_ACCOUNT}}"

SCOPE="${SCOPE:-prod}"

# Cumulative, naming where the run stops, and refusing an unrecognised value by
# name for the same reason teardown does. foundation is not a value: it survived
# the teardown by construction, and this script never applies it. Plan §D7.
case "$SCOPE" in
  network) REBUILD_ORDER=(network) ;;
  staging) REBUILD_ORDER=(network staging) ;;
  prod) REBUILD_ORDER=(network staging prod) ;;
  *) die "SCOPE is '$SCOPE'; expected one of network, staging, prod" ;;
esac

# The marker value each layer's success earns. Derived from the layer rather
# than typed twice, so a reordering cannot leave the two disagreeing.
marker_after() {
  case "$1" in
    network) echo network ;;
    staging) echo staging ;;
    prod) echo all ;;
  esac
}

echo
info "rebuild scope: $SCOPE"
echo
printf '  will apply, in order:\n'
for layer in "${REBUILD_ORDER[@]}"; do
  printf '    %s\n' "$layer"
done
printf '\n  will record:  %s = %s\n\n' \
  "$DEPLOYED_SCOPE_PARAM" "$(marker_after "${REBUILD_ORDER[${#REBUILD_ORDER[@]} - 1]}")"

# ---------------------------------------------------------------------------
# Preconditions — all read-only, all before a dollar is spent
# ---------------------------------------------------------------------------
#
# The order is by what each one costs to get wrong. The account is first because
# a rebuild into the wrong one is not recoverable by re-running it; the image
# tags are last of the reads but still ahead of every apply, because discovering
# a wrong tag at the staging layer means the NAT gateway already exists and has
# started billing. Ten seconds of read-only calls moves that discovery to before
# the first resource. Plan §D10.

info "preconditions"

account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" ||
  die "no AWS session — run: aws sso login --profile ${AWS_PROFILE:-bootcamp-administrator-access}"
[[ "$account" == "$EXPECTED_ACCOUNT" ]] ||
  die "wrong account: session is $account, this project is $EXPECTED_ACCOUNT"
ok "account $account"

aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1 ||
  die "state bucket $STATE_BUCKET is unreachable — bootstrap has not been applied, or the session cannot see it"
ok "state bucket $STATE_BUCKET"

aws s3api head-object --bucket "$STATE_BUCKET" --key foundation/terraform.tfstate >/dev/null 2>&1 ||
  die "foundation has no state — apply it before rebuilding anything above it"
ok "foundation state present"

deployed="$(read_deployed_scope)"
info "marker currently reads $deployed"

# The two environment layers only. There is no container in the network layer,
# so a SCOPE=network rebuild needs no tag and must not demand one.
declare -a IMAGE_TAGS=()
for layer in "${REBUILD_ORDER[@]}"; do
  case "$layer" in
    staging | prod) ;;
    *) continue ;;
  esac

  param="/bgd/${layer}/image_tag"
  tag="$(aws ssm get-parameter --region "$REGION" --name "$param" \
    --query 'Parameter.Value' --output text 2>/dev/null)" ||
    die "cannot read $param — apply the foundation layer before rebuilding $layer"

  if [[ -z "$tag" || "$tag" == "unset" || "$tag" == "None" ]]; then
    die "$param is '$tag' — run 'make seed-ecr' to record a tag, or let the app pipeline set one"
  fi

  # The check that moves a failure from after the NAT gateway to before it.
  aws ecr describe-images --region "$REGION" \
    --repository-name "${BGD_ECR_REPOSITORY:-bgd-us-east-1-api}" \
    --image-ids "imageTag=$tag" >/dev/null 2>&1 ||
    die "$param names '$tag', which is not in ECR — data.aws_ecr_image would fail at the $layer layer, after the network already exists and is billing"

  IMAGE_TAGS+=("$layer=$tag")
  ok "$param → $tag, present in ECR"
done

# The dry run stops HERE rather than before the block above, and the placement
# is the whole value of the flag: a dry run that checks nothing tells you
# nothing. Stopping here means `BGD_REBUILD_DRY_RUN=1 make rebuild` answers
# "could I rebuild right now?" — session, account, state, marker, both tags and
# both images — for the price of six read-only calls and no resources.
if [[ -n "${BGD_REBUILD_DRY_RUN:-}" ]]; then
  echo
  ok "dry run — preconditions pass; nothing was applied and nothing was written"
  exit 0
fi

# Dies rather than returning empty on a miss. An empty tag would reach
# terraform as `-var image_tag=`, which fails in data.aws_ecr_image with a
# message about an empty tag rather than about this lookup — one layer away
# from the cause, after the network has applied.
tag_for() {
  local layer="$1" entry
  for entry in ${IMAGE_TAGS[@]+"${IMAGE_TAGS[@]}"}; do
    if [[ "${entry%%=*}" == "$layer" ]]; then
      printf '%s' "${entry#*=}"
      return 0
    fi
  done
  die "no image tag was resolved for $layer — the preconditions above should have made this impossible"
}

# ---------------------------------------------------------------------------
# The applies
# ---------------------------------------------------------------------------

declare -a TIMINGS=()

for layer in "${REBUILD_ORDER[@]}"; do
  info "$layer — terraform apply"
  started=$SECONDS

  tf_vars=()
  case "$layer" in
    staging | prod) tf_vars=(-var "image_tag=$(tag_for "$layer")") ;;
  esac

  "$ROOT/scripts/tf.sh" apply "$layer" \
    -auto-approve -input=false -lock-timeout=5m \
    ${tf_vars[@]+"${tf_vars[@]}"} ||
    die "apply failed for $layer; later layers were not touched. The marker still reads what was true before this layer."

  # After the apply, never before: the marker must not claim a layer that did
  # not finish. Plan §D3.
  write_deployed_scope "$(marker_after "$layer")"

  elapsed=$((SECONDS - started))
  TIMINGS+=("$layer|applied|$elapsed")
  ok "$layer applied in $((elapsed / 60))m$((elapsed % 60))s"

  # Smoke each environment as it lands, and stop before the next one if it
  # fails. scripts/smoke.sh asserts that /version's image_digest equals the
  # digest Terraform deployed, which is exactly the question a rebuild raises —
  # and it is the same script Phase 8's pipeline runs. Staging failing here is
  # what keeps prod from being applied on top of a broken rebuild. Plan §D11.
  case "$layer" in
    staging | prod)
      started=$SECONDS
      "$ROOT/scripts/smoke.sh" "$layer" ||
        die "$layer applied but does not serve traffic; later layers were not touched"
      elapsed=$((SECONDS - started))
      TIMINGS+=("$layer smoke|passed|$elapsed")
      ;;
  esac
done

# ---------------------------------------------------------------------------
# What it cost in time — this is where the runbook's number comes from
# ---------------------------------------------------------------------------

echo
printf '  %-16s %-12s %s\n' "step" "outcome" "time"
printf '  %-16s %-12s %s\n' "----" "-------" "----"
total=0
for row in "${TIMINGS[@]}"; do
  IFS='|' read -r name outcome elapsed <<<"$row"
  printf '  %-16s %-12s %dm%02ds\n' "$name" "$outcome" "$((elapsed / 60))" "$((elapsed % 60))"
  total=$((total + elapsed))
done
printf '  %-16s %-12s %dm%02ds\n\n' "total" "" "$((total / 60))" "$((total % 60))"

ok "rebuild complete — $DEPLOYED_SCOPE_PARAM records $(marker_after "${REBUILD_ORDER[${#REBUILD_ORDER[@]} - 1]}")"
