#!/usr/bin/env bash
#
# Ordered teardown: prod, then staging, then network. foundation and bootstrap
# are never touched — that is the whole reason the five-layer split exists
# (roadmap §1), and there is deliberately no SCOPE value and no flag that
# reaches either of them (plan §D16).
#
#   make teardown                  destroy all three
#   make teardown SCOPE=staging    destroy prod and staging, leave the network
#   make teardown SCOPE=prod       destroy prod only
#
# Order is not cosmetic. Destroying network first would strand the ALBs and ECS
# services that depend on its subnets, and the destroy would fail part-way with
# a dependency violation, leaving the expensive half running.
#
# ---------------------------------------------------------------------------
# The marker is written BEFORE the first destroy
# ---------------------------------------------------------------------------
#
# /bgd/platform/deployed_scope records how deep the platform is applied, and
# both pipeline drivers clamp their scope to it. Writing it first is what makes
# the rule "the marker never overstates what exists" hold at both ends:
#
#   - writing it afterwards leaves a window, the whole length of the destroy,
#     in which a merge to main lands, reads `all`, and starts applying into an
#     account being dismantled underneath it
#   - a teardown that dies half-way would never write it at all, leaving both
#     pipelines believing production is up when prod is what was destroyed first
#
# The direction this accepts — the marker understating, saying `foundation`
# while a half-destroyed staging still exists — costs a skipped stage and a line
# in the console. The other direction costs a deployment into an account that
# cannot serve it. Plan §D3.
#
# Environment variables:
#   SCOPE                  prod | staging | network   (default: network)
#   BGD_ASSUME_YES=1       skip the confirmation, for the runbook and for a
#                          re-run after a partial failure
#   BGD_TEARDOWN_DRY_RUN=1 print the plan and exit; destroy nothing, write
#                          nothing

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform
require_cmd aws

ROOT="$(repo_root)"

SCOPE="${SCOPE:-network}"

# Cumulative, naming where the run STOPS — the rule DEPLOY_SCOPE and APP_SCOPE
# already use, pointed the way this script travels. An unrecognised value is
# refused by name rather than falling back to the safe end: a SCOPE=staginng
# typo that silently tore down everything would be a bad surprise, and one that
# silently tore down nothing while printing success would be worse. Plan §D7.
case "$SCOPE" in
  prod) TEARDOWN_ORDER=(prod) SURVIVING_SCOPE=staging ;;
  staging) TEARDOWN_ORDER=(prod staging) SURVIVING_SCOPE=network ;;
  network) TEARDOWN_ORDER=(prod staging network) SURVIVING_SCOPE=foundation ;;
  *) die "SCOPE is '$SCOPE'; expected one of prod, staging, network" ;;
esac

# ---------------------------------------------------------------------------
# What is about to happen, in full, before anything happens
# ---------------------------------------------------------------------------

echo
info "teardown scope: $SCOPE"
echo
printf '  will destroy, in order:\n'
for layer in "${TEARDOWN_ORDER[@]}"; do
  printf '    %s\n' "$layer"
done
printf '\n  will survive: foundation and bootstrap are never destroyed'
case "$SCOPE" in
  prod) printf ', and so are network and staging\n' ;;
  staging) printf ', and so is network\n' ;;
  *) printf '\n' ;;
esac
printf '  will record:  %s = %s\n\n' "$DEPLOYED_SCOPE_PARAM" "$SURVIVING_SCOPE"

if [[ -n "${BGD_TEARDOWN_DRY_RUN:-}" ]]; then
  ok "dry run — nothing was destroyed and nothing was written"
  exit 0
fi

# One typed confirmation, not three Terraform prompts. The first cut relied on
# terraform's own `yes` prompt per layer and called that the safety; three
# identical prompts in a row is how the third one gets answered by reflex. The
# word rather than a letter for the same reason. Plan §D8.
if [[ -z "${BGD_ASSUME_YES:-}" ]]; then
  printf '  type "destroy" to continue: '
  read -r reply
  [[ "$reply" == "destroy" ]] || die "aborted — nothing was destroyed and no marker was written"
