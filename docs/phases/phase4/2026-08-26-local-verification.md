# Phase 4 — Local Verification

**Date:** 2026-08-26
**Branch:** `feat/Phase4_Network`
**Status:** Local gate green. **Neither of Phase 4's two exit criteria is met**
— see §4.
**Plan:** [Phase 4 implementation plan](./2026-08-26-phase-04-implementation-plan.md)
**Runbook:** [network apply, verification and teardown](../../runbooks/phase-04-network.md)

Everything Phase 4 could build and prove without an AWS session was built and
proved. **Nothing was applied.** No AWS session exists on this machine, and the
Phase 3 runbook — which creates the S3 bucket this layer's state lives in —
has not been executed either. This document records what was run, what it
returned, and what is left.

**Headline:** one Terraform layer, seventeen plan/apply-time assertions
against a mocked provider, zero AWS API calls.

---

## 1. The gate

`make tf-check` runs `validate`, `tflint`, `checkov` and `terraform test`
across all three layers now in the repository — `bootstrap`, `foundation` and
`network`. None of it needs credentials: `scripts/tf.sh` initialises with
`-backend=false`, so the whole gate runs on a machine that has never logged
in.

```
$ make tf-check

==> terraform validate — bootstrap
Success! The configuration is valid.

==> terraform validate — foundation
Success! The configuration is valid.

==> terraform validate — network
Success! The configuration is valid.

==> tflint — installing rulesets
==> tflint — bootstrap
  ✓ bootstrap clean
==> tflint — foundation
  ✓ foundation clean
==> tflint — network
  ✓ network clean
==> checkov — infra/
terraform scan results:

Passed checks: 166, Failed checks: 0, Skipped checks: 22


  ✓ checkov clean

  ✓ static analysis passed
==> terraform test — bootstrap
Success! 5 passed, 0 failed.
==> terraform test — foundation
Success! 14 passed, 0 failed.
==> terraform test — network
tests/addressing.tftest.hcl... in progress
  run "the_vpc_is_named_and_sized_by_the_convention"... pass
  run "dns_is_on_because_every_aws_endpoint_is_a_hostname"... pass
  run "the_default_security_group_permits_nothing"... pass
  run "subnets_land_one_per_tier_per_availability_zone"... pass
  run "the_address_plan_is_the_one_recorded_in_the_layer_readme"... pass
  run "no_two_subnets_overlap_even_at_four_availability_zones"... pass
  run "private_subnets_never_auto_assign_a_public_address"... pass
tests/addressing.tftest.hcl... tearing down
tests/addressing.tftest.hcl... pass
tests/outputs.tftest.hcl... in progress
  run "the_consumed_surface_is_complete_and_correctly_shaped"... pass
tests/outputs.tftest.hcl... tearing down
tests/outputs.tftest.hcl... pass
tests/routing.tftest.hcl... in progress
  run "the_nat_gateway_sits_in_a_public_subnet"... pass
  run "public_traffic_leaves_through_the_internet_gateway"... pass
  run "private_traffic_leaves_through_the_nat_gateway"... pass
  run "the_free_gateway_endpoints_keep_bulk_traffic_off_the_nat_meter"... pass
  run "flow_logs_capture_both_accepted_and_rejected_traffic"... pass
tests/routing.tftest.hcl... tearing down
tests/routing.tftest.hcl... pass
tests/security_groups.tftest.hcl... in progress
  run "there_is_one_pair_of_groups_per_environment"... pass
  run "only_production_exposes_the_blue_green_test_listener"... pass
  run "tasks_accept_traffic_only_from_their_own_environments_load_balancer"... pass
  run "the_known_task_egress_rules_are_https_and_dns_only"... pass
tests/security_groups.tftest.hcl... tearing down
tests/security_groups.tftest.hcl... pass

Success! 17 passed, 0 failed.

  all infra checks passed
```

Three layers, **36 `terraform test` run blocks** (5 + 14 + 17), zero AWS API
calls.

### 1.1 The network layer's seventeen assertions

