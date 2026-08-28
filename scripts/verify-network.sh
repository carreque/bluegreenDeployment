#!/usr/bin/env bash
#
# Phase 4's live exit criterion: a host in a private subnet reaches the
# internet, and reaches it *through the NAT gateway*.
#
# The probe is an ephemeral t4g.nano with no public IP, no key pair and no
# instance profile. Its user-data curls an echo service and writes the answer
# to /dev/console, which `get-console-output` can read back without any agent,
# any SSH and any IAM. The instance is terminated by a trap, so a failure
# half-way through does not leave it running.
#
# Asserting the observed address equals the NAT's Elastic IP is what makes this
# a proof rather than a smoke test: an instance that had somehow acquired a
# public IP, or that was sitting in a public subnet, would reach the internet
# too — and would report a different address.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd aws
require_cmd terraform
require_cmd jq

ROOT="$(repo_root)"
LAYER="$ROOT/infra/network"

# AL2023 on arm64: t4g is the cheapest family, and the image id is looked up
# rather than pinned so this keeps working after the AMI is rotated.
AMI_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
INSTANCE_TYPE="t4g.nano"
CONSOLE_TIMEOUT_SECONDS=300
POLL_INTERVAL_SECONDS=15

instance_id=""

cleanup() {
  if [[ -n "$instance_id" ]]; then
    info "terminating probe $instance_id"
    aws ec2 terminate-instances --instance-ids "$instance_id" >/dev/null 2>&1 || true
    return
  fi

  # instance_id is unset, but run-instances may still have created something
  # server-side before the CLI returned — a network drop or a signal landing
  # inside that single round trip. The Name tag is the only handle left, so
  # sweep for any probe instance still pending or running under that tag.
  local orphans
  orphans="$(aws ec2 describe-instances \
    --filters 'Name=tag:Name,Values=bgd-us-east-1-nat-probe' \
               'Name=instance-state-name,Values=pending,running' \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [[ -n "$orphans" && "$orphans" != "None" ]]; then
    warn "found orphaned probe instance(s): $orphans — terminating"
    # Deliberately unquoted: $orphans is AWS CLI's tab-separated instance-id
    # list, and terminate-instances needs each id as its own argument.
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $orphans >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

info "reading the network layer's outputs"
terraform -chdir="$LAYER" init -input=false >/dev/null 2>&1 ||
  die "could not initialise the network layer — check your AWS session (aws sso login --profile bootcamp-administrator-access) and that 'make apply-bootstrap' has been run"
outputs="$(terraform -chdir="$LAYER" output -json)" ||
  die "could not read outputs — has 'make apply-network' been run?"

subnet_id="$(jq -r '.private_subnet_ids.value[0]' <<<"$outputs")"
sg_id="$(jq -r '.task_security_group_ids.value.staging' <<<"$outputs")"
nat_ip="$(jq -r '.nat_gateway_public_ip.value' <<<"$outputs")"

[[ "$subnet_id" != "null" && -n "$subnet_id" ]] || die "no private subnet in the outputs"
[[ "$nat_ip" != "null" && -n "$nat_ip" ]] || die "no NAT gateway address in the outputs"

ami_id="$(aws ssm get-parameter --name "$AMI_PARAM" --query 'Parameter.Value' --output text)"

# The staging task security group already permits exactly what the probe needs:
# 443 out and DNS. Reusing it means the probe tests the real rules rather than
# a permissive set written for the probe.
#
# User-data goes through a temp file and file://, not an inline base64 string.
# The AWS CLI base64-encodes a file:// argument itself, which sidesteps the fact
# that GNU base64 wraps at 76 columns while BSD base64 does not — a difference
# that would make this script work on this Mac and fail in CodeBuild.
user_data_file="$(mktemp -t bgd-nat-probe)"
trap 'rm -f "$user_data_file"; cleanup' EXIT
cat > "$user_data_file" <<'CLOUDINIT'
#!/bin/bash
for _ in $(seq 1 10); do
  ip="$(curl --silent --max-time 10 https://checkip.amazonaws.com)"
  if [[ -n "$ip" ]]; then
    echo "BGD_EGRESS_IP=${ip}" > /dev/console
    exit 0
  fi
  sleep 5
done
echo "BGD_EGRESS_IP=UNREACHABLE" > /dev/console
CLOUDINIT

info "launching probe in $subnet_id"
instance_id="$(aws ec2 run-instances \
  --image-id "$ami_id" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$subnet_id" \
  --security-group-ids "$sg_id" \
  --no-associate-public-ip-address \
  --user-data "file://$user_data_file" \
  --instance-initiated-shutdown-behavior terminate \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bgd-us-east-1-nat-probe},{Key=environment,Value=shared},{Key=projectName,Value=bgd},{Key=region,Value=us-east-1},{Key=owner,Value=carreque45@gmail.com}]' \
  --query 'Instances[0].InstanceId' --output text)"

info "probe $instance_id launched; waiting for it to run"
aws ec2 wait instance-running --instance-ids "$instance_id"

info "waiting for console output (up to $((CONSOLE_TIMEOUT_SECONDS / 60)) min)"
observed=""
deadline=$((SECONDS + CONSOLE_TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  console="$(aws ec2 get-console-output --instance-id "$instance_id" --latest \
    --query 'Output' --output text 2>/dev/null || true)"
  if [[ "$console" == *BGD_EGRESS_IP=* ]]; then
    observed="$(sed -n 's/.*BGD_EGRESS_IP=\([0-9.]*\).*/\1/p' <<<"$console" | head -1)"
    [[ -n "$observed" ]] && break
    die "the probe reached no external address: private subnet egress is broken"
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

[[ -n "$observed" ]] || die "no console output after ${CONSOLE_TIMEOUT_SECONDS}s — the probe may still be booting; re-run before concluding egress is broken"

info "probe egress IP : $observed"
info "nat gateway EIP : $nat_ip"

if [[ "$observed" == "$nat_ip" ]]; then
  ok "private subnet egresses through the NAT gateway"
else
  die "egress left through $observed, not the NAT gateway at $nat_ip"
fi
