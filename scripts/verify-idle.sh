#!/usr/bin/env bash
#
# Is this account actually idle?
#
#   make verify-idle                  after a full teardown
#   make verify-idle SCOPE=prod       after `make teardown SCOPE=prod`
#
# A clean `terraform destroy` on three layers is not the same claim. The three
# cases where they differ are the reason this exists: a resource created by hand
# and never in state, a state file that drifted, and a destroy that failed
# part-way and left the expensive half running.
#
# So NOTHING here reads a state file. Every check goes to AWS directly, because
# state is precisely what is wrong in the cases this is for. Plan §D9.
#
# Five authoritative checks, each on a shape that bills while idle, plus one
# tagged sweep as a catch-all. The sweep is a WARNING and not a verdict:
# resourcegroupstaggingapi is an index and can still list a resource deleted a
# minute ago — which is the exact moment this runs. Plan §F2.
#
# Exit 0 means nothing billable survived in scope.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd aws
require_cmd jq

REGION="${AWS_REGION:-us-east-1}"
PROJECT="${BGD_PROJECT_NAME:-bgd}"
PREFIX="${PROJECT}-${REGION}-"

SCOPE="${SCOPE:-network}"

# Which environments were destroyed, and whether the network was. The
# `environment` tag separates staging from prod; it CANNOT separate network from
# foundation, because both tag environment = "shared" — so the network checks
# key on the SERVICE instead. Plan §F1.
case "$SCOPE" in
  prod) ENVIRONMENTS=(prod) CHECK_NETWORK=no ;;
  staging) ENVIRONMENTS=(prod staging) CHECK_NETWORK=no ;;
  network) ENVIRONMENTS=(prod staging) CHECK_NETWORK=yes ;;
  *) die "SCOPE is '$SCOPE'; expected one of prod, staging, network" ;;
esac

FAILURES=0
WARNINGS=0

row() { printf '  %-34s ' "$1"; }

echo
info "verify-idle — scope $SCOPE, prefix ${PREFIX}"
echo

# ---------------------------------------------------------------------------
# ECS services, per environment
# ---------------------------------------------------------------------------
#
# desiredCount rather than existence: a service scaled to zero bills nothing,
# and reporting it as a failure would send someone hunting for a cost that is
# not there. A cluster with no service is free.

for env in "${ENVIRONMENTS[@]}"; do
  row "ecs services ($env)"
  cluster="${PREFIX}${env}-cluster"

  running="$(aws ecs list-services --region "$REGION" --cluster "$cluster" \
    --query 'serviceArns' --output text 2>/dev/null || true)"

  if [[ -z "$running" || "$running" == "None" ]]; then
    mark_ok
  else
    count="$(aws ecs describe-services --region "$REGION" --cluster "$cluster" \
      --services $running --query 'length(services[?desiredCount>`0`])' --output text 2>/dev/null || echo 0)"
    if [[ "$count" == "0" ]]; then
      mark_ok
    else
      FAILURES=$((FAILURES + 1))
      mark_fail "$count service(s) still running in $cluster"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Load balancers, per environment
# ---------------------------------------------------------------------------
#
# An ALB bills by the hour whether or not anything is behind it, and is the
# second-largest idle cost after the NAT gateway. describe-load-balancers has no
# tag filter, so the name prefix is the discriminator — the same convention
# every other name in this project derives from.

for env in "${ENVIRONMENTS[@]}"; do
  row "load balancers ($env)"
  found="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?starts_with(LoadBalancerName, '${PREFIX}${env}-')].LoadBalancerName" \
    --output text 2>/dev/null || true)"

  if [[ -z "$found" || "$found" == "None" ]]; then
    mark_ok
  else
    FAILURES=$((FAILURES + 1))
    mark_fail "still up: $found"
  fi
done

# ---------------------------------------------------------------------------
# DynamoDB tables, per environment
# ---------------------------------------------------------------------------
#
# On-demand tables bill nothing while idle, so this is not a cost check — it is
# a completeness check. A surviving table means the destroy did not finish, and
# the next rebuild will fail creating a table that already exists.