| Suite | Run | Asserts |
|---|---|---|
| `addressing` | `the_vpc_is_named_and_sized_by_the_convention` | the VPC's CIDR and `Name` tag |
| | `dns_is_on_because_every_aws_endpoint_is_a_hostname` | `enable_dns_support`/`enable_dns_hostnames`, without which ECR, logs and DynamoDB cannot resolve |
| | `the_default_security_group_permits_nothing` | the adopted default SG has zero ingress and egress rules (checkov `CKV2_AWS_12`) |
| | `subnets_land_one_per_tier_per_availability_zone` | two AZs, two public, two private, index-aligned |
| | `the_address_plan_is_the_one_recorded_in_the_layer_readme` | the exact CIDRs — `10.0.0.0/24`, `10.0.1.0/24` public; `10.0.16.0/20`, `10.0.32.0/20` private |
| | `no_two_subnets_overlap_even_at_four_availability_zones` | the CIDR maths holds beyond the default `az_count = 2`, mutation-tested at plan time |
| | `private_subnets_never_auto_assign_a_public_address` | `map_public_ip_on_launch` is `true` on public, `false` on private |
| `outputs` | `the_consumed_surface_is_complete_and_correctly_shaped` | every output Phases 5 and 6 will read exists and is the right shape, including `vpc_id` and `nat_gateway_public_ip` by name — added in a fix round after a mutation test showed a rename of either output passed 18/18 |
| `routing` | `the_nat_gateway_sits_in_a_public_subnet` | the NAT's subnet and its Elastic IP allocation |
| | `public_traffic_leaves_through_the_internet_gateway` | the public default route and both associations |
| | `private_traffic_leaves_through_the_nat_gateway` | every private route targets the one NAT, one table per AZ, correctly paired (not both subnets to table 0) — this is also the cost-model guarantee: a second NAT actually carrying traffic fails here, since no private route targets it |
| | `the_free_gateway_endpoints_keep_bulk_traffic_off_the_nat_meter` | both endpoints are `Gateway` type, S3's service name, both associated to every private route table |
| | `flow_logs_capture_both_accepted_and_rejected_traffic` | `traffic_type = ALL`, VPC-scoped attachment, the log group name and 7-day retention, and — added in a fix round — that the flow-logs IAM policy's `resources` stay scoped to the log group rather than widening to `"*"` |
| `security_groups` | `there_is_one_pair_of_groups_per_environment` | four groups, keyed staging/prod |
| | `only_production_exposes_the_blue_green_test_listener` | `:8443` open on prod's ALB SG only |
| | `tasks_accept_traffic_only_from_their_own_environments_load_balancer` | staging and prod tasks cannot reach each other |
| | `the_known_task_egress_rules_are_https_and_dns_only` | `:443` plus `:53` UDP/TCP pinned by protocol and port — renamed from `task_egress_is_https_and_dns_rather_than_everything`, which overclaimed: it cannot catch an ADDED wide rule, only a mutation of one of the three known ones. See the "Carried forward" table below. |

