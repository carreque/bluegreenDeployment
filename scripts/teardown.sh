#!/usr/bin/env bash
#
# Ordered teardown: prod, then staging, then network. foundation and bootstrap
# are never touched — that is the whole reason the five-layer split exists
# (roadmap §1).
#
# Order is not cosmetic. Destroying network first would strand the ALBs and ECS
# services that depend on its subnets, and the destroy would fail part-way with
# a dependency violation, leaving the expensive half running.
#
# A layer with no .tf files at all is skipped and *says so*. Silence would be
# the dangerous behaviour: the failure mode this guards against is Phase 6's
# production layer being quietly passed over and left running at ~$40/month.
#
# No -auto-approve. Terraform's own confirmation prompt is the safety, so this
# first cut needs no confirmation logic of its own. Phase 10 hardens it.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform

ROOT="$(repo_root)"

TEARDOWN_ORDER=(prod staging network)

echo
info "teardown order: ${TEARDOWN_ORDER[*]}  (foundation and bootstrap are never destroyed)"
echo

for layer in "${TEARDOWN_ORDER[@]}"; do
  dir="$(layer_dir "$layer")"

  if [[ ! -d "$dir" ]] || ! compgen -G "$dir/*.tf" >/dev/null; then
    info "$layer — no .tf files yet, skipping"
    continue
  fi

  info "$layer — terraform destroy"
  "$ROOT/scripts/tf.sh" destroy "$layer" || die "destroy failed for $layer; later layers were not touched"
done

echo
ok "teardown complete — foundation and bootstrap intact"