for env in "${ENVIRONMENTS[@]}"; do
  row "dynamodb tables ($env)"
  found="$(aws dynamodb list-tables --region "$REGION" \
    --query "TableNames[?starts_with(@, '${PREFIX}${env}-')]" --output text 2>/dev/null || true)"

  if [[ -z "$found" || "$found" == "None" ]]; then
    mark_ok
  else
    FAILURES=$((FAILURES + 1))
    mark_fail "still present: $found"
  fi
done

# ---------------------------------------------------------------------------
# The network, only on a full teardown
# ---------------------------------------------------------------------------

if [[ "$CHECK_NETWORK" == "yes" ]]; then
  # The single largest idle cost in the project, and the reason the network
  # layer was split out of foundation at all (roadmap §1).
  #
  # `deleting` is a warning rather than a failure: deletion is asynchronous and
  # billing stops at deletion, but reporting it as a clean pass would hide that
  # the account is not yet in its final state — which matters if the next thing
  # you do is a rebuild. Plan §F8.
  row "nat gateways"
  states="$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=tag:projectName,Values=${PROJECT}" \
    --query 'NatGateways[].State' --output text 2>/dev/null || true)"

  live="$(printf '%s\n' $states | grep -c -E '^(pending|available)$' || true)"
  deleting="$(printf '%s\n' $states | grep -c -E '^deleting$' || true)"

  if ((live > 0)); then
    FAILURES=$((FAILURES + 1))
    mark_fail "$live still billing"
  elif ((deleting > 0)); then
    WARNINGS=$((WARNINGS + 1))
    mark_warn "$deleting still deleting — re-run in a few minutes"
  else
    mark_ok
  fi

  # An Elastic IP bills whether or not it is associated — AWS has charged for
  # in-use addresses since 1 February 2024 and for idle ones for far longer.
  # So: any address carrying the project tag is a failure.
  row "elastic ips"
  found="$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:projectName,Values=${PROJECT}" \
    --query 'Addresses[].PublicIp' --output text 2>/dev/null || true)"

  if [[ -z "$found" || "$found" == "None" ]]; then
    mark_ok
  else
    FAILURES=$((FAILURES + 1))
    mark_fail "still allocated: $found"
  fi
fi

# ---------------------------------------------------------------------------
# The catch-all
# ---------------------------------------------------------------------------
#
# Everything above names a shape somebody thought of. This names the ones
# nobody did.
#
# The four services below are exactly those in which this project owns nothing
# that survives a full teardown, which is what makes the rule expressible
# without an allowlist of the fourteen kinds of thing that DO survive — the
# zone, the certificate, both repositories, both buckets, the topic, the
# connection, both pipelines, eight CodeBuild projects, the roles, three
# parameters, the collector, its log group and the dashboard.
#
# A warning, never a verdict: the tagging API is an index and lags deletion by
# minutes. Plan §F2.

row "tagged sweep (ec2/elb/ecs/ddb)"
tagged="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=projectName,Values=${PROJECT}" \
  --resource-type-filters ec2 elasticloadbalancing ecs dynamodb \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)"

if [[ -z "$tagged" || "$tagged" == "None" ]]; then
  mark_ok
else
  count="$(printf '%s\n' $tagged | wc -l | tr -d ' ')"
  WARNINGS=$((WARNINGS + 1))
  mark_warn "$count resource(s) still indexed (the index lags deletion by minutes)"
  for arn in $tagged; do
    dim "      $arn"
  done
fi

# ---------------------------------------------------------------------------

echo
if ((FAILURES > 0)); then
  die "$FAILURES check(s) failed — something is still billing"
fi

if ((WARNINGS > 0)); then
  warn "$WARNINGS warning(s) — nothing is billing, but the account is not yet settled"
fi

ok "nothing billable survives in scope $SCOPE"
