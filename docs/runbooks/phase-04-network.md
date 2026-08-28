# Runbook — Phase 4: network apply, verification and teardown

**Date:** 2026-08-26
**Layer:** `infra/network`
**Estimated time:** 10–15 minutes for the apply-verify-teardown cycle, plus a
second apply in step 10 to prove the layer rebuilds
**Cost while it exists:** roadmap §3 says ~$34/month. Step 8 below is what
confirms that figure rather than repeating it.

This runbook creates and destroys the first layer that costs real money when
idle. The Terraform it applies was written and verified in Phase 4 without an
AWS session; this is the half that needs one. Unlike Phase 3, this layer is not
meant to stay up between sessions — steps 9 and 10 tear it down and rebuild it
within this same runbook, because leaving a NAT Gateway running between
sessions is exactly the cost this layer exists to avoid paying by accident.

---

## 1. Precondition — Phase 3 has been executed

`network` keeps its state in the bucket `bootstrap` creates. If that bucket
does not exist, nothing below will work — not even `terraform init`.

```bash
aws s3api head-bucket --bucket bgd-us-east-1-tfstate-590184028094
```

Expected: no output, exit `0`. A `404`/`403` here means **stop** — go run [the
Phase 3 runbook](./phase-03-bootstrap-and-foundation.md) first. Do not proceed
past this step on a guess that the bucket "probably" exists.

---

## 2. AWS session

```bash
aws sso login --profile bootcamp-administrator-access
make verify-aws
```

Expected: account `590184028094`, region `us-east-1`, both ticked.

---

## 3. Re-run the offline gate against the real toolchain

```bash
make tf-check
```

Expected: `all infra checks passed`. This was captured green on 2026-08-26 with
no AWS session — `terraform validate`, `tflint`, `checkov` (166 passed, 0
failed, 22 skipped across the three layers), and `terraform test`, ending with
the network layer's own suite:

```
==> terraform test — network
...
Success! 18 passed, 0 failed.

  all infra checks passed
```

A failure here is a code problem, not a credentials problem — re-run it before
touching `plan` or `apply`, on the theory that the offline gate is cheaper to
debug than a half-applied layer.

---

## 4. Plan

```bash
make plan-network
```

**What to read in the plan: roughly 30 resources to add, and zero to change or
destroy.** In particular, confirm the plan shows exactly:

- one `aws_nat_gateway` and one `aws_eip`
- four `aws_security_group` (staging/prod × alb/task)
- two `aws_vpc_endpoint` (S3 and DynamoDB, both `Gateway` type — not
  `Interface`; an `Interface` type here would mean the wrong file got applied)

If the plan proposes changing or destroying anything, stop — this is a first
apply against empty state, and a change/destroy means the state file already
disagrees with what is on this branch.

---

## 5. Apply

```bash
make apply-network
```

Expect **3–5 minutes**, almost all of it the NAT Gateway, which alone takes
about two minutes to become `available`. The apply is not hung during that
wait; it is polling AWS for gateway state.

---

## 6. Verify — the first exit criterion

```bash
make verify-network
```

This launches an ephemeral probe instance in a private subnet, reads back what
public address its outbound traffic appears to come from, and asserts that
address equals the NAT Gateway's Elastic IP — proof of the path, not just proof
that something reached the internet. Expected output, from
`scripts/verify-network.sh`:

```
==> probe egress IP : <the observed address>
==> nat gateway EIP : <the same address>
  ✓ private subnet egresses through the NAT gateway
```

If the two addresses differ, egress left through something other than the NAT
— see "What goes wrong" below before assuming the layer is broken.

---

## 7. Confirm the flow logs are receiving records

Skip this step if D5 was declined during Phase 4 and flow logs were not built
(check for `infra/network/flowlogs.tf` — if it does not exist, this step does
not apply).

```bash
aws logs describe-log-streams \
  --log-group-name /bgd/us-east-1/shared/vpc-flow \
  --query 'logStreams[0].lastEventTimestamp'
```

**An empty result immediately after the apply is expected, not a fault.**
`max_aggregation_interval` is 60 seconds and CloudWatch delivery is batched;
the first records can take up to 10 minutes to appear. Re-run this later in
the session rather than treating a null timestamp as a defect right after
step 5.

---

## 8. Confirm the real cost

