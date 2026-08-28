# Runbook — Phase 5: staging apply, verification and teardown

**Date:** 2026-08-28
**Layer:** `infra/environments/staging`
**Estimated time:** 20–30 minutes for the apply-verify-teardown cycle, most of
it the ALB provisioning and the ECS service reaching steady state
**Cost while it exists:** roadmap §3 estimates ~$25/month — the ALB is most of
it, the single 0.25 vCPU Fargate task is most of the rest, and the on-demand
DynamoDB tables cost nothing while idle

This runbook creates the first layer that runs the application itself. The
Terraform it applies was written and verified in Phase 5 without an AWS
session — 16 tests, all green, against mocked providers — and this is the half
that needs one. Like `network`, staging is not meant to stay up between
sessions: the last two steps tear it down and rebuild it within this same
runbook, per the session teardown practice.

**It has three preconditions, not one.** Phase 4's runbook had a single
precondition — the bootstrap bucket. This layer needs `foundation` applied,
`network` applied, *and* a seeded ECR image tag. The third is the one most
likely to be skipped, because [the Phase 3 runbook](./phase-03-bootstrap-and-foundation.md)
lists seeding as one of its own steps rather than as a handover to this phase.
Step 1 below checks all three before anything is planned.

---

## 1. Preconditions

**`foundation` is applied, and its certificate is actually issued.**

```bash
terraform -chdir=infra/foundation output -raw certificate_arn
```

Expected: an ACM certificate ARN. No output, or an error reading state, means
**stop** — go run [the Phase 3 runbook](./phase-03-bootstrap-and-foundation.md)
first.

A non-empty ARN is not, by itself, enough — it names the certificate, not its
validation state. Check the state too:

```bash
aws acm describe-certificate --certificate-arn "$(terraform -chdir=infra/foundation output -raw certificate_arn)" \
  --query 'Certificate.Status' --output text
```

Expected: `ISSUED`. `aws_lb_listener.https` in this layer fails at apply
against a certificate that is still `PENDING_VALIDATION`. This normally only
bites on the path where `foundation` **created** the hosted zone rather than
adopting the registrar's existing one — `wait_for_validation` on the
certificate defaults to `true`, and `foundation` explicitly supports the
created-zone path, so validation can still be in flight if `foundation`'s
apply is checked immediately rather than waited out.

**`network` is applied.**

```bash
terraform -chdir=infra/network output -raw nat_gateway_public_ip
```

Expected: a public IPv4 address. No output means **stop** — go run [the
Phase 4 runbook](./phase-04-network.md) first. This layer's ECS tasks run in
the private subnets `network` creates; without it there is nowhere to place
them.

**An image tag exists in ECR.** This is the one to run even when it feels
unnecessary:

```bash
aws ecr describe-images --repository-name bgd-us-east-1-api \
  --query 'reverse(sort_by(imageDetails,&imagePushedAt))[:5].imageTags' --output table
```

Expected: at least one row, most likely `0.1.0-<sha>` from Phase 3's
`make seed-ecr`. **If this is empty, do not proceed to `plan`.** Without a
tag, `terraform plan` does not fail with a message about seeding — it fails
inside `data.aws_ecr_image`, naming the tag it could not find, which reads
like a Terraform problem rather than the missing handover it actually is:

```
Error: reading ECR Image: ImageNotFoundException: ...
```

If this happens, run `make seed-ecr` (needs `app/dist/image.oci.tar` — run
`make build` first if that is missing) and re-check this step before planning
again.

---

## 2. AWS session

```bash
aws sso login --profile bootcamp-administrator-access
make verify-aws
```

Expected: account `590184028094`, region `us-east-1`, both ticked.

---

## 3. Set `image_tag`

Every other variable in this layer already defaults to the value the project
wants. `image_tag` deliberately does not: the correct value changes with
every build, and a stale default would silently deploy an old image.

```bash
cp infra/environments/staging/terraform.tfvars.example \
   infra/environments/staging/terraform.tfvars
```

Then edit `terraform.tfvars` and set `image_tag` to the tag chosen in step 1
— or, to deploy exactly what was last built locally rather than whatever is
newest in ECR:

```bash
cat app/dist/image-ref.txt
```

`image-ref.txt` names the full reference `make build` produced; the tag is
everything after the last `:`. `terraform.tfvars` is gitignored — this file
never gets committed, on purpose, since the right value is a fact about a
build, not about the codebase.

---

## 4. Re-run the offline gate against the real toolchain

```bash
make tf-check
```

Expected: `all infra checks passed`, ending with the staging layer's own
suite:

```
==> terraform test — staging
...
Success! 16 passed, 0 failed.

  all infra checks passed
```

A failure here is a code problem, not a credentials problem — re-run it
before touching `plan` or `apply`, on the theory that the offline gate is
cheaper to debug than a half-applied layer.

---

## 5. Plan

```bash
make plan-staging
```

**This is the first moment `data.aws_ecr_image` runs for real** — every plan
before this one, in every prior test run, was against a mocked provider. If
step 1's ECR check passed, this data source should resolve cleanly; if it
does not, re-read step 1 rather than assuming the layer is broken.

**What to read in the plan: exactly 15 resources to add, and zero to change
or destroy.** That total is a count of the `resource` blocks across
`alb.tf`, `dns.tf`, `dynamodb.tf`, `ecs.tf` and `iam.tf`, not an estimate —
confirm the plan shows exactly:

- one `aws_lb`, one `aws_lb_target_group`, two `aws_lb_listener` (80 and 443)
- one `aws_route53_record` — the `staging-api.carloscloudengineer.com` alias
  every curl in steps 7 and 8 depends on
- one `aws_ecs_cluster`, one `aws_ecs_task_definition`, one `aws_ecs_service`
- two `aws_iam_role` (`task-exec` and `task`) with their policies
- two `aws_dynamodb_table` (`accounts` and `transactions`, the latter with its
  `created_at-index` local secondary index)
- one `aws_cloudwatch_log_group`

If the plan proposes changing or destroying anything, stop — this is a first
apply against empty state, and a change/destroy means the state file already
disagrees with what is on this branch.

---

## 6. Apply

```bash
make apply-staging
```

Expect **several minutes**, most of it the ALB — it typically takes 2–3
minutes to become `active`. After that, the slow part is the ECS service
reaching steady state: the task pulls the image, starts, passes its first
`/health` check after the 60-second grace period, and only then does the
deployment finish. The apply is not hung during either wait.

---

## 7. Verify — the exit criterion

```bash
make smoke-staging
```

`scripts/smoke.sh staging` asserts, in order: `/health` returns 200 (the ALB,
the certificate, the target group and the task are all up), `/ready` returns
200 (the task role, security groups and DynamoDB gateway endpoint are all
correct), `/version` returns 200, and `/version`'s `image_digest` equals what
Terraform deployed. Expected, ending line: `staging is serving sha256:...`.

For the raw shape of what a correct response looks like:

```bash
curl -s https://staging-api.carloscloudengineer.com/health  | jq .
curl -s https://staging-api.carloscloudengineer.com/ready   | jq .
curl -s https://staging-api.carloscloudengineer.com/version | jq .
```

Expected:

```json
{"status": "ok"}
{"status": "ready", "checks": {"dynamodb": "ok"}}
{"version": "...", "git_sha": "...", "image_digest": "sha256:...", "built_at": "..."}
```

`/version`'s `image_digest` must equal:

```bash
terraform -chdir=infra/environments/staging output -raw image_digest
```

If they differ, the ALB is serving a task that predates this apply — usually
a rolling deployment still mid-flight. If `image_digest` reads `"unknown"`,
`BGD_IMAGE_DIGEST` is missing from the task definition (see the table below).

---

## 8. Exercise the application — the most important verification step

`/health` and `/ready` between them prove the ALB, the task and DynamoDB
reachability. **Neither touches the Local Secondary Index, and neither
exercises the write path.** These three calls do, and they are not optional:

```bash
BASE=https://staging-api.carloscloudengineer.com

# 201 Created. Returns the generated account_id.
curl -s -X POST "$BASE/api/accounts" -H 'content-type: application/json' -d '{
  "owner_name": "Phase 5 runbook",
  "currency": "EUR",
  "initial_balance_minor": 10000
}' | tee /tmp/account.json | jq .

ACCOUNT_ID=$(jq -r .account_id /tmp/account.json)

# 201 Created. Repeat the identical command to confirm idempotency: the
# second call returns 200, not 201, and the same transaction_id.
curl -s -X POST "$BASE/api/transactions" -H 'content-type: application/json' -d "{
  \"account_id\": \"$ACCOUNT_ID\",
  \"type\": \"CREDIT\",
  \"amount_minor\": 2500,
  \"currency\": \"EUR\",
  \"idempotency_key\": \"runbook-phase5-001\",
  \"description\": \"Phase 5 verification\"
}" | jq .

# 200 OK, one item. THIS is the LSI query, and the only call in the whole
# runbook that proves the task role carries the index ARN. A 500 here with
# everything else green means exactly that — confirm it by looking for
# AccessDeniedException in the log group.
curl -s "$BASE/api/transactions?account_id=$ACCOUNT_ID&limit=10" | jq .
```

Expected: `201`, then `201` (and `200`, same `transaction_id`, on the
repeat), then `200` with one item in `items`. `account_id` is required on the
list call and returns `422` without it.

**Report back whether the `POST /api/transactions` call succeeded, and treat
that answer as significant.** The task-role policy in
`infra/environments/staging/iam.tf` grants `dynamodb:UpdateItem` and
`dynamodb:TransactWriteItems` **together**, as one set, for the compound
`transact_write_items` call `post_transaction` makes. A successful POST here
proves that granted set is sufficient — and specifically proves
`dynamodb:UpdateItem` is present and working, since the transaction's Update
item cannot succeed without it. **It does not determine whether
`dynamodb:TransactWriteItems` is separately required**: the call exercises
both permissions at once, so success cannot isolate which one was necessary,
and running the idempotent repeat does not help either — `dynamodb.py` issues
the identical `transact_write_items` call on both requests, with idempotency
coming from a `ConditionExpression` raising `TransactionCanceledException`,
not from a different code path, so IAM authorization is identical on both
calls.

The experiment that *would* determine it, **optional tidying, not a required
step** — worth doing only if someone wants the policy minimal: remove
`dynamodb:TransactWriteItems` from the task-role policy, `make apply-staging`,
and repeat this step. A failure proves the action necessary and it goes back
in; a success proves it redundant and it can stay removed.

---

## 9. Confirm the tags actually landed on the tasks

This cannot be checked from Terraform. `propagate_tags` is an
optional-but-not-computed argument on `aws_ecs_service`: a missing value
plans as unset and `terraform plan` stays clean forever, while every running
task quietly goes untagged.

```bash
aws ecs list-tasks --cluster bgd-us-east-1-staging-cluster \
  --query 'taskArns[0]' --output text
aws ecs describe-tasks --cluster bgd-us-east-1-staging-cluster \
  --tasks <arn> --include TAGS --query 'tasks[0].tags'
```

Expected: all four convention tags — `environment`, `projectName`, `region`,
`owner` — with `environment = staging`. If the tags are missing, `iam.tf`'s
neighbour `ecs.tf` is fine but `propagate_tags = "SERVICE"` was dropped from
`aws_ecs_service.api`; `terraform plan` will not show this as a problem.

---

## 10. Watch a rolling deployment

```bash
aws ecs update-service --cluster bgd-us-east-1-staging-cluster \
  --service bgd-us-east-1-staging-api --force-new-deployment
aws ecs describe-services --cluster bgd-us-east-1-staging-cluster \
  --services bgd-us-east-1-staging-api --query 'services[0].deployments'
```

Watch the second `describe-services` call across a few seconds: a healthy
rolling deployment shows a new deployment starting a fresh task before the
old one is stopped, so `runningCount` briefly totals more than
`desired_count` across the two deployments rather than dropping to zero. This
is `ROLLING`, not `CODE_DEPLOY` — production's blue/green controller lands in
Phase 6.

---

## 11. Teardown and rebuild once