fi

# ---------------------------------------------------------------------------
# The marker, then the destroys
# ---------------------------------------------------------------------------

write_deployed_scope "$SURVIVING_SCOPE"

declare -a TIMINGS=()

for layer in "${TEARDOWN_ORDER[@]}"; do
  dir="$(layer_dir "$layer")"

  # A layer with no .tf files at all is skipped and SAYS SO. Silence would be
  # the dangerous behaviour: the failure mode this guards against is the
  # production layer being quietly passed over and left running at ~$40/month.
  if [[ ! -d "$dir" ]] || ! compgen -G "$dir/*.tf" >/dev/null; then
    info "$layer — no .tf files, skipping"
    TIMINGS+=("$layer|skipped (no .tf files)|0")
    continue
  fi

  # A layer whose state holds nothing is skipped too, and this is the common
  # case on a re-run after a partial failure. `terraform destroy` against empty
  # state succeeds and spends half a minute of init doing nothing.
  #
  # The init is -backend=false-free on purpose: reading state needs the real
  # backend, so this goes through tf.sh's plan/apply init path.
  terraform -chdir="$dir" init -input=false >/dev/null 2>&1 || true
  if [[ -z "$(terraform -chdir="$dir" state list 2>/dev/null)" ]]; then
    info "$layer — state is empty, skipping"
    TIMINGS+=("$layer|skipped (already destroyed)|0")
    continue
  fi

  info "$layer — terraform destroy"
  started=$SECONDS

  # staging and prod declare image_tag with no default, and Terraform demands a
  # value for a destroy exactly as it does for an apply. Without this the
  # destroy fails before touching anything, which is how this command reached
  # 2026-08-31 unable to destroy either of the two layers it exists to destroy.
  # The value comes from the same SSM parameter rebuild.sh reads, so a teardown
  # and the rebuild that follows it agree about what was deployed.
  tf_vars=()
  case "$layer" in
    staging | prod) tf_vars=(-var "image_tag=$(resolve_image_tag "$layer")") ;;
  esac

  # -auto-approve because the single typed confirmation above replaced the
  # per-layer prompts. -lock-timeout matches both pipeline drivers: without it
  # a destroy racing a pipeline apply fails instantly on the lock rather than
  # waiting for it.
  "$ROOT/scripts/tf.sh" destroy "$layer" \
    -auto-approve -input=false -lock-timeout=5m \
    ${tf_vars[@]+"${tf_vars[@]}"} ||
    die "destroy failed for $layer; later layers were not touched. The marker already reads $SURVIVING_SCOPE, so both pipelines will skip this layer — re-run once the cause is fixed."

  elapsed=$((SECONDS - started))
  TIMINGS+=("$layer|destroyed|$elapsed")
  ok "$layer destroyed in $((elapsed / 60))m$((elapsed % 60))s"
done

# ---------------------------------------------------------------------------
# What it cost in time — measured rather than remembered
# ---------------------------------------------------------------------------

echo
printf '  %-12s %-28s %s\n' "layer" "outcome" "time"
printf '  %-12s %-28s %s\n' "-----" "-------" "----"
total=0
for row in "${TIMINGS[@]}"; do
  IFS='|' read -r layer outcome elapsed <<<"$row"
  printf '  %-12s %-28s %dm%02ds\n' "$layer" "$outcome" "$((elapsed / 60))" "$((elapsed % 60))"
  total=$((total + elapsed))
done
printf '  %-12s %-28s %dm%02ds\n\n' "total" "" "$((total / 60))" "$((total % 60))"

ok "teardown complete — $DEPLOYED_SCOPE_PARAM records $SURVIVING_SCOPE"
info "run \`make verify-idle\` to confirm nothing billable survived"