Roadmap §3 currently carries **~$34/month**, and the Phase 4 plan flagged this
figure as probably low: it was derived from published rates, not measured,
because no AWS session was available when the plan was written. AWS has billed
in-use public IPv4 addresses since 1 February 2024, and a NAT Gateway's
Elastic IP is one — so the true figure is expected to be closer to **the NAT
Gateway's hourly rate (~$32.85/month) plus the public IPv4 charge
(~$3.60/month) plus data processing**, roughly **$36–37/month** before any
traffic is served.

Confirm this against the pricing API rather than trusting either number:

```bash
aws pricing get-products --service-code AmazonEC2 --region us-east-1 \
  --filters 'Type=TERM_MATCH,Field=productFamily,Value=NAT Gateway' \
             'Type=TERM_MATCH,Field=regionCode,Value=us-east-1'

aws pricing get-products --service-code AmazonVPC --region us-east-1 \
  --filters 'Type=TERM_MATCH,Field=productFamily,Value=PublicIPv4Address' \
             'Type=TERM_MATCH,Field=regionCode,Value=us-east-1'
```

**Amend [the roadmap's §3 cost table](../2026-08-04-implementation-phase-roadmap.md)
with whatever number this actually returns.** Treat the figure above as an
expectation to verify, not a fact to copy in — it was never measured against a
live account.

---

## 9. Teardown — the second exit criterion

```bash
make teardown
```

**Run it — do not skip this step to save time.** A `terraform destroy` that
has never been executed against a real account is a claim in a document, not a
proven capability, and this is the layer whose whole design point is that it
destroys cleanly. It is also destroyed at the end of every working session
(session teardown practice): the foundation persists, `network` does not.

Expected: `teardown order: prod staging network`, then `prod` and `staging`
report "no .tf files yet, skipping" (Phases 5 and 6 have not landed), then
`network — terraform destroy` runs and completes with no dependency-violation
error, ending in `teardown complete — foundation and bootstrap intact`.

---

## 10. Rebuild once, and re-verify

```bash
make apply-network
make verify-network
```

This is what proves the layer is genuinely reproducible rather than merely
applied once and never touched again. A layer that only ever sees one apply in
its lifetime has not demonstrated that a second `apply` from clean state
produces the same working thing — this step is that demonstration. Expected
output is identical in shape to steps 5 and 6.

Once this is confirmed, run `make teardown` again to leave the account at
~$1/month (foundation only), per the session teardown practice.

---

## What goes wrong

**`Error: creating EC2 VPC: VpcLimitExceeded`.** The account's default VPC
limit is five per region, and a stray VPC from earlier experimentation (often
the account's original default VPC, which nobody deleted) can leave no room
for this one. Find it and confirm it is unused before deleting:

```bash
aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,IsDefault,CidrBlock]' --output table
aws ec2 delete-vpc --vpc-id <the unused default vpc id>
```

Do not delete a VPC you have not confirmed is empty and unrelated to this
project.

**`terraform destroy` hangs on the NAT Gateway.** A NAT Gateway takes several
minutes to delete even when nothing is blocking it — this alone can look like
a hang. If it genuinely does not finish, the usual cause is a dependent ENI
(elastic network interface) still attached, which keeps the gateway alive
until AWS's own cleanup catches up. Give it time before intervening; a NAT
Gateway delete that is actually stuck, rather than merely slow, is rare.

**`verify-network.sh` times out waiting for console output.** The probe
instance may simply still be booting — `get-console-output` can return nothing
for a running instance for longer than feels comfortable. Re-run
`make verify-network` before concluding egress is broken; the script's own
error message says the same thing (`the probe may still be booting`).

**An `AWS_PROFILE` already exported for another account.** The makefile's
`AWS_PROFILE := bootcamp-administrator-access` (`:=`, not `?=`) overrides an
inherited environment variable for anything run through `make` (Phase 3 §F7).
It does **not** help a bare `terraform -chdir=infra/network apply` typed by
hand — that command never goes through the makefile at all. The only thing
that stops such a command from running against the wrong account is
`allowed_account_ids = [var.account_id]` on the provider, which fails the
apply outright rather than silently succeeding against a stranger's account.
Prefer the `make` targets for exactly this reason.

**A destroy that fails part-way leaves the Elastic IP allocated.** An
unattached EIP still bills at $0.005/hour. Check for one and release it:

```bash
aws ec2 describe-addresses --query 'Addresses[?AssociationId==`null`]'
aws ec2 release-address --allocation-id <id>
```