`data.aws_ecr_image` is evaluated on `destroy` as well as on `plan` — Terraform
still has to resolve `var.image_tag` to a digest to know which resources it is
tearing down. `foundation`'s ECR lifecycle policy retains only the
`ecr_max_image_count` most recent images (currently 10, in
`infra/foundation/variables.tf`), so a tag that was valid at apply time can
have aged out of the registry by the time teardown runs, especially after a
run of unrelated `make build && make seed-ecr` cycles on the same repository.
If that happens, `make teardown` fails inside `data.aws_ecr_image` before
destroying anything — leaving the ALB and the Fargate task running, and
billing. The remedy is the same shape as the plan-time failure in step 1: set
`image_tag` in `terraform.tfvars` to a tag that still exists in ECR (re-run
the `aws ecr describe-images` check from step 1), then re-run `make teardown`.

```bash
make teardown
make apply-network && make apply-staging && make smoke-staging
```

This is the first time `make teardown` has a second layer to order — Phase 4
tore down only `network`. Expected from `teardown`:
`teardown order: prod staging network`, then `prod` reports "no .tf files
yet, skipping" (Phase 6 has not landed), then `staging — terraform destroy`
runs, then `network — terraform destroy` runs, ending in `teardown complete —
foundation and bootstrap intact`. This is also the first real test of the
ordering `teardown.sh` encodes: destroying `network` before `staging` would
strand the ALB and the ECS service in subnets that no longer exist, and the
destroy would fail part-way with a dependency violation instead.

The rebuild that follows is what proves this layer is genuinely reproducible
rather than merely applied once and never touched again — a layer that only
ever sees one apply has not demonstrated that a second `apply` from clean
state produces the same working thing. Expected output is identical in shape
to steps 6 and 7. Once `smoke-staging` passes, run `make teardown` once more
to leave the account at the foundation-only baseline, per the session
teardown practice — do not leave `staging` or `network` running between
sessions.

---

## What goes wrong

| Symptom | Cause |
|---|---|
| Plan fails in `data.aws_ecr_image` | `image_tag` is not in ECR. Run `make seed-ecr`, or pick a tag from the precondition check in step 1. |
| `make teardown` fails inside `data.aws_ecr_image` before destroying anything | The pinned `image_tag` has aged out of ECR's 10-image retention since apply. Set `image_tag` to a tag that still exists (step 1's `aws ecr describe-images` check) and re-run `make teardown`. See step 11. |
| Apply fails: certificate is not valid / listener creation fails on the ACM certificate | `foundation`'s certificate is still `PENDING_VALIDATION`. Re-check the precondition in step 1 with `aws acm describe-certificate` and wait for `ISSUED` before planning again. |
| Apply fails: *target group does not have an associated load balancer* | The `depends_on = [aws_lb_listener.https]` in `ecs.tf` was removed. |
| Service never stabilises; tasks stop immediately | Almost always the ARM64/image mismatch — the image is built `linux/arm64` only. Check the stopped task's reason in the console. |
| `/health` 503 from the ALB | No healthy targets. Check the task is running and the security group path from ALB to task on port 8080 (`local.network.container_port`). |
| `/ready` 503 while `/health` is 200 | The task cannot reach DynamoDB: task role policy, or the gateway endpoint's route table association from Phase 4. |
| `GET /api/transactions` 500, everything else fine | The task role is missing the LSI index ARN (`iam.tf`'s `aws_iam_role_policy.task`, `.../index/created_at-index`). |
| `/version` reports `image_digest: unknown` | `BGD_IMAGE_DIGEST` is absent from the task definition's container environment. |
| Tasks are untagged in the console | `propagate_tags` was dropped from `aws_ecs_service.api`; `terraform plan` will not show it — see step 9. |
| `POST /api/transactions` fails `AccessDeniedException` | Unexpected under the current policy — both `UpdateItem` and `TransactWriteItems` are granted. `dynamodb.py` runs the identical `transact_write_items` call on the first request and the idempotent repeat, so a missing permission fails **both calls, starting with the first**, not just the retry. If this happens anyway, check `iam.tf`'s task policy for a resource-ARN typo on the `accounts` or `transactions` table before assuming a permissions gap; this is the failure mode step 8 exists to catch. |