Every run block that asserts a relationship between two computed ids, or reads
a block-typed attribute (the default SG's `ingress`/`egress` sets), uses
`command = apply` against the mocked provider rather than `command = plan` —
those values stay `(known after apply)` under `plan` and the assertion cannot
be evaluated at all. Nothing is created; the provider is mocked, so `apply`
here makes no API call and needs no credential.

---

## 2. Static analysis triage

### 2.1 Before and after

A probe carrying the VPC, subnets, IGW, NAT, both gateway endpoints and the
first two security groups — before flow logs, before the `CKV_AWS_260` and
`CKV_AWS_130` false positives were understood — failed on four checks:

```
Passed checks: 36, Failed checks: 4, Skipped checks: 0

CKV2_AWS_12  default security group of every VPC restricts all traffic   aws_vpc.this
CKV2_AWS_11  VPC flow logging is enabled in all VPCs                     aws_vpc.this
CKV2_AWS_5   Security Groups are attached to another resource            aws_security_group.alb
CKV2_AWS_5   Security Groups are attached to another resource            aws_security_group.task
```

The finished layer:

```
$ (checkov, network layer only)
terraform scan results:

Passed checks: 121, Failed checks: 0, Skipped checks: 10
```

`CKV2_AWS_12` was a real finding and was fixed, not skipped: the VPC's default
security group is adopted with zero rules. `CKV2_AWS_11` was fixed by building
the flow logs (D5) rather than skipped, though the plan recorded a one-line
skip as the fallback if flow logs were declined. The remaining findings are
skips, all with reasons recorded inline in the resource block.

### 2.2 The six skips in `infra/network`

| File:line | Code | Reason |
|---|---|---|
| `subnets.tf:7` | `CKV_AWS_130` | A public subnet that does not assign public addresses cannot host a NAT gateway or an internet-facing ALB's nodes. The private subnets set this to `false` explicitly and pass the same check. |
| `security.tf:12` | `CKV2_AWS_5` | Attached by the ALB in Phases 5 and 6, which live in a different state file. checkov reads one directory and cannot see across layers. |
| `security.tf:32` | `CKV2_AWS_5` | Attached by the ECS service in Phases 5 and 6, which live in a different state file. Same reason as above. |
| `security.tf:52` | `CKV_AWS_260` | The ALB is the internet-facing entry point by design; port 80 must accept `0.0.0.0/0` so a browser can reach the listener that immediately redirects to 443. Nothing behind this port serves plaintext. |
| `flowlogs.tf:7` | `CKV_AWS_338` | Seven-day retention is deliberate; these are a debugging aid for an ephemeral layer that is destroyed when idle, and retention is the entirety of what they cost. See plan §D5. |
| `flowlogs.tf:8` | `CKV_AWS_158` | AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. Flow logs carry addresses and byte counts, not payloads or secrets. |

**Both `CKV2_AWS_5` skips are the class of finding Phase 3 predicted**:
checkov is correct for a generic account and wrong for a project split across
five state files by design. The security groups genuinely are attached — just
not in the same `terraform plan` checkov can see.

`tflint` 0.60.0 with AWS ruleset 0.44.0 reports **no findings** on the network
layer.

---

## 3. No AWS resource was created

No AWS session exists on this machine. The two scripts this phase built were
each run as far as their own local guards reach and no further.

**`scripts/teardown.sh`**, run with no session — the skip path from Task 9:

```
$ ./scripts/teardown.sh

==> teardown order: prod staging network  (foundation and bootstrap are never destroyed)

==> prod — no .tf files yet, skipping
==> staging — no .tf files yet, skipping
==> network — terraform destroy
==> terraform destroy — network
╷
│ Error: validating provider credentials: retrieving caller identity from STS: operation error STS: GetCallerIdentity, https response error StatusCode: 403, RequestID: d6291d11-8176-4a99-9a83-d283db43e934, api error InvalidClientTokenId: The security token included in the request is invalid
│ 
│ 
╵
  ✗ destroy failed for network; later layers were not touched
exit: 1
```

`prod` and `staging` are correctly and loudly skipped — no `.tf` files exist
for either yet — and the script stops on the first real destroy attempt at the
first credential check, rather than proceeding past it.

**`scripts/verify-network.sh`**, run with no session and no applied state —
the failure from Task 8:

```
$ ./scripts/verify-network.sh
==> reading the network layer's outputs
  ✗ could not initialise the network layer — check your AWS session (aws sso login --profile bootcamp-administrator-access) and that 'make apply-bootstrap' has been run
exit: 1
```

Both scripts fail at the earliest point that needs an AWS session, with a
message naming what to fix — which is both the intended behaviour and the
only verification of it available in this session.

---

## 4. What remains before Phase 4's exit criteria are met

Roadmap §3 gives Phase 4 two exit criteria. Neither is met by this branch —
both need [the runbook](../../runbooks/phase-04-network.md), which needs an
AWS session and a completed Phase 3 apply, neither of which this machine has.

- [ ] Confirm `bgd-us-east-1-tfstate-590184028094` exists (runbook §1) —
      **blocked on the Phase 3 runbook having been executed first**
- [ ] `aws sso login --profile bootcamp-administrator-access` (runbook §2)
- [ ] `make tf-check` against the real toolchain (runbook §3) — expected
      green; this is a re-run of §1 above, not a new gate
- [ ] `make plan-network` — confirm ~30 resources to add, 0 to change or
      destroy (runbook §4)
- [ ] `make apply-network` (runbook §5) — **`terraform apply` succeeds
      cleanly**, the first exit criterion
- [ ] `make verify-network` (runbook §6) — **a task in a private subnet can
      reach the internet through NAT**, the second exit criterion
- [ ] Confirm flow-log records are arriving (runbook §7)
- [ ] Confirm the real NAT/EIP cost against the pricing API and amend roadmap
      §3 (runbook §8)
- [ ] `make teardown` (runbook §9) — a destroy that has never been run is a
      claim, not a proven capability
- [ ] Rebuild once and re-verify (runbook §10) — proves the layer is
      reproducible, not merely applied once

Until then the branch's own gate is `make tf-check`, and it is green.

---

## 5. Carried forward

| Item | Why it matters |
|---|---|
| **The single-NAT AZ dependency** | One NAT Gateway, in one AZ, shared by both environments (design §3.1's recorded cost trade). If `us-east-1a` fails, tasks in `us-east-1b` lose all egress. Per-AZ private route tables mean adding a second NAT is a one-line change if that trade ever stops being acceptable. |
| **The cost figure is unverified until the runbook confirms it** | Roadmap §3's ~$34/month was arithmetic against published rates, not a measurement — no AWS session existed when the plan was written. Since 1 February 2024 AWS also bills the NAT Gateway's in-use Elastic IP (~$3.60/month on top of the ~$32.85/month gateway rate), which the original estimate may not have included. Runbook §8 checks it against the pricing API and amends the roadmap with the real number. |
| **`verify-network.sh` is the only script in the repository that creates an AWS resource outside Terraform** | An ephemeral EC2 probe, terminated by an `EXIT` trap on every code path plus a tag-based sweep for an orphan the trap's own variable might have missed (a network drop or signal landing inside the single `run-instances` round trip). **A `SIGKILL` still leaks it** — no trap runs, and this is a universal bash limitation rather than something fixable in this script. The tag (`Name=bgd-us-east-1-nat-probe`, plus the four convention tags) is what makes a leaked instance findable and attributable if that happens. |
| **The flow-logs IAM policy is asserted by a test, but IAM *behaviour* generally cannot be tested here** | `flow_logs_capture_both_accepted_and_rejected_traffic` asserts the policy document's configured `resources` list stays scoped to the log group rather than widening to `"*"`, and a mutation test proved the assertion actually fails when the scope is widened. What it tests is the **configured input** to `data.aws_iam_policy_document`, which keeps its real values under `mock_provider` even though the document's rendered `.json` is mocked. Whether AWS actually enforces that policy the way the JSON implies is not something a mocked provider can exercise at all — that is only provable against a real account. |
| **An ADDED wide egress rule on the task security groups is not caught by any automated gate** | `the_known_task_egress_rules_are_https_and_dns_only` (`security_groups.tftest.hcl`) pins protocol and port on the three known task-egress rules, so mutating one of them into `-1`/all-traffic fails the suite. It cannot catch a *fourth* `aws_vpc_security_group_egress_rule` added alongside those three — `terraform test` has no "and nothing else exists" assertion over a `for_each`-generated set of resources, so an added resource is invisible to any run block written against the known ones. checkov does not fill the gap either: its open-egress checks fire on `aws_security_group` inline `egress` blocks, not on this layer's standalone `aws_vpc_security_group_egress_rule` resources — proven by mutation: a fourth rule with `ip_protocol = "-1"` to `0.0.0.0/0` passed both the test suite and checkov before this fix round. Review is currently the only control for this specific case. |
