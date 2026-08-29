# Phase 5 — Staging environment: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-28
**Status:** Proposed, awaiting approval
**Branch:** `feat/Phase5_Staging`
**AWS cost incurred by this phase as planned:** **$0.** Every deliverable is written and verified locally against mocked providers. The apply that creates roughly $25/month of real resources is handed to you as a runbook — see §0.1 D1.
**Companion documents:**
[design research](../../2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 3 plan](../phase3/2026-08-24-phase-03-implementation-plan.md) ·
[Phase 4 plan](../phase4/2026-08-26-phase-04-implementation-plan.md) ·
[Phase 4 runbook](../../runbooks/phase-04-network.md) ·
[naming and tagging convention](../../naming-and-tagging-convention.md)

**Goal:** Write the `staging` environment layer — an internet-facing ALB terminating TLS, a single-task Fargate service on the rolling deployment controller, the two DynamoDB tables the application reads and writes, and the `staging-api.carloscloudengineer.com` record that fronts it — and prove it correct offline before a single resource is created.

**Architecture:** A flat root module at `infra/environments/staging/`, matching the three layers before it. Unlike `network` it **does** read `terraform_remote_state`, from both `foundation` and `network`, because it consumes their real ARNs and ids rather than derived strings (D2). Correctness is asserted by Terraform's native test framework against `mock_provider`, with `override_data` standing in for both remote states; the whole gate stays offline. Two shell deliverables land with it: a reusable smoke test and the runbook for the applies.

**Tech stack:** Terraform 1.15.7, AWS provider 6.61.0, tflint 0.60.0 with AWS ruleset 0.44.0, checkov 3.3.13 — the last two from digest-pinned containers, installing nothing on the host.

**Spec:** [phase roadmap §3, Phase 5](../../2026-08-04-implementation-phase-roadmap.md#phase-5--staging-environment), elaborated by [design research §5](../../2026-08-04-blue-green-deployment-platform-design-research.md#5-infrastructure).

---

## Global Constraints

Project-wide requirements. Every task's requirements implicitly include this section.

- **Naming:** `bgd-us-east-1-<env>-<resource>`, all lowercase, hyphen-separated. ALB and target group names are capped at **32 characters**. CloudWatch log groups are the one deviation and use slashes: `/bgd/us-east-1/staging/api`. See the [convention](../../naming-and-tagging-convention.md).
- **Tagging:** exactly four keys — `environment`, `projectName`, `region`, `owner` — applied through the provider's `default_tags`. This layer's `environment` is `staging`. Tag keys are case-sensitive.
- **`propagate_tags = "SERVICE"`** on the ECS service is mandatory, not optional. It is `optional` and **not `computed`** in the provider schema, so omitting it silently leaves every running task untagged and `terraform plan` stays clean. Fargate is the largest cost line after the ALBs and NAT. Convention §6.1.
- **`runtime_platform { cpu_architecture = "ARM64" }`** on the task definition. Phase 2 builds `linux/arm64` only; an `X86_64` task definition cannot start this image.
- **`BGD_IMAGE_DIGEST`** in the container environment. An image cannot contain its own digest, so without this `/version` reports `unknown` in a live environment.
- **Terraform:** `required_version >= 1.10`, AWS provider `~> 6.61`, S3 backend with `use_lockfile = true`, no DynamoDB lock table.
- **The offline gate:** `make tf-check` — `validate`, `tflint`, `checkov`, `terraform test` — must pass on a machine that has never run `aws sso login`. Established in Phase 3 §F2 and preserved here by F3.
- **Every checkov finding is either fixed or skipped with a written reason.** A bare skip is not acceptable; the reason names the trade-off.

---

## 0. Purpose and non-goals

`staging` is the roadmap's deliberately simpler environment. Its job is to fail fast, not to demonstrate blue/green — that is Phase 6's whole subject. The value of building it first is that everything blue/green does *not* change gets debugged here: remote-state wiring, image pinning, TLS, the task role's DynamoDB permissions, log delivery, and the DNS record. Phase 6 then adds only the parts that are genuinely about deployment strategy.

**This phase deliberately does not:**

- create any AWS resource, or make any AWS API call, in this session (D1)
- create a second target group, a `:8443` test listener, lifecycle hook Lambdas, or anything with `strategy = "BLUE_GREEN"` — all Phase 6
- create CloudWatch alarms, dashboards or EventBridge rules — Phase 9
- create a pipeline, or automate the image push — Phases 7 and 8
- change anything under `app/`, `infra/bootstrap/`, `infra/foundation/` or `infra/network/`

### 0.1 Decisions taken before this plan was written

#### D1 — This session writes and verifies; you apply

The same split Phases 3 and 4 took, for the same reason: the SSO token on `bootcamp-administrator-access` is expired.

```
$ aws sts get-caller-identity --profile bootcamp-administrator-access
aws: [ERROR]: Error when retrieving token from sso: Token has expired and refresh failed
```

**Consequences:**

- The branch's gate is `make tf-check`. Phase 5's exit criterion — the three endpoints answering over TLS — is met when you execute the runbook, not when this branch is written.
- **The Phase 5 runbook is blocked behind the Phase 3 and Phase 4 runbooks**, and by one step inside Phase 3 that is easy to overlook: `make seed-ecr`. Without a seeded image, `terraform plan` on this layer fails in the `aws_ecr_image` data source rather than at apply (D3). The runbook checks all three preconditions before it plans.
- One check cannot be gathered offline and becomes a runbook step: whether the ALB's health check actually passes against `/health` on a real task. Everything up to "the task definition is correct and the security groups permit the path" is asserted here; "the target became healthy" is observed there.

#### D2 — `staging` reads remote state from both `foundation` and `network`

The divergence from `network` that Phase 4 §D2 predicted, now taken.

**Consequences:**

- This layer consumes real ARNs and ids that cannot be reconstructed from convention: the certificate ARN, the hosted zone id, the registry URL and ARN, the VPC and subnet ids, and two of the four security group ids. Rebuilding those locally is not possible; reading them is the only correct option.
- It does **not** read `name_prefix` or `common_tags` from `foundation`, even though both are exported. `foundation`'s `common_tags` carries `environment = "shared"` and this layer is `staging`, so consuming it would be wrong. The prefix is a derived string, and Phase 4 §D2's argument against coupling for derived strings still holds. Both are rebuilt locally from the same four variables.
- `make tf-check` stays offline because `override_data` mocks a `terraform_remote_state` data source cleanly (F3). This was measured, not assumed — it was the single biggest risk to the offline gate.
- `terraform destroy` on this layer now depends on `foundation`'s state being readable. That is acceptable: `foundation` is never destroyed, which is the entire reason it is a separate layer.

#### D3 — The image is pinned by digest, resolved from a tag through ECR

Decided with you on 2026-08-28. `var.image_tag` names a tag; `data "aws_ecr_image"` resolves it to a digest; the container is referenced as `<repo>@sha256:…` and `BGD_IMAGE_DIGEST` is set from the same expression.

**Consequences:**

- There is exactly one digest in the layer, so `/version` cannot report something that was never deployed. The alternative — two hand-maintained variables — makes that disagreement a one-character typo away, and the symptom appears only as a wrong string on a live endpoint.
- `terraform plan` requires the tag to already exist in ECR. This is a feature: it fails with a data source error naming the missing tag, rather than applying a task definition that ECS cannot pull. It does mean `make seed-ecr` is a hard precondition (D1).
- Deploying by digest rather than tag means ECS records the exact bytes. Phase 11's manual-rollback demonstration is "apply with the previous `image_tag`", and the digest follows automatically.
- The data source is mockable (F2), so the offline gate is unaffected.

#### D4 — `scripts/smoke.sh`, parameterised by environment

Decided with you on 2026-08-28. A shell script, not a pytest suite and not runbook prose.

**Consequences:**

- Phase 8's CodeBuild runs the identical command that you run locally. A pytest suite would make the deploy gate depend on the application virtualenv, so a container that only needs `curl` would have to install Python and its dependencies to smoke-test a service.
- It takes the environment as its argument, so Phase 6 gets production smoke-testing with no new code.
- It asserts more than "200 OK": `/version`'s `image_digest` must equal the digest Terraform recorded in its output. That is what makes it a deployment check rather than a liveness check — it proves the *intended* image is the one serving traffic.
- Its timeout floor is set by a measurement, not a guess. See F5.

#### D5 — ALB access logging is off, with a written reason

Decided with you on 2026-08-28. checkov `CKV_AWS_91` is skipped rather than satisfied.

**Consequences:**

- Staging carries no production data, and the questions access logs answer here are already answered by the ALB's CloudWatch metrics and by Phase 4's VPC flow logs.
- Enabling it would have meant either reopening `foundation` to add a bucket policy for the ELB service principal — a cross-layer edit this phase otherwise avoids entirely — or adding a bucket, a policy and lifecycle rules to the layer whose whole point is being cheap and disposable.
- **Phase 6 decides independently.** In production, access logs are genuine blue/green evidence: they record which target group served which request. This skip is scoped to staging and says so.

> **Answered in Phase 6 (2026-08-29): still off, and the premise above was
> wrong.** This entry promised a fresh decision for production and predicted the
> answer would be yes, because "access logs are genuine blue/green evidence".
> Having looked at what the evidence actually has to be, they are not.
>
> The three exit criteria are met by `/version` on `:443` versus `:8443` during
> a deployment, the ECS deployment-stage transitions, and the hook Lambdas' own
> log output — all available within seconds. ALB access logs are delivered to S3
> on a roughly five-minute lag, which is **longer than the deployment they would
> document**: they would arrive after the thing they record had finished. And
> enabling them still requires either a bucket policy in `foundation`, a layer
> Phase 6 was equally scoped not to touch, or a bucket in `prod` that
> `make teardown` destroys along with every log in it.
>
> See [the Phase 6 plan](../phase6/2026-08-28-phase-06-implementation-plan.md)'s
> D7. The reason is written out in full in `infra/environments/prod/alb.tf`'s
> `CKV_AWS_91` skip rather than pointing back here, because production is the
> layer where a reviewer is most entitled to see the reasoning without following
> a link.

#### D6 — DynamoDB point-in-time recovery is off, with a written reason

Decided with you on 2026-08-28. checkov `CKV_AWS_28` is skipped.

**Consequences:**

- These tables are destroyed by `make teardown` and recreated empty by a rebuild. There is no point in time anyone would want to recover to.
- Deletion protection is off for the same reason, and that one is not optional: `deletion_protection_enabled = true` would make `terraform destroy` fail on this layer and break the teardown policy the five-layer split exists to serve.
- Phase 6 decides independently for production, where the answer is likely different.

> **Answered in Phase 6 (2026-08-29): the same, and for the same reason.** The
> production tables are destroyed by `make teardown` and recreated empty by a
> rebuild exactly as staging's are, so there is still no point in time worth
> recovering to. "Production" here names an environment in a demonstration
> project, not a system holding data anyone would miss — and deletion protection
> stays off on both tables for the reason above, which is not optional if
> `make teardown` is to work at all. `infra/environments/prod/dynamodb.tf`
> carries both skips, pointing at this entry.

#### D7 — Container Insights is explicitly disabled, not omitted

Decided with you on 2026-08-28. checkov `CKV_AWS_65` is skipped.

**Consequences:**

- Written as `setting { name = "containerInsights", value = "disabled" }` rather than left out, so the choice is visible in the code and in the plan diff rather than being an absence someone has to notice.
- Phase 9 owns observability and builds the dashboard that would consume these metrics. Turning it on now bills per custom metric on the layer whose purpose is being cheap to leave running.
- Reversing it is a one-line change to a `setting` block with no resource replacement, so deferring costs nothing.

#### D8 — The deployment circuit breaker is enabled, with rollback

Decided with you on 2026-08-28.

**Consequences:**

- A task that never reaches a healthy state rolls staging back to the previous task definition instead of retrying forever. The roadmap's stated job for staging is to fail fast; this is the mechanism.
- It gives staging automatic-rollback behaviour without any of Phase 6's blue/green machinery, which means the app pipeline in Phase 8 gets a meaningful staging gate for free.
- The trade-off accepted: a failed deployment reverts itself, so the broken task set is gone before anyone inspects it. The CloudWatch log group retains what the container printed, which is the part worth reading.

#### D9 — IAM policies are built with `jsonencode`, not `aws_iam_policy_document`

Forced by F1, and better than what it replaces.

**Consequences:**

- `mock_provider "aws"` mocks every data source the AWS provider owns, including the policy document generator, even though it is a pure local computation. Under mocks it returns a random string and `aws_iam_role` rejects it client-side.
- With `jsonencode` the policy JSON is a real value at plan time, so a test can `jsondecode` it and assert exactly which actions are granted on exactly which resources. The least-privilege claim in design §8.1 becomes a tested property instead of a description.
- The cost is losing the data source's validation and its `source_policy_documents` merging. Neither is used by this layer's three policies.

---

## 1. Findings recorded before this plan was written

Six probes were run on 2026-08-28 against real Terraform 1.15.7, the real AWS provider 6.61.0, real checkov, real tflint and the real Phase 2 container image. **None touched AWS.** Two changed the plan.

### F1 — `mock_provider "aws"` mocks `aws_iam_policy_document`, and the roles reject the result

This is the finding that changed how IAM is written. `aws_iam_policy_document` is a pure local computation — it renders JSON and makes no API call — but it is a data source belonging to the AWS provider, so `mock_provider` replaces it like any other. The mocked `.json` is a random string, and `aws_iam_role` validates its `assume_role_policy` client-side:

```
$ terraform test
  run "the_task_definition_carries_the_phase_2_inheritances"... fail

Error: "assume_role_policy" contains an invalid JSON policy: not a JSON object
  with aws_iam_role.task_exec,
  on iam.tf line 19, in resource "aws_iam_role" "task_exec":
  19:   assume_role_policy = data.aws_iam_policy_document.task_assume.json
```

The error arrives during plan, before any assertion runs, so the mocked value cannot even be inspected from a test.

Two fixes exist. `mock_data "aws_iam_policy_document" { defaults = { json = "…" } }` satisfies the validator but returns *the same* fixed JSON for every policy document in the layer, which means no test can assert what any policy grants. Building the policies with `jsonencode` instead keeps them real under mocks.

**Consequence:** this layer uses `jsonencode` for all three policies (D9), and Task 2 asserts their contents — including the LSI index ARN that F6 shows is load-bearing.

### F2 — Mocked attributes are random strings, and the provider validates several of them

The same trap, one layer deeper. With IAM fixed, the next error was:

```
Error: "execution_role_arn" (242nndcg) is an invalid ARN: arn: invalid prefix
  with aws_ecs_task_definition.api,
  on ecs.tf line 21, in resource "aws_ecs_task_definition" "api":
  21:   execution_role_arn       = aws_iam_role.task_exec.arn
```

`mock_provider` fills unknown computed attributes with a random eight-character string. Any attribute a downstream resource validates client-side must therefore be given a realistic `mock_resource` default. Six were required, each discovered by hitting its error rather than by guessing:

| Mocked resource | Attribute(s) | Why it is mandatory |
|---|---|---|
| `aws_iam_role` | `arn` | task definition validates ARN shape |
| `aws_dynamodb_table` | `arn` | interpolated into the task role's policy |
| `aws_cloudwatch_log_group` | `arn` | interpolated into the exec role's policy |
| `aws_lb` | `arn`, `dns_name`, `zone_id` | listeners and the Route 53 alias |
| `aws_lb_target_group` | `arn` | listener default action and the service |
| `aws_ecs_task_definition` | `arn` | the service's `task_definition` |

**Consequence:** Task 1 creates `tests/mocks.tftest.hcl` holding this block, and every other test file repeats it. Terraform's test framework has no shared-setup construct for `mock_provider`, so the duplication is structural rather than careless — Task 7's interface test is what catches a drift between copies.

### F3 — `terraform_remote_state` mocks cleanly, and omitting the mock fails loudly

The single biggest risk to the offline gate, since D2 makes this layer depend on two remote states. `override_data` handles it:

```
$ terraform test
  run "alb_lands_in_the_public_subnets"... pass
Success! 1 passed, 0 failed.
```

The failure mode when an override is forgotten is the safe one — the test reaches for the real backend and dies:

```
$ terraform test          # same config, override_data removed
  run "without_an_override"... fail
Error: validating provider credentials: retrieving caller identity from STS:
  api error InvalidClientTokenId: The security token included in the request is invalid.
```

**Consequence:** the Phase 3 §F2 offline property survives D2 intact. A missing override is a hard error naming credentials, not a test that silently asserts against `null`.

### F4 — checkov fails this layer's shape on ten checks in six categories; tflint finds one

Run against a complete draft of the layer:

```
Passed checks: 72, Failed checks: 10, Skipped checks: 0
```

| Check | Resource | Disposition |
|---|---|---|
| `CKV_AWS_150` | `aws_lb` | **skip** — deletion protection would break `make teardown`, which is the policy the five-layer split exists to serve |
| `CKV_AWS_91` | `aws_lb` | **skip** — D5 |
| `CKV2_AWS_28` | `aws_lb` | **skip** — a WAF web ACL is a monthly charge plus per-request billing, for a demo API with no attack surface worth the spend. Never specified by the design. |
| `CKV_AWS_28` ×2 | both tables | **skip** — D6 |
| `CKV_AWS_119` ×2 | both tables | **skip** — AES256 with the AWS-owned key, same reasoning as Phase 3 §D4 |
| `CKV_AWS_158` | log group | **skip** — same family; the precedent is `infra/network/flowlogs.tf` |
| `CKV_AWS_338` | log group | **skip** — 14-day retention on an environment destroyed when idle |
| `CKV_AWS_65` | `aws_ecs_cluster` | **skip** — D7 |

Nothing in the task definition failed: `readonlyRootFilesystem`, the non-root user inherited from the image, and the log configuration all passed as drafted.

tflint reported one issue, an unused `local.name_prefix` left over from drafting. It is absent by construction in Task 1, which defines `local.env_prefix` and nothing surplus.

### F5 — `/ready` takes 25.6 seconds to fail, and that sets the smoke test's timeout floor

The Phase 2 image was run locally with a read-only root filesystem and DynamoDB pointed at a dead endpoint:

```
$ docker run -d --read-only -p 18080:8080 \
    -e BGD_IMAGE_DIGEST=sha256:deadbeef \
    -e BGD_DYNAMODB_ENDPOINT_URL=http://127.0.0.1:9 bgd-us-east-1-api:…

health: 200
version: {"version":"0.1.0","git_sha":"84d4eb0-dirty","image_digest":"sha256:deadbeef",…}
ready:   503
```

Two things came out of it.

**`readonlyRootFilesystem = true` is safe**, measured rather than hoped. The container starts and serves under it, because the image sets `PYTHONDONTWRITEBYTECODE=1` and nothing in the request path writes to disk. And `BGD_IMAGE_DIGEST` is picked up from the environment and surfaced verbatim by `/version` — the Phase 2 inheritance proven end to end before any AWS resource exists.

**`/ready` took 25.6 seconds to return its 503.** That is botocore's retry backoff, not a hang, and it happens on exactly the failure the smoke test exists to catch — a task that starts but cannot reach DynamoDB because a security group, a gateway endpoint or the task role's policy is wrong:

```json
{"level":"INFO","logger":"bgd.access","message":"request","method":"GET","path":"/ready",
 "status":503,"duration_ms":25606.64}
```

**Consequence:** `scripts/smoke.sh` uses `--max-time 40` on `/ready`. A conventional 10-second timeout would report a connection failure and hide the 503 that names the actual cause.

### F6 — The application makes exactly four DynamoDB calls, and one of them needs the index ARN

`app/src/bgd/repository/dynamodb.py` was read rather than assumed. It calls `put_item`, `get_item`, `scan` and `query` — no `update_item`, no `delete_item`, and deliberately no `describe_table`, because `ping()` documents that `/ready` uses a data-plane read instead:

```python
def ping(self) -> None:
    """A data-plane read against a key that does not exist.

    Cheaper and far less throttle-prone than DescribeTable, which is a
    control-plane call — and /ready is polled.
    """
```

The `query` targets the LSI (`IndexName: created_at-index`). In IAM, an index is a distinct resource ARN.

**Consequence:** the task role's policy grants four actions on three ARNs — both tables and `${transactions_arn}/index/created_at-index`. Omitting the third is the trap: every endpoint works, and only `GET /api/transactions` fails, with an `AccessDeniedException` at runtime that no plan, no apply and no health check would reveal. Task 2 asserts the index ARN is present.

> **Amended in Phase 5 (2026-08-28), during Task 2's review.** This finding is
> **wrong**. It was gathered with a grep over `app/src/bgd/repository/dynamodb.py`
> whose alternation did not include `transact_write_items`, so it missed a call.
> `post_transaction` (`dynamodb.py:164`) calls `transact_write_items` with a `Put`
> on the transactions table and an **`Update`** on the accounts table
> (`SET balance_minor = balance_minor + :delta`). The real granted set is **six**
> actions — `GetItem`, `PutItem`, `Query`, `Scan`, `UpdateItem`,
> `TransactWriteItems` — not four, and the missing pair guards the application's
> primary write path rather than one read endpoint: shipped as originally
> written, this finding would have broken `POST /api/transactions` with
> `AccessDenied` in production, which is strictly worse than the LSI trap this
> finding was written to catch. `UpdateItem` is unambiguously required by the
> `Update` item; `TransactWriteItems` is a confirmed real IAM action in
> botocore's DynamoDB model, and whether AWS additionally checks the compound
> action (rather than only the per-item actions it wraps) could not be settled
> offline, so it is granted rather than omitted — inert at worst, breaking at
> best if wrong to omit. See the [local verification
> record](./2026-08-28-local-verification.md)'s note on the runbook step this
> could not, in the end, fully settle either. Task 2's tests
> (`tests/data_and_iam.tftest.hcl`) assert the six-action set and the
> `UpdateItem` grant separately.

### F7 — Provider 6.61 carries the full Phase 6 surface, confirmed against the installed binary

Checked with `terraform providers schema -json`, so this is the schema actually in `.terraform.lock.hcl`, not a changelog claim.

`aws_ecs_service.deployment_configuration` exposes `strategy`, `bake_time_in_minutes`, `canary_configuration`, `linear_configuration` and a `lifecycle_hook` set whose members take `hook_target_arn`, `lifecycle_stages` and `role_arn`. `aws_ecs_service.load_balancer.advanced_configuration` exposes `production_listener_rule`, `test_listener_rule`, `role_arn` and `alternate_target_group_arn`.

**Consequence for this phase:** `deployment_configuration { strategy = "ROLLING" }` is written explicitly even though the attribute is `optional` and `computed` and would default to the same value. Stating it makes the one-word difference from Phase 6 the visible difference between the two layers.

**Consequence for Phase 6:** design §5's and §8.1's Phase 0 amendments hold — `production_listener_rule` is a listener *rule* ARN and `role_arn` is required — and no provider upgrade is needed.

---

## 2. Global constraints

Restating the ones this layer breaks if it gets them wrong, with the symptom attached:

| Constraint | Symptom if missed |
|---|---|
| `runtime_platform { cpu_architecture = "ARM64" }` | Tasks fail at start with an exec format error. Circuit breaker rolls back; the service never becomes healthy. |
| `BGD_IMAGE_DIGEST` in the container environment | `/version` reports `unknown` on a live endpoint. Nothing fails; the evidence surface is just wrong. |
| `propagate_tags = "SERVICE"` | Running tasks untagged, Fargate cost unattributable, `terraform plan` clean. |
| Task role policy includes the LSI index ARN | `GET /api/transactions` returns 500 at runtime; every other endpoint works (F6). |
| `deletion_protection_enabled` unset on both tables | `terraform destroy` fails and `make teardown` leaves the layer running. |
| ALB and target group names ≤ 32 characters | Apply fails with an unhelpful error. `bgd-us-east-1-staging-alb` is 25; `bgd-us-east-1-staging-api` is 25. |
| Log group name uses slashes | A hyphenated name creates a second, silently empty group (convention §4). |
| `depends_on = [aws_lb_listener.https]` on the service | ECS refuses to create a service whose target group is not yet attached to a load balancer. Terraform's implicit graph does not order this, because the service references the target group and not the listener. |

> **Amended in Phase 5 (2026-08-28).** The LSI row above is correct as far as
> it goes but understates the blast radius, because it was written against
> F6's now-corrected claim. "Every other endpoint works" is not quite true:
> the task role also needs `dynamodb:UpdateItem` and `dynamodb:TransactWriteItems`
> for `post_transaction`'s compound write, and omitting *those* breaks
> `POST /api/transactions` — the primary write path, not a secondary read —
> with `AccessDenied`, on the first call rather than only the LSI-dependent
> list endpoint. See F6's amendment above. The symptom for the LSI omission
> specifically is unchanged: `GET /api/transactions` fails, everything else
> that does not touch the index still works.

---

## 3. File structure

```
infra/environments/staging/
  versions.tf                    terraform block, provider constraint, S3 backend
  providers.tf                   aws provider, allowed_account_ids, default_tags
  variables.tf                   every input, each with a default correct for this project
  locals.tf                      both remote states, the ECR lookup, derived names
  dynamodb.tf                    accounts and transactions tables, LSI included
  iam.tf                         task execution role, task role, both policies
  ecs.tf                         log group, cluster, task definition, service
  alb.tf                         load balancer, target group, both listeners
  dns.tf                         the staging-api A record
  outputs.tf                     the surface Phase 8 and scripts/smoke.sh consume
  terraform.tfvars.example       documented, committed; terraform.tfvars is gitignored
  README.md                      what this layer owns and what it depends on
  tests/
    mocks.tftest.hcl             F2's mock block and both remote-state overrides
    data_and_iam.tftest.hcl      tables, LSI, and what the two policies actually grant
    compute.tftest.hcl           task definition, service, and the Phase 2 inheritances
    edge.tftest.hcl              ALB, listeners, target group, DNS record
    outputs.tftest.hcl           the interface Phase 6 and Phase 8 depend on

scripts/
  smoke.sh                       new — TLS smoke test, environment as argument

docs/
  runbooks/phase-05-staging.md   new — the applies, the verification, the teardown
  phases/phase5/
    2026-08-28-phase-05-implementation-plan.md   this document
    2026-08-28-local-verification.md             new — the evidence record

makefile                         TF_LAYERS gains staging; `smoke` stops being PLANNED
```

**Why these boundaries.** The split is by responsibility rather than by resource type: `alb.tf` owns everything that terminates traffic, `ecs.tf` everything that runs it, `iam.tf` everything that grants it. `dns.tf` is three lines and could live in `alb.tf`, but it is the one resource that writes into a *foundation*-owned hosted zone, and keeping it separate makes that cross-layer write visible in the file list.

The test files split along the same lines, with one exception: `mocks.tftest.hcl` exists to hold the F2 block and the F3 overrides in one place as the reference copy. Terraform's test framework has no shared-setup construct for `mock_provider`, so each file repeats the block; the reference copy is what a reviewer diffs against.

---

## 4. Tasks

Ten tasks. Tests precede implementation throughout, which for Terraform means the `.tftest.hcl` file is written and *seen to fail* before the resources it asserts on exist. A test that has never failed is a test that has never been shown to test anything.

Every task ends with `./scripts/tf.sh test staging` and a commit. The full gate — `make tf-check` — runs at Task 7 and again at Task 10, because tflint and checkov are slower and their findings are layer-wide rather than per-resource.

### Task 1: Layer skeleton, remote state, and the DynamoDB tables

The foundation of everything else: the backend, the provider, the two remote states, and the tables. The tables come first because the task role's policy in Task 2 interpolates their ARNs, and because the LSI is the one thing in this layer that cannot be corrected later without destroying and recreating the table.

**Files:**
- Create: `infra/environments/staging/versions.tf`
- Create: `infra/environments/staging/providers.tf`
- Create: `infra/environments/staging/variables.tf`
- Create: `infra/environments/staging/locals.tf`
- Create: `infra/environments/staging/dynamodb.tf`
- Create: `infra/environments/staging/terraform.tfvars.example`
- Test: `infra/environments/staging/tests/mocks.tftest.hcl`
- Test: `infra/environments/staging/tests/data_and_iam.tftest.hcl`
- Delete: `infra/environments/staging/.gitkeep`

**Interfaces:**
- Consumes: `foundation` outputs `certificate_arn`, `zone_id`, `staging_api_domain`, `ecr_repository_url`, `ecr_repository_arn`; `network` outputs `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `alb_security_group_ids`, `task_security_group_ids`, `container_port`.
- Produces: `local.env_prefix` (`bgd-us-east-1-staging`), `local.foundation`, `local.network`, `local.container_port`, `local.container_name` (`"api"`), `local.image_reference`, `local.log_group_name`, `aws_dynamodb_table.accounts`, `aws_dynamodb_table.transactions`.

- [ ] **Step 1: Write the mock reference file**

This is F2's block plus F3's overrides. Every other test file repeats it verbatim.

Create `infra/environments/staging/tests/mocks.tftest.hcl`:

```hcl
# The reference copy of this layer's mocks. Terraform's test framework has no
# shared-setup construct for mock_provider, so every other test file in this
# directory repeats these three blocks verbatim; this file is what a reviewer
# diffs the copies against.
#
# Each mock_resource default below exists because omitting it produced a hard
# error before any assertion ran, not because it looked tidy. mock_provider
# fills computed attributes with a random eight-character string, and several
# resources validate ARN shape client-side. See the plan's F2.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::590184028094:role/mock" }
  }

  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-1:590184028094:table/mock" }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:590184028094:log-group:mock" }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:us-east-1:590184028094:loadbalancer/app/mock/0123456789abcdef"
      dns_name = "mock-alb-123.us-east-1.elb.amazonaws.com"
      zone_id  = "Z35SXDOTRQ7X7K"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:590184028094:targetgroup/mock/0123456789abcdef" }
  }

  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:590184028094:task-definition/mock:1" }
  }

  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  }
}

# Without these two overrides the tests reach the real S3 backend and fail on
# credentials rather than silently asserting against null. Measured — plan F3.
override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      certificate_arn    = "arn:aws:acm:us-east-1:590184028094:certificate/mock"
      zone_id            = "Z0MOCKZONEID000"
      staging_api_domain = "staging-api.carloscloudengineer.com"
      ecr_repository_url = "590184028094.dkr.ecr.us-east-1.amazonaws.com/bgd-us-east-1-api"
      ecr_repository_arn = "arn:aws:ecr:us-east-1:590184028094:repository/bgd-us-east-1-api"
    }
  }
}

override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      vpc_id                  = "vpc-0mockvpc"
      public_subnet_ids       = ["subnet-0mockpuba", "subnet-0mockpubb"]
      private_subnet_ids      = ["subnet-0mockprva", "subnet-0mockprvb"]
      alb_security_group_ids  = { staging = "sg-0mockalbstaging", prod = "sg-0mockalbprod" }
      task_security_group_ids = { staging = "sg-0mocktaskstaging", prod = "sg-0mocktaskprod" }
      container_port          = 8080
    }
  }
}

run "the_mock_reference_resolves" {
  command = apply

  assert {
    condition     = local.container_port == 8080
    error_message = "the network remote-state override did not reach locals"
  }
}
```

- [ ] **Step 2: Write the failing table test**

Append to a new `infra/environments/staging/tests/data_and_iam.tftest.hcl`. Copy the three blocks from `mocks.tftest.hcl` above the `run` blocks first — they are required in every file.

```hcl
# The LSI is the assertion that matters most in this file. A local secondary
# index must be created with its table and cannot be added afterwards, so
# getting it wrong here is not a fix, it is a destroy and recreate. The shape
# is fixed by app/src/bgd/repository/schema.py, which the application, the
# local bootstrap and the tests all read.

run "the_tables_match_the_application_schema" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.accounts.name == "bgd-us-east-1-staging-accounts"
    error_message = "accounts table name breaks the naming convention"
  }

  assert {
    condition     = aws_dynamodb_table.accounts.hash_key == "account_id"
    error_message = "accounts is keyed on account_id in schema.py"
  }

  assert {
    condition = (
      aws_dynamodb_table.transactions.hash_key == "account_id" &&
      aws_dynamodb_table.transactions.range_key == "transaction_id"
    )
    error_message = "transactions is keyed (account_id, transaction_id) in schema.py"
  }

  assert {
    condition     = one(aws_dynamodb_table.transactions.local_secondary_index).name == "created_at-index"
    error_message = "the created_at-index LSI is missing; it cannot be added after the table is created"
  }

  assert {
    condition = (
      one(aws_dynamodb_table.transactions.local_secondary_index).range_key == "created_at" &&
      one(aws_dynamodb_table.transactions.local_secondary_index).projection_type == "ALL"
    )
    error_message = "the LSI must sort on created_at and project ALL, per schema.py"
  }

  assert {
    condition = alltrue([
      aws_dynamodb_table.accounts.billing_mode == "PAY_PER_REQUEST",
      aws_dynamodb_table.transactions.billing_mode == "PAY_PER_REQUEST",
    ])
    error_message = "on-demand billing is what makes an idle staging environment cost nothing"
  }

  assert {
    condition = alltrue([
      !aws_dynamodb_table.accounts.deletion_protection_enabled,
      !aws_dynamodb_table.transactions.deletion_protection_enabled,
    ])
    error_message = "deletion protection would make terraform destroy fail and break make teardown"
  }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
./scripts/tf.sh test staging
```

Expected: failure. The directory holds no `.tf` files yet, so `tf.sh` dies with `layer 'staging' has no directory yet` or Terraform reports no configuration. Either is the correct failure — it proves the test is running against this layer and not silently passing.

- [ ] **Step 4: Write `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
  }

  # A backend block cannot interpolate, so the bucket bootstrap created appears
  # as a literal — the same trade the three layers before this one make. Only
  # the key differs, and it matches the layer name tf.sh and teardown.sh use.
  backend "s3" {
    bucket       = "bgd-us-east-1-tfstate-590184028094"
    key          = "staging/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

- [ ] **Step 5: Write `providers.tf`**

```hcl
# Repeated from the layers before it rather than shared: a provider block is not
# a module's worth of abstraction, and each root module owning its own is what
# lets this layer set environment = "staging" without touching those.
provider "aws" {
  region = var.region

  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.common_tags
  }
}
```

- [ ] **Step 6: Write `variables.tf`**

```hcl
variable "project_name" {
  description = "Short project identifier used as the prefix of every resource name."
  type        = string
  default     = "bgd"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.project_name))
    error_message = "project_name must be 2-8 lowercase alphanumeric characters (ALB names are capped at 32)."
  }
}

variable "region" {
  description = "AWS region. Also a name segment and a tag value, not only a provider setting."
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "Expected AWS account. Asserted by the provider."
  type        = string
  default     = "590184028094"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be twelve digits."
  }
}

variable "owner" {
  description = "Value of the owner tag: who to contact, and who pays."
  type        = string
  default     = "carreque45@gmail.com"
}

variable "state_bucket" {
  description = "Bucket holding every layer's state. This layer reads foundation's and network's outputs from it."
  type        = string
  default     = "bgd-us-east-1-tfstate-590184028094"
}

variable "image_tag" {
  description = <<-EOT
    ECR tag to deploy. Resolved to a digest by data.aws_ecr_image, and the task
    definition references the digest rather than this tag.

    The tag must already exist in ECR or terraform plan fails in the data source.
    That is deliberate: the alternative is applying a task definition ECS cannot
    pull. Phase 3's `make seed-ecr` is what puts the first one there, and
    `cat app/dist/image-ref.txt` names it.
  EOT
  type        = string
}

variable "task_cpu" {
  description = "Fargate CPU units. 256 is a quarter vCPU, the smallest Fargate offers and what design §10 priced."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate memory in MiB. 512 is the minimum permitted at 256 CPU units."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "How many tasks the service runs. One, deliberately: staging exists to fail fast, not to be available."
  type        = number
  default     = 1

  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "log_retention_days" {
  description = "CloudWatch retention for the application log group. Short by design on an environment destroyed when idle."
  type        = number
  default     = 14
}
```

Note that `image_tag` has **no default**. Every other variable in this layer has one that is correct for this project; this one cannot, because the correct value changes with every build and a stale default would silently deploy an old image.

- [ ] **Step 7: Write `locals.tf`**

```hcl
# Unlike network, this layer reads remote state — it consumes real ARNs and ids
# that cannot be reconstructed from the naming convention. See the plan's D2.
# What it deliberately does NOT read is name_prefix and common_tags: foundation
# exports both, but its common_tags says environment = "shared" and this layer
# is staging. Derived strings are rebuilt locally; only real identifiers cross
# the layer boundary.
data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "foundation/terraform.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "network/terraform.tfstate"
    region = var.region
  }
}

# Resolves a tag to the digest ECR actually holds. The task definition then
# deploys the digest, so there is exactly one identifier for "what is running"
# and /version cannot disagree with it. Plan §D3.
#
# This is the one data source in the layer that reaches AWS at plan time, and
# it fails loudly when var.image_tag is not in the registry — which is better
# than applying a task definition ECS cannot pull.
data "aws_ecr_image" "api" {
  repository_name = local.ecr_repository_name
  image_tag       = var.image_tag
}

locals {
  environment = "staging"
  env_prefix  = "${var.project_name}-${var.region}-${local.environment}"

  common_tags = {
    environment = local.environment
    projectName = var.project_name
    region      = var.region
    owner       = var.owner
  }

  foundation = data.terraform_remote_state.foundation.outputs
  network    = data.terraform_remote_state.network.outputs

  # Derived from the URL rather than rebuilt from the convention, so this layer
  # and foundation cannot disagree about which repository is meant.
  ecr_repository_url  = local.foundation.ecr_repository_url
  ecr_repository_name = split("/", local.ecr_repository_url)[1]

  # The name the ALB target group and the service's load_balancer block both
  # reference. A mismatch between the two is an apply-time error with a message
  # that does not name this as the cause, so it is written once.
  container_name = "api"

  # Read from network rather than restated, so the security group rules opened
  # there and the port declared here cannot drift. network exports it for
  # exactly this reason.
  container_port = local.network.container_port

  image_reference = "${local.ecr_repository_url}@${data.aws_ecr_image.api.image_digest}"

  # Slashes, not hyphens — the one deliberate deviation in the naming
  # convention (§3). The console builds its navigation tree from the hierarchy.
  log_group_name = "/${var.project_name}/${var.region}/${local.environment}/api"
}
```

- [ ] **Step 8: Write `dynamodb.tf`**

```hcl
# The shape is fixed by app/src/bgd/repository/schema.py, which calls itself the
# single source of truth and is read by the application, the local bootstrap and
# the tests. This file is the Terraform restatement of it, and the tests in
# tests/data_and_iam.tftest.hcl assert the two agree.
#
# On-demand billing rather than provisioned: an idle staging environment then
# costs nothing at all, which is what makes leaving it up between sessions a
# decision about the ALB and NAT rather than about the tables.

resource "aws_dynamodb_table" "accounts" {
  # checkov:skip=CKV_AWS_28:point-in-time recovery buys nothing on tables that make teardown destroys and rebuild recreates empty. There is no point in time worth recovering to. Plan §D6.
  # checkov:skip=CKV_AWS_119:the AWS-owned key, for the reason recorded in the Phase 3 plan §D4. A customer-managed CMK bills a request per read and per write on the application's entire data path.
  name         = "${local.env_prefix}-accounts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "account_id"

  attribute {
    name = "account_id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_dynamodb_table" "transactions" {
  # checkov:skip=CKV_AWS_28:as above — plan §D6.
  # checkov:skip=CKV_AWS_119:as above — Phase 3 plan §D4.
  name         = "${local.env_prefix}-transactions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "account_id"
  range_key    = "transaction_id"

  # transaction_id is derived from the idempotency key, so this sort key IS the
  # idempotency guard — the application writes with attribute_not_exists and
  # needs no separate guard item. See schema.py's module docstring.
  attribute {
    name = "account_id"
    type = "S"
  }

  attribute {
    name = "transaction_id"
    type = "S"
  }

  # Declared because the LSI sorts on it. DynamoDB requires an attribute
  # definition for every key of every index, and only for those.
  attribute {
    name = "created_at"
    type = "S"
  }

  # An LSI can only be created with its table. Getting this wrong is not a fix
  # in a later phase — it is destroying the table and losing whatever is in it.
  local_secondary_index {
    name            = "created_at-index"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled = true
  }
}
```

- [ ] **Step 9: Write `terraform.tfvars.example`**

```hcl
# Copy to terraform.tfvars, which is gitignored, and set image_tag.
#
# Every other variable in this layer already defaults to the value this project
# wants. image_tag deliberately has no default: it changes with every build, and
# a stale default would silently deploy an old image.
#
#   cat app/dist/image-ref.txt      # the tag scripts/build-image.sh produced
#
# The tag must already be in ECR — `make seed-ecr` in Phase 3, or a push from
# Phase 8's pipeline. terraform plan fails in data.aws_ecr_image otherwise, and
# names the tag it could not find.

image_tag = "0.1.0-84d4eb0"

# Occasionally useful, all correct as they stand:
# task_cpu           = 256
# task_memory        = 512
# desired_count      = 1
# log_retention_days = 14
```

- [ ] **Step 10: Run the tests to verify they pass**

```bash
rm -f infra/environments/staging/.gitkeep
./scripts/tf.sh test staging
```

Expected: `Success! 2 passed, 0 failed.` — `the_mock_reference_resolves` and `the_tables_match_the_application_schema`.

If `data_and_iam.tftest.hcl` fails on a missing `image_tag`, the variable has no default by design; add `variables { image_tag = "0.0.0-test" }` at the top of that file, outside any run block.

- [ ] **Step 11: Commit**

```bash
git add infra/environments/staging/
git commit -m "feat(staging): layer skeleton, remote state, and the DynamoDB tables

The tables come first because the task role's policy interpolates their ARNs,
and because the created_at-index LSI cannot be added after the table exists.

tests/mocks.tftest.hcl is the reference copy of the mock block every other test
file in this layer repeats; each mock_resource default in it exists because
omitting it produced a hard error before any assertion ran."
```

### Task 2: The two IAM roles, least-privilege and asserted

Design §8.1 asks for roles separated by function rather than one permissive role. This task builds two of the six and makes the least-privilege claim a tested property rather than a description — which is only possible because of D9.

**Files:**
- Create: `infra/environments/staging/iam.tf`
- Modify: `infra/environments/staging/tests/data_and_iam.tftest.hcl`

**Interfaces:**
- Consumes: `local.env_prefix`, `local.foundation.ecr_repository_arn`, `aws_dynamodb_table.accounts.arn`, `aws_dynamodb_table.transactions.arn`, `aws_cloudwatch_log_group.api.arn` (created in Task 3).
- Produces: `aws_iam_role.task_exec` (the role ECS assumes to pull the image and write logs), `aws_iam_role.task` (the role the application code runs as), `local.ecs_tasks_assume_role_policy`.

> **Ordering note.** `iam.tf` references `aws_cloudwatch_log_group.api.arn`, which Task 3 creates. Write the log group resource as the first step of this task rather than leaving Task 2 unable to validate — it is four lines, and splitting a reference from its referent across a commit boundary produces a commit that does not validate.

- [ ] **Step 1: Write the failing policy test**

Append to `infra/environments/staging/tests/data_and_iam.tftest.hcl`:

```hcl
# These assertions are only possible because the policies are built with
# jsonencode rather than aws_iam_policy_document. mock_provider mocks that data
# source — it is the AWS provider's, despite being a pure local computation —
# and returns a random string, so a policy built through it asserts nothing
# under test. See the plan's F1 and D9.

run "the_task_role_grants_exactly_what_the_application_calls" {
  command = apply

  # dynamodb.py calls put_item, get_item, scan and query. Nothing else — no
  # update_item, no delete_item, and deliberately no describe_table, because
  # ping() uses a data-plane read instead. Plan §F6.
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.task.policy).Statement[0].Action) == toset([
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:Scan",
    ])
    error_message = "the task role grants a different action set than app/src/bgd/repository/dynamodb.py calls"
  }

  # The trap this asserts against: an IAM index is a distinct ARN. Grant only
  # the two table ARNs and every endpoint works except GET /api/transactions,
  # which fails AccessDenied at runtime — invisible to plan, apply and the ALB
  # health check. Plan §F6.
  assert {
    condition = contains(
      jsondecode(aws_iam_role_policy.task.policy).Statement[0].Resource,
      "${aws_dynamodb_table.transactions.arn}/index/created_at-index"
    )
    error_message = "the LSI index ARN is missing; listing transactions would fail AccessDenied at runtime"
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.task.policy).Statement) == 1
    error_message = "the task role should grant one statement; anything else is scope creep"
  }
}

run "the_execution_role_can_pull_only_this_projects_registry" {
  command = apply

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.task_exec.policy).Statement :
      s.Resource if s.Sid == "EcrPullThisRepositoryOnly"
    ], "arn:aws:ecr:us-east-1:590184028094:repository/bgd-us-east-1-api")
    error_message = "the image pull must be scoped to the project's repository, not to every repository in the account"
  }

  # GetAuthorizationToken is the one action that genuinely cannot be scoped —
  # it grants a registry-wide token and AWS defines no resource for it. It is
  # isolated in its own statement so that the wildcard is visibly attached to
  # that action alone rather than to the pull actions as well.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.task_exec.policy).Statement :
      s if s.Resource == "*"
    ]) == 1
    error_message = "exactly one statement may use a wildcard resource, and it must be the ECR auth token"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.task_exec.policy).Statement :
      s.Sid == "EcrAuthToken" && s.Resource == "*"
    ])
    error_message = "the wildcard statement must be the ECR auth token and nothing else"
  }
}

run "both_roles_are_assumable_only_by_ecs_tasks_in_this_account" {
  command = plan

  assert {
    condition = alltrue([
      jsondecode(aws_iam_role.task.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com",
      jsondecode(aws_iam_role.task_exec.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com",
    ])
    error_message = "only the ECS tasks service principal may assume these roles"
  }

  # Without the account condition these trust policies are confused-deputy
  # shaped: any ECS task anywhere could assume them if it obtained the ARN.
  assert {
    condition = jsondecode(
      aws_iam_role.task.assume_role_policy
    ).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "590184028094"
    error_message = "the trust policy must be conditioned on this account"
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
./scripts/tf.sh test staging
```

Expected: FAIL, with errors naming `aws_iam_role_policy.task` and `aws_iam_role.task_exec` as undeclared resources.

- [ ] **Step 3: Write the log group into `ecs.tf`**

Task 2's policies reference it, so it lands here rather than in Task 3.

```hcl
resource "aws_cloudwatch_log_group" "api" {
  # checkov:skip=CKV_AWS_338:fourteen-day retention is deliberate on an environment that is destroyed when idle. Retention is the entirety of what a log group costs. Same reasoning as network's flow logs.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. These are application logs from a staging environment carrying no production data.
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}
```

- [ ] **Step 4: Write `iam.tf`**

```hcl
# Two of design §8.1's six roles. Both are created here rather than in
# foundation because a role's policy cannot be scoped to resources that do not
# exist yet — the Phase 3 §D2 rule — and the tables and log group are this
# layer's.
#
# Policies are built with jsonencode rather than aws_iam_policy_document.
# mock_provider mocks every data source the AWS provider owns, and the policy
# document generator is one of them despite being a pure local computation: it
# returns a random string under test and aws_iam_role rejects it client-side.
# jsonencode keeps the JSON real under mocks, which is what lets the tests
# assert what these policies actually grant. See the plan's F1 and D9.

locals {
  # Shared by both roles: identical trust, different permissions. The account
  # condition is what stops these being confused-deputy shaped — without it any
  # ECS task anywhere could assume them given the ARN.
  ecs_tasks_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}

# --- execution role: what the ECS agent does on the task's behalf -----------
#
# Assumed by ECS itself, before the container starts, to pull the image and
# create the log stream. The application code never holds these permissions.

resource "aws_iam_role" "task_exec" {
  name               = "${local.env_prefix}-task-exec-role"
  assume_role_policy = local.ecs_tasks_assume_role_policy
}

resource "aws_iam_role_policy" "task_exec" {
  name = "${local.env_prefix}-task-exec-policy"
  role = aws_iam_role.task_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The one action that genuinely cannot be scoped: it returns a
        # registry-wide token and AWS defines no resource type for it. Isolated
        # in its own statement so the wildcard is visibly attached to this
        # action alone.
        Sid      = "EcrAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPullThisRepositoryOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = local.foundation.ecr_repository_arn
      },
      {
        # CreateLogGroup is deliberately absent. Terraform owns the group, and
        # granting the agent permission to create one would let a typo in the
        # log configuration silently produce a second, unmanaged group instead
        # of failing.
        Sid      = "WriteThisServicesLogsOnly"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.api.arn}:*"
      },
    ]
  })
}

# --- task role: what the application code itself can do ---------------------

resource "aws_iam_role" "task" {
  name               = "${local.env_prefix}-task-role"
  assume_role_policy = local.ecs_tasks_assume_role_policy
}

resource "aws_iam_role_policy" "task" {
  name = "${local.env_prefix}-task-policy"
  role = aws_iam_role.task.id

  # Exactly the four calls app/src/bgd/repository/dynamodb.py makes, on exactly
  # the three ARNs it touches. The index ARN is the one easy to omit: an IAM
  # index is a distinct resource, and without it every endpoint works except
  # GET /api/transactions, which fails AccessDenied at runtime. Plan §F6.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DynamoDbDataPlane"
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:Query",
        "dynamodb:Scan",
      ]
      Resource = [
        aws_dynamodb_table.accounts.arn,
        aws_dynamodb_table.transactions.arn,
        "${aws_dynamodb_table.transactions.arn}/index/created_at-index",
      ]
    }]
  })
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
./scripts/tf.sh test staging
```

Expected: `Success! 5 passed, 0 failed.`

- [ ] **Step 6: Commit**

```bash
git add infra/environments/staging/
git commit -m "feat(staging): task execution and task roles, scoped and asserted

Two of design §8.1's six roles. Policies are built with jsonencode rather than
aws_iam_policy_document: mock_provider mocks that data source and returns a
random string, so a policy built through it asserts nothing under test.

The task role's third resource ARN is the created_at-index LSI. Without it every
endpoint works except GET /api/transactions, which fails AccessDenied at runtime
— invisible to plan, apply and the health check."
```

### Task 3: The cluster and the task definition

Where Phase 2's two inherited requirements land. Both are silent failures if missed — one at task start, one only as a wrong string on a live endpoint — so both get assertions rather than comments.

**Files:**
- Modify: `infra/environments/staging/ecs.tf`
- Test: `infra/environments/staging/tests/compute.tftest.hcl`

**Interfaces:**
- Consumes: `local.env_prefix`, `local.container_name`, `local.container_port`, `local.image_reference`, `local.log_group_name`, `aws_iam_role.task_exec.arn`, `aws_iam_role.task.arn`, both table names, `data.aws_ecr_image.api.image_digest`.
- Produces: `aws_ecs_cluster.this`, `aws_ecs_task_definition.api`.

- [ ] **Step 1: Write the failing task definition test**

Create `infra/environments/staging/tests/compute.tftest.hcl`. Copy the `mock_provider` and both `override_data` blocks from `tests/mocks.tftest.hcl` above the run blocks, then add `variables { image_tag = "0.0.0-test" }`.

```hcl
# The two assertions that matter most here are the Phase 2 inheritances. Both
# fail silently in different ways: an X86_64 task definition cannot start the
# arm64 image at all, and a missing BGD_IMAGE_DIGEST leaves /version reporting
# "unknown" on a live endpoint with nothing else wrong.

# The digest is written as a literal rather than a local. A `locals` block is
# not a valid block type in a .tftest.hcl file — Terraform rejects the file with
# "Blocks of type \"locals\" are not expected here". Module locals ARE readable
# from an assertion; it is only declaring new ones here that is unsupported.

run "the_task_definition_carries_the_phase_2_inheritances" {
  command = apply

  assert {
    condition     = aws_ecs_task_definition.api.runtime_platform[0].cpu_architecture == "ARM64"
    error_message = "Phase 2 builds linux/arm64 only; an X86_64 task definition cannot start this image"
  }

  assert {
    condition = one([
      for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
    ]).image == "590184028094.dkr.ecr.us-east-1.amazonaws.com/bgd-us-east-1-api@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "the container must be pinned to the digest the ECR data source resolved, not to a tag"
  }

  assert {
    condition = one([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e.value if e.name == "BGD_IMAGE_DIGEST"
    ]) == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "BGD_IMAGE_DIGEST must equal the deployed digest, or /version reports a digest that was never deployed"
  }
}

run "the_container_environment_points_at_this_environments_tables" {
  command = apply

  assert {
    condition = one([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e.value if e.name == "BGD_ACCOUNTS_TABLE"
    ]) == "bgd-us-east-1-staging-accounts"
    error_message = "the container must be pointed at the staging accounts table"
  }

  assert {
    condition = one([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e.value if e.name == "BGD_TRANSACTIONS_TABLE"
    ]) == "bgd-us-east-1-staging-transactions"
    error_message = "the container must be pointed at the staging transactions table"
  }

  # BGD_DYNAMODB_ENDPOINT_URL must be absent. Set, it points the client at
  # DynamoDB Local; the settings default of null is what selects real AWS.
  assert {
    condition = length([
      for e in one([
        for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
      ]).environment : e if e.name == "BGD_DYNAMODB_ENDPOINT_URL"
    ]) == 0
    error_message = "BGD_DYNAMODB_ENDPOINT_URL must be unset in AWS; setting it points the client at DynamoDB Local"
  }
}

run "the_container_is_hardened_and_logs_where_terraform_says" {
  command = apply

  # Verified against the real image before this was written: the container
  # starts and serves under a read-only root filesystem, because the image sets
  # PYTHONDONTWRITEBYTECODE and nothing in the request path writes to disk.
  # Plan §F5.
  assert {
    condition = one([
      for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
    ]).readonlyRootFilesystem
    error_message = "the root filesystem must be read-only; measured to work against the real image in plan §F5"
  }

  assert {
    condition = one([
      for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
    ]).logConfiguration.options["awslogs-group"] == "/bgd/us-east-1/staging/api"
    error_message = "logs must go to the group Terraform manages; a mismatched name creates a second, silently empty group"
  }

  assert {
    condition = one([
      for c in jsondecode(aws_ecs_task_definition.api.container_definitions) : c if c.name == "api"
    ]).portMappings[0].containerPort == 8080
    error_message = "the container port must match what network's security group rules opened"
  }
}

run "the_cluster_is_named_by_convention_and_insights_is_an_explicit_choice" {
  command = plan

  assert {
    condition     = aws_ecs_cluster.this.name == "bgd-us-east-1-staging-cluster"
    error_message = "cluster name breaks the naming convention"
  }

  assert {
    condition     = one(aws_ecs_cluster.this.setting).value == "disabled"
    error_message = "container insights must be explicitly disabled rather than omitted, so the choice is visible (plan §D7)"
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
./scripts/tf.sh test staging
```

Expected: FAIL, naming `aws_ecs_task_definition.api` and `aws_ecs_cluster.this` as undeclared.

- [ ] **Step 3: Append the cluster and task definition to `ecs.tf`**

```hcl
resource "aws_ecs_cluster" "this" {
  # checkov:skip=CKV_AWS_65:Container Insights bills per custom metric on the layer whose purpose is being cheap to leave running, and Phase 9 owns observability and builds the dashboard that would consume it. Written as an explicit "disabled" rather than omitted so the choice is visible. Plan §D7.
  name = "${local.env_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.env_prefix}-api"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  # Two roles, not one. The execution role is assumed by the ECS agent before
  # the container starts, to pull the image and open the log stream; the task
  # role is what the application code itself runs as. Design §8.1.
  execution_role_arn = aws_iam_role.task_exec.arn
  task_role_arn      = aws_iam_role.task.arn

  # Inherited from Phase 2, and not optional: the image is built linux/arm64
  # only, because it runs on Graviton, which is cheaper. An X86_64 task
  # definition fails at task start with an exec format error — after a clean
  # apply, so Terraform reports success and the service never stabilises.
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name = local.container_name

      # By digest, not by tag. There is one identifier for "what is running" in
      # this layer, and BGD_IMAGE_DIGEST below is the same expression, so
      # /version cannot disagree with what ECS actually deployed. Plan §D3.
      image     = local.image_reference
      essential = true

      portMappings = [
        {
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "BGD_ENVIRONMENT", value = local.environment },
        { name = "BGD_AWS_REGION", value = var.region },
        { name = "BGD_ACCOUNTS_TABLE", value = aws_dynamodb_table.accounts.name },
        { name = "BGD_TRANSACTIONS_TABLE", value = aws_dynamodb_table.transactions.name },

        # The second Phase 2 inheritance. An image cannot carry its own digest,
        # because the digest is its hash, so the deployer is the only party that
        # knows it. Without this /version reports "unknown" in a live
        # environment — nothing fails, the evidence surface is simply wrong.
        { name = "BGD_IMAGE_DIGEST", value = data.aws_ecr_image.api.image_digest },

        # BGD_DYNAMODB_ENDPOINT_URL is deliberately absent. The settings default
        # of null is what selects real AWS; setting it points the client at
        # DynamoDB Local.
      ]

      # Measured against the real image before this was written: it starts and
      # serves under a read-only root filesystem, because the image sets
      # PYTHONDONTWRITEBYTECODE=1 and nothing in the request path writes to
      # disk. Plan §F5.
      readonlyRootFilesystem = true

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
./scripts/tf.sh test staging
```

Expected: `Success! 9 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git add infra/environments/staging/
git commit -m "feat(staging): ECS cluster and task definition

Both Phase 2 inheritances land here and both are asserted: ARM64, without which
the task cannot start at all, and BGD_IMAGE_DIGEST, without which /version
reports 'unknown' on a live endpoint with nothing else wrong.

readonlyRootFilesystem is set on the strength of a measurement against the real
image, not an assumption — see the plan's F5."
```

### Task 4: The load balancer, target group and listeners

**Files:**
- Create: `infra/environments/staging/alb.tf`
- Test: `infra/environments/staging/tests/edge.tftest.hcl`

**Interfaces:**
- Consumes: `local.env_prefix`, `local.container_port`, `local.network.public_subnet_ids`, `local.network.alb_security_group_ids`, `local.network.vpc_id`, `local.foundation.certificate_arn`.
- Produces: `aws_lb.this`, `aws_lb_target_group.api`, `aws_lb_listener.http`, `aws_lb_listener.https`.

- [ ] **Step 1: Write the failing edge test**

Create `infra/environments/staging/tests/edge.tftest.hcl` with the three mock blocks and `variables { image_tag = "0.0.0-test" }`, then:

```hcl
run "the_load_balancer_is_public_and_uses_this_environments_security_group" {
  command = apply

  assert {
    condition     = aws_lb.this.name == "bgd-us-east-1-staging-alb" && length(aws_lb.this.name) <= 32
    error_message = "ALB name breaks the convention or the 32-character cap"
  }

  assert {
    condition     = !aws_lb.this.internal
    error_message = "the staging ALB is internet-facing by design"
  }

  assert {
    condition     = aws_lb.this.subnets == toset(["subnet-0mockpuba", "subnet-0mockpubb"])
    error_message = "the ALB belongs in the public subnets"
  }

  # The staging group, not prod's. network deliberately created four groups so
  # the two environments' tasks cannot reach each other — picking the wrong key
  # here would quietly undo that. Phase 4 §D3.
  assert {
    condition     = aws_lb.this.security_groups == toset(["sg-0mockalbstaging"])
    error_message = "the ALB must use the staging ALB security group, not prod's"
  }

  # Deletion protection is off deliberately, and it is not an oversight: enabled,
  # it makes terraform destroy fail and breaks make teardown.
  assert {
    condition     = !aws_lb.this.enable_deletion_protection
    error_message = "deletion protection would break make teardown"
  }

  assert {
    condition     = aws_lb.this.drop_invalid_header_fields
    error_message = "malformed headers should be dropped at the edge rather than reaching the application"
  }
}

run "the_target_group_health_checks_liveness_only" {
  command = apply

  assert {
    condition     = aws_lb_target_group.api.name == "bgd-us-east-1-staging-api" && length(aws_lb_target_group.api.name) <= 32
    error_message = "target group name breaks the convention or the 32-character cap"
  }

  # ip, not instance: awsvpc network mode gives each Fargate task its own ENI
  # and there is no instance to register.
  assert {
    condition     = aws_lb_target_group.api.target_type == "ip"
    error_message = "Fargate tasks register by IP; an instance target type cannot work with awsvpc"
  }

  # /health, never /ready. /health reports only whether the process is alive.
  # Health-checking /ready would let one DynamoDB hiccup deregister every task
  # at once — the reason the two endpoints are separate at all. See the
  # docstring in app/src/bgd/api/routers/health.py.
  assert {
    condition     = one(aws_lb_target_group.api.health_check).path == "/health"
    error_message = "the health check must poll /health; /ready would deregister every task on a DynamoDB hiccup"
  }

  assert {
    condition     = aws_lb_target_group.api.port == 8080
    error_message = "the target group port must match the container port network opened"
  }

  # 300 seconds is the default and far too slow for a rolling deployment of one
  # task: every deploy would hold the old task draining for five minutes.
  assert {
    condition     = aws_lb_target_group.api.deregistration_delay == "30"
    error_message = "the default 300s deregistration delay makes every rolling deployment take five minutes"
  }
}

run "http_redirects_and_https_terminates_with_the_foundation_certificate" {
  command = apply

  assert {
    condition     = one(aws_lb_listener.http.default_action).type == "redirect"
    error_message = "port 80 must redirect rather than serve"
  }

  assert {
    condition = (
      one(one(aws_lb_listener.http.default_action).redirect).port == "443" &&
      one(one(aws_lb_listener.http.default_action).redirect).status_code == "HTTP_301"
    )
    error_message = "the redirect must be a permanent redirect to 443"
  }

  assert {
    condition     = aws_lb_listener.https.certificate_arn == "arn:aws:acm:us-east-1:590184028094:certificate/mock"
    error_message = "the HTTPS listener must use the certificate foundation issued, read through remote state"
  }

  assert {
    condition     = aws_lb_listener.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "the TLS policy must be the TLS 1.2 floor with 1.3 support"
  }

  # Staging has exactly one listener beyond the redirect. Production adds :8443
  # in Phase 6, and network already opened that port on prod's group alone.
  assert {
    condition     = aws_lb_listener.https.port == 443
    error_message = "staging serves on 443 only; the 8443 test listener is Phase 6 and production-only"
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
./scripts/tf.sh test staging
```

Expected: FAIL, naming `aws_lb.this` and the listeners as undeclared.

- [ ] **Step 3: Write `alb.tf`**

```hcl
# The environment's entire ingress path. One listener pair — 80 redirecting to
# 443 — and one target group. Production's shape in Phase 6 differs by a second
# target group and the :8443 test listener; everything in this file is the part
# that blue/green does not change, which is why staging is built first.

resource "aws_lb" "this" {
  # checkov:skip=CKV_AWS_150:deletion protection would make terraform destroy fail and break make teardown, which is the policy the five-layer split exists to serve (roadmap §1).
  # checkov:skip=CKV_AWS_91:access logging is deliberately off for staging, which carries no production data; the ALB's CloudWatch metrics and Phase 4's VPC flow logs answer the questions it would. Enabling it means either a bucket policy in foundation or a bucket in this disposable layer. Phase 6 decides separately for production, where access logs are genuine blue/green evidence. Plan §D5.
  # checkov:skip=CKV2_AWS_28:a WAF web ACL is a monthly charge plus per-request billing for a demo API with no attack surface worth the spend, and was never part of the design.
  name               = "${local.env_prefix}-alb"
  load_balancer_type = "application"
  internal           = false

  subnets         = local.network.public_subnet_ids
  security_groups = [local.network.alb_security_group_ids[local.environment]]

  # Requests with malformed headers are rejected at the edge rather than being
  # normalised and passed on, which is where request smuggling starts.
  drop_invalid_header_fields = true

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "api" {
  name        = "${local.env_prefix}-api"
  port        = local.container_port
  protocol    = "HTTP"
  vpc_id      = local.network.vpc_id
  target_type = "ip"

  # The default is 300 seconds. With one task, every rolling deployment would
  # then hold the old task draining for five minutes before the deployment
  # completed. Thirty is long enough to finish in-flight requests for an API
  # whose slowest measured response is a DynamoDB query.
  deregistration_delay = 30

  # /health, not /ready — and this is the whole reason the application has two
  # endpoints. /health reports only whether the process is alive; /ready checks
  # DynamoDB. Polling /ready here would let a single DynamoDB hiccup deregister
  # every healthy task at once. See app/src/bgd/api/routers/health.py.
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # Redirect rather than serve. network's ALB security group opens 80 to the
  # world so a browser typing the hostname reaches something; this is the
  # something, and nothing behind it serves plaintext.
  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"

  # TLS 1.2 floor with 1.3 support. The certificate lives in foundation and
  # outlives every teardown, which is why it is referenced through remote state
  # rather than issued here — a rebuild must not re-validate a certificate.
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = local.foundation.certificate_arn

  # A default action, not a listener rule. Phase 6's production listener needs
  # an aws_lb_listener_rule because advanced_configuration takes a rule ARN
  # (design §5, amended in Phase 0); staging shifts no traffic and needs none.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
./scripts/tf.sh test staging
```

Expected: `Success! 12 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git add infra/environments/staging/
git commit -m "feat(staging): ALB, target group and the listener pair

The health check polls /health and never /ready. That is the entire reason the
application has two endpoints: /ready checks DynamoDB, and health-checking it
would let one DynamoDB hiccup deregister every healthy task at once.

deregistration_delay drops from the 300s default to 30s, or every rolling
deployment of a single task would take five minutes to complete."
```

### Task 5: The ECS service

**Files:**
- Modify: `infra/environments/staging/ecs.tf`
- Modify: `infra/environments/staging/tests/compute.tftest.hcl`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: `aws_ecs_service.api`.

- [ ] **Step 1: Write the failing service test**

Append to `infra/environments/staging/tests/compute.tftest.hcl`:

```hcl
run "the_service_runs_private_tasks_with_attributable_tags" {
  command = apply

  assert {
    condition     = aws_ecs_service.api.name == "bgd-us-east-1-staging-api"
    error_message = "service name breaks the naming convention"
  }

  # Not decoration. propagate_tags is optional and NOT computed in the provider
  # schema, so omitting it sends nothing, the ECS default of no propagation
  # applies, every running task is untagged, and terraform plan stays clean.
  # Fargate is the largest cost line after the ALBs and NAT. Convention §6.1.
  assert {
    condition     = aws_ecs_service.api.propagate_tags == "SERVICE"
    error_message = "without propagate_tags every running task is untagged and Fargate cost cannot be attributed"
  }

  assert {
    condition     = one(aws_ecs_service.api.network_configuration).subnets == toset(["subnet-0mockprva", "subnet-0mockprvb"])
    error_message = "tasks belong in the private subnets, reaching the internet through the NAT"
  }

  assert {
    condition     = !one(aws_ecs_service.api.network_configuration).assign_public_ip
    error_message = "a public IP on a private-subnet task both costs money and defeats the point of the subnet"
  }

  assert {
    condition     = one(aws_ecs_service.api.network_configuration).security_groups == toset(["sg-0mocktaskstaging"])
    error_message = "the service must use the staging task security group, not prod's"
  }
}

run "the_service_deploys_by_rolling_and_rolls_itself_back" {
  command = apply

  # ROLLING is also the API default, so this line changes nothing on its own.
  # It is written because the single word is the visible difference between this
  # layer and Phase 6's, where it becomes BLUE_GREEN.
  assert {
    condition     = one(aws_ecs_service.api.deployment_configuration).strategy == "ROLLING"
    error_message = "staging deploys by rolling update; blue/green is Phase 6 and production only"
  }

  # Staging's job in the roadmap is to fail fast. Without the circuit breaker a
  # task that never becomes healthy is retried indefinitely, consuming Fargate
  # capacity, and the failure is visible only to someone reading service events.
  assert {
    condition = (
      one(aws_ecs_service.api.deployment_circuit_breaker).enable &&
      one(aws_ecs_service.api.deployment_circuit_breaker).rollback
    )
    error_message = "the circuit breaker must be enabled with rollback (plan §D8)"
  }

  assert {
    condition     = one(aws_ecs_service.api.load_balancer).container_name == "api"
    error_message = "the load_balancer block's container_name must match the task definition's container name"
  }

  assert {
    condition     = aws_ecs_service.api.desired_count == 1
    error_message = "staging runs one task by design"
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
./scripts/tf.sh test staging
```

Expected: FAIL, naming `aws_ecs_service.api` as undeclared.

- [ ] **Step 3: Append the service to `ecs.tf`**

```hcl
resource "aws_ecs_service" "api" {
  name            = "${local.env_prefix}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Both mandatory for cost attribution, and neither is computed: omitting
  # propagate_tags sends nothing and ECS defaults to no propagation, leaving
  # every running task untagged while terraform plan stays clean. SERVICE
  # rather than TASK_DEFINITION because Phase 8 revises the task definition on
  # every image push, which makes its tags the less reliable source.
  # Convention §6.1.
  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true

  # The application starts in a second or two, but the first health check is
  # scheduled immediately. Sixty seconds of grace stops a cold start being
  # counted as a failure and rolled back by the circuit breaker below.
  health_check_grace_period_seconds = 60

  # ROLLING is also the API default. It is stated because this one word is the
  # difference between this layer and Phase 6's, and a difference that matters
  # should be visible rather than implied by an absence. Plan §F7.
  deployment_configuration {
    strategy = "ROLLING"
  }

  # Staging's stated job is to fail fast. Without this, a task that never
  # becomes healthy is retried forever; with it, the service reverts to the
  # previous task definition and the failure is a finished event rather than an
  # ongoing one. The trade accepted is that the broken task set is gone before
  # it can be inspected — the log group keeps what the container printed, which
  # is the part worth reading. Plan §D8.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.network.private_subnet_ids
    security_groups  = [local.network.task_security_group_ids[local.environment]]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = local.container_name
    container_port   = local.container_port
  }

  # Load-bearing, and not inferable from the graph. ECS refuses to create a
  # service whose target group is not yet attached to a load balancer, and
  # Terraform sees only the service's reference to the target group — not the
  # listener that attaches it. Without this the first apply fails with
  # "target group does not have an associated load balancer" and the second
  # succeeds, which is the most confusing kind of intermittent failure.
  depends_on = [aws_lb_listener.https]
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
./scripts/tf.sh test staging
```

Expected: `Success! 14 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git add infra/environments/staging/
git commit -m "feat(staging): the ECS service, rolling with a circuit breaker

depends_on the HTTPS listener is load-bearing and not inferable from the graph:
ECS refuses a service whose target group is not yet attached to a load balancer,
and Terraform sees only the service's reference to the target group. Without it
the first apply fails and the second succeeds.

propagate_tags is optional and not computed in the schema, so omitting it leaves
every running task untagged with a clean plan."
```

### Task 6: The DNS record

Three lines of Terraform, in their own file because this is the one resource that writes into a hosted zone another layer owns.

**Files:**
- Create: `infra/environments/staging/dns.tf`
- Modify: `infra/environments/staging/tests/edge.tftest.hcl`

**Interfaces:**
- Consumes: `local.foundation.zone_id`, `local.foundation.staging_api_domain`, `aws_lb.this.dns_name`, `aws_lb.this.zone_id`.
- Produces: `aws_route53_record.api`.

- [ ] **Step 1: Write the failing DNS test**

Append to `infra/environments/staging/tests/edge.tftest.hcl`:

```hcl
run "the_hostname_aliases_this_environments_load_balancer" {
  command = apply

  # Read from foundation rather than composed here. foundation owns the domain
  # and already derives this name; composing "staging-api." + a domain variable
  # in this layer would be a second place for the hostname to be spelled.
  assert {
    condition     = aws_route53_record.api.name == "staging-api.carloscloudengineer.com"
    error_message = "the record must use the hostname foundation derives, not one composed here"
  }

  assert {
    condition     = aws_route53_record.api.zone_id == "Z0MOCKZONEID000"
    error_message = "the record belongs in the hosted zone foundation owns"
  }

  # An alias A record, not a CNAME. An ALB has no stable address, and a zone
  # apex cannot hold a CNAME — alias records are the only shape that works for
  # both, and they cost nothing to resolve.
  assert {
    condition     = aws_route53_record.api.type == "A"
    error_message = "an alias A record is what fronts an ALB; a CNAME would not work at an apex and costs a lookup"
  }

  assert {
    condition     = one(aws_route53_record.api.alias).name == "mock-alb-123.us-east-1.elb.amazonaws.com"
    error_message = "the alias must target this layer's own load balancer"
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
./scripts/tf.sh test staging
```

Expected: FAIL, naming `aws_route53_record.api` as undeclared.

- [ ] **Step 3: Write `dns.tf`**

```hcl
# The one resource in this layer that writes into another layer's hosted zone.
# It is in its own file so that cross-layer write is visible in the file list
# rather than buried at the bottom of alb.tf.
#
# The zone survives teardown — it lives in foundation — so a rebuild recreates
# this record pointing at a new ALB, and the hostname keeps working with no
# manual step. That property is the whole reason the zone is not in this layer.

resource "aws_route53_record" "api" {
  zone_id = local.foundation.zone_id
  name    = local.foundation.staging_api_domain
  type    = "A"

  # An alias, not a CNAME: an ALB has no stable IP address, alias records
  # resolve for free rather than costing a lookup, and only an alias can sit at
  # a zone apex should this ever need to.
  alias {
    name    = aws_lb.this.dns_name
    zone_id = aws_lb.this.zone_id

    # Route 53 stops answering with this record if the ALB has no healthy
    # targets. With one record and one ALB that changes nothing today, but it
    # is the correct default and Phase 6 inherits the habit.
    evaluate_target_health = true
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
./scripts/tf.sh test staging
```

Expected: `Success! 15 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git add infra/environments/staging/
git commit -m "feat(staging): the staging-api alias record

In its own file because it is the one resource in this layer that writes into a
hosted zone foundation owns. The zone survives teardown, so a rebuild recreates
this record against a new ALB and the hostname keeps working."
```

### Task 7: Outputs, the layer README, and the full gate

Outputs are an interface. Phase 6 copies this layer's shape, Phase 8's pipeline deploys against it, and `scripts/smoke.sh` reads it — so a rename here surfaces three phases later as a null lookup. This task pins the surface and then runs the complete static-analysis gate for the first time.

**Files:**
- Create: `infra/environments/staging/outputs.tf`
- Create: `infra/environments/staging/README.md`
- Test: `infra/environments/staging/tests/outputs.tftest.hcl`

**Interfaces:**
- Produces: outputs `api_url`, `alb_dns_name`, `cluster_name`, `service_name`, `task_definition_family`, `image_digest`, `log_group_name`, `accounts_table_name`, `transactions_table_name`.

- [ ] **Step 1: Write the failing outputs test**

Create `infra/environments/staging/tests/outputs.tftest.hcl` with the three mock blocks and `variables { image_tag = "0.0.0-test" }`, then:

```hcl
# This file exists to make a rename in this layer fail here rather than in
# Phase 8, where it would surface as a smoke test reading an empty URL, or in
# Phase 6, where it would surface as a copied module referencing an output that
# no longer exists. Outputs are an interface; interfaces get tests.

run "the_consumed_surface_is_present_and_correctly_shaped" {
  command = apply

  # scripts/smoke.sh reads these two and nothing else. They are the contract
  # that makes the smoke test a deployment check rather than a liveness check:
  # one says where to look, the other says what must be running there.
  assert {
    condition     = output.api_url == "https://staging-api.carloscloudengineer.com"
    error_message = "api_url is what scripts/smoke.sh curls; it must be the full https URL"
  }

  assert {
    condition     = output.image_digest == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "image_digest is what the smoke test compares /version against"
  }

  # Phase 8's ECS deploy action addresses the service by cluster and name.
  assert {
    condition = (
      output.cluster_name == "bgd-us-east-1-staging-cluster" &&
      output.service_name == "bgd-us-east-1-staging-api"
    )
    error_message = "Phase 8's deploy action addresses the service by cluster and service name"
  }

  assert {
    condition     = output.log_group_name == "/bgd/us-east-1/staging/api"
    error_message = "the runbook and Phase 9 both read logs by this name"
  }

  assert {
    condition = (
      output.accounts_table_name == "bgd-us-east-1-staging-accounts" &&
      output.transactions_table_name == "bgd-us-east-1-staging-transactions"
    )
    error_message = "the table names are how the runbook seeds and inspects staging data"
  }

  assert {
    condition     = output.alb_dns_name == "mock-alb-123.us-east-1.elb.amazonaws.com"
    error_message = "alb_dns_name is what the runbook curls to bypass DNS while a record propagates"
  }
}
```

> **Amended in Phase 5 (2026-08-28), during Task 7's review.** The test code
> above is incomplete: `outputs.tf` (Step 3, below) declares **nine** outputs,
> and the code block above asserts only **eight** — it never references
> `output.task_definition_family`. That is a hole in a test file whose stated
> purpose, two paragraphs up, is "outputs are an interface; interfaces get
> tests," and this specific output matters: a later phase registers new task
> definition revisions against the family and a rollback names a revision of
> it, so an unguarded rename would break exactly the consumer this test exists
> to protect. Fixed during implementation — the committed
> `tests/outputs.tftest.hcl` carries a ninth assertion:
>
> ```hcl
>   assert {
>     condition     = output.task_definition_family == "bgd-us-east-1-staging-api"
>     error_message = "task_definition_family is what later phases register revisions against and roll back by"
>   }
> ```

- [ ] **Step 2: Run the test to verify it fails**

```bash
./scripts/tf.sh test staging
```

Expected: FAIL — `output.api_url` is unknown because no outputs are declared.

- [ ] **Step 3: Write `outputs.tf`**

```hcl
# The interface Phases 6 and 8, the runbook and scripts/smoke.sh all read.
# tests/outputs.tftest.hcl pins every name here, so a rename fails in this
# layer rather than three phases later as a null lookup.

output "api_url" {
  description = "Base URL of this environment. scripts/smoke.sh curls it; the runbook pastes it into a browser."
  value       = "https://${local.foundation.staging_api_domain}"
}

output "alb_dns_name" {
  description = "The load balancer's own hostname, for reaching the environment while the Route 53 record is still propagating."
  value       = aws_lb.this.dns_name
}

output "cluster_name" {
  description = "ECS cluster name. Phase 8's deploy action and every aws ecs CLI call address the service through it."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name, as addressed by Phase 8's deploy action."
  value       = aws_ecs_service.api.name
}

output "task_definition_family" {
  description = "Task definition family. Phase 8 registers new revisions against it; a rollback names a revision of it."
  value       = aws_ecs_task_definition.api.family
}

output "image_digest" {
  description = "The digest actually deployed. scripts/smoke.sh asserts /version reports this exact value."
  value       = data.aws_ecr_image.api.image_digest
}

output "log_group_name" {
  description = "Where the container's stdout goes. The runbook tails it; Phase 9 reads metrics from it."
  value       = aws_cloudwatch_log_group.api.name
}

output "accounts_table_name" {
  description = "Staging accounts table, for seeding and inspecting data by hand."
  value       = aws_dynamodb_table.accounts.name
}

output "transactions_table_name" {
  description = "Staging transactions table, for seeding and inspecting data by hand."
  value       = aws_dynamodb_table.transactions.name
}
```

- [ ] **Step 4: Write `infra/environments/staging/README.md`**

```markdown
# infra/environments/staging

The staging environment: an internet-facing ALB terminating TLS, one Fargate
task on the rolling deployment controller, the two DynamoDB tables the
application uses, and the `staging-api.carloscloudengineer.com` record.

Deliberately the simpler of the two environments. Its job is to fail fast, not
to demonstrate blue/green — that is `../prod`.

## What it depends on

Both through `terraform_remote_state`, unlike `../../network`, because it
consumes real ARNs and ids rather than derived strings:

| Layer | Consumed |
|---|---|
| `foundation` | certificate ARN, hosted zone id, staging hostname, ECR repository URL and ARN |
| `network` | VPC id, public and private subnet ids, the `staging` ALB and task security groups, the container port |

It does **not** read `foundation`'s `name_prefix` or `common_tags`. That layer's
tags say `environment = shared`; this one is `staging`. Derived strings are
rebuilt locally and only real identifiers cross the boundary.

## What it costs

Roughly $25/month: the ALB is most of it, the single 0.25 vCPU Fargate task is
most of the rest, and the on-demand tables cost nothing while idle. Destroyed
by `make teardown` along with `prod` and `network`.

## Applying it

`image_tag` has no default, because the correct value changes with every build:

    cp terraform.tfvars.example terraform.tfvars   # then set image_tag
    make plan-staging
    make apply-staging
    make smoke-staging

The tag must already be in ECR or the plan fails in `data.aws_ecr_image`,
naming the tag it could not find. `make seed-ecr` is what puts the first one
there.

See [the Phase 5 runbook](../../../docs/runbooks/phase-05-staging.md).
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
./scripts/tf.sh test staging
```

Expected: `Success! 16 passed, 0 failed.`

- [ ] **Step 6: Run the complete gate for the first time**

`staging` is not yet in `TF_LAYERS`, so name it directly:

```bash
terraform fmt -recursive infra
./scripts/tf.sh validate staging
./scripts/lint-infra.sh environments/staging
```

Expected from checkov: `Failed checks: 0`, with the eight skips from F4 reported as skipped rather than failed. Expected from tflint: clean.

If checkov reports a failure that F4 does not list, triage it rather than adding a skip reflexively — a new finding means the code diverged from what was drafted, and the divergence is what to look at first.

- [ ] **Step 7: Commit**

```bash
git add infra/environments/staging/
git commit -m "feat(staging): outputs, layer README, and a test that pins the surface

Outputs are an interface. Phase 6 copies this layer's shape, Phase 8 deploys
against it and scripts/smoke.sh reads it, so a rename here would surface three
phases later as a null lookup rather than as a failure in this directory."
```

### Task 8: `scripts/smoke.sh` and `make smoke-ENV`

The deliverable Phase 8 reuses unchanged. It asserts more than "the endpoint answers": `/version`'s digest must equal the digest Terraform deployed, which is what makes it a deployment check.

**Files:**
- Create: `scripts/smoke.sh`
- Modify: `makefile`

**Interfaces:**
- Consumes: the `api_url` and `image_digest` outputs from Task 7.
- Produces: `scripts/smoke.sh <staging|prod>`, exit 0 on success; `make smoke-staging`.

- [ ] **Step 1: Write `scripts/smoke.sh`**

```bash
#!/usr/bin/env bash
#
# Smoke test one environment over TLS.
#
#   scripts/smoke.sh <staging|prod>
#
# Asserts four things, in order of what they rule out:
#
#   1. /health answers 200 over TLS          the ALB, the certificate, the
#                                            target group and the task are all up
#   2. /ready answers 200                    the task role, the security groups
#                                            and the DynamoDB gateway endpoint
#                                            are all correct
#   3. /version answers 200
#   4. /version's image_digest equals the     the image Terraform intended is the
#      digest Terraform deployed              image actually serving traffic
#
# The fourth is the one that makes this a deployment check rather than a
# liveness check, and it is why Phase 8 runs this exact script after deploying
# to staging rather than inventing a smoke stage of its own.
#
# The URL and digest come from Terraform outputs by default. Both can be
# overridden by environment variable so Phase 8's CodeBuild can pass them
# directly rather than needing the state backend:
#
#   BGD_SMOKE_URL=https://…  BGD_SMOKE_DIGEST=sha256:…  scripts/smoke.sh staging

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd curl
require_cmd jq

ROOT="$(repo_root)"

env_name="${1:-}"
case "$env_name" in
  staging | prod) ;;
  *) die "usage: smoke.sh <staging|prod>" ;;
esac

layer_dir="$ROOT/infra/environments/$env_name"
[[ -d "$layer_dir" ]] || die "layer '$env_name' has no directory yet"

# Read both values from Terraform unless the caller supplied them. terraform
# output is used directly rather than through tf.sh, matching seed-ecr.sh: this
# reads state, it does not run a Terraform command against the layer.
BASE_URL="${BGD_SMOKE_URL:-}"
EXPECTED_DIGEST="${BGD_SMOKE_DIGEST:-}"

if [[ -z "$BASE_URL" ]]; then
  BASE_URL="$(terraform -chdir="$layer_dir" output -raw api_url 2>/dev/null)" ||
    die "cannot read the $env_name outputs — apply the layer first, or set BGD_SMOKE_URL"
fi

if [[ -z "$EXPECTED_DIGEST" ]]; then
  EXPECTED_DIGEST="$(terraform -chdir="$layer_dir" output -raw image_digest 2>/dev/null)" ||
    die "cannot read the $env_name image digest — apply the layer first, or set BGD_SMOKE_DIGEST"
fi

echo
info "smoke — $env_name"
dim "  url     $BASE_URL"
dim "  digest  $EXPECTED_DIGEST"
echo

failures=0

# --max-time 40, not the conventional 10. Measured: when DynamoDB is
# unreachable, /ready takes 25.6 seconds to return its 503, because botocore
# retries with backoff before giving up. A 10-second timeout would report a
# connection failure and hide the 503 that names the actual cause — on exactly
# the misconfiguration this check exists to catch. See the Phase 5 plan §F5.
#
# --fail is deliberately NOT used: a non-2xx body is the most useful thing on
# the screen when this fails, and --fail discards it.
probe() {
  local path="$1" expected="$2" timeout="$3" body status
  body="$(curl --silent --show-error --max-time "$timeout" \
    --write-out '\n%{http_code}' "$BASE_URL$path" 2>&1)" || {
    printf '  %-10s ' "$path"
    mark_fail "no response within ${timeout}s"
    failures=$((failures + 1))
    return
  }

  status="${body##*$'\n'}"
  body="${body%$'\n'*}"

  printf '  %-10s ' "$path"
  if [[ "$status" == "$expected" ]]; then
    mark_ok
    LAST_BODY="$body"
  else
    mark_fail "HTTP $status (expected $expected)"
    dim "    $body"
    failures=$((failures + 1))
    LAST_BODY=""
  fi
}

LAST_BODY=""

probe /health 200 10
probe /ready 200 40
probe /version 200 10

# The assertion that makes this a deployment check. LAST_BODY holds /version's
# response, because it was the last probe to succeed.
printf '  %-10s ' "digest"
if [[ -z "$LAST_BODY" ]]; then
  mark_fail "no /version response to check"
  failures=$((failures + 1))
else
  reported="$(printf '%s' "$LAST_BODY" | jq -r '.image_digest')"
  if [[ "$reported" == "$EXPECTED_DIGEST" ]]; then
    mark_ok
  elif [[ "$reported" == "unknown" ]]; then
    mark_fail "/version reports 'unknown' — BGD_IMAGE_DIGEST is missing from the task definition"
    failures=$((failures + 1))
  else
    mark_fail "serving $reported, Terraform deployed $EXPECTED_DIGEST"
    failures=$((failures + 1))
  fi
fi

echo
if ((failures > 0)); then
  die "$failures smoke check(s) failed against $env_name"
fi
ok "$env_name is serving $EXPECTED_DIGEST"
```

- [ ] **Step 2: Make it executable and check it fails cleanly with no session**

```bash
chmod +x scripts/smoke.sh
./scripts/smoke.sh
./scripts/smoke.sh nonsense
./scripts/smoke.sh staging
```

Expected, in order: the usage message; the usage message; and `cannot read the staging outputs — apply the layer first, or set BGD_SMOKE_URL`. All three exit non-zero. The third is the important one — it names the fix rather than failing inside Terraform.

- [ ] **Step 3: Prove the assertions work, without AWS**

Run the real image locally and point the script at it. This is the same probe that produced F5, reused as a test of the script:

```bash
docker run -d --name bgd-smoke-probe --read-only -p 18080:8080 \
  -e BGD_IMAGE_DIGEST=sha256:aaaa \
  -e BGD_DYNAMODB_ENDPOINT_URL=http://127.0.0.1:9 \
  "$(cat app/dist/image-ref.txt)"

# Digest matches what the container reports, but /ready fails: expect the
# /ready row to fail after ~26s and the digest row to pass.
BGD_SMOKE_URL=http://127.0.0.1:18080 BGD_SMOKE_DIGEST=sha256:aaaa \
  ./scripts/smoke.sh staging

# Digest deliberately wrong: expect the digest row to name both values.
BGD_SMOKE_URL=http://127.0.0.1:18080 BGD_SMOKE_DIGEST=sha256:bbbb \
  ./scripts/smoke.sh staging

docker rm -f bgd-smoke-probe
```

Expected: the first run fails on `/ready` only, and takes about 26 seconds to do it — which is the direct evidence that `--max-time 40` was necessary. The second additionally fails the digest row with `serving sha256:aaaa, Terraform deployed sha256:bbbb`.

Record both outputs; they go into the verification record in Task 10.

- [ ] **Step 4: Add the makefile target**

Replace the `# PLANNED: smoke` line with a real pattern rule, in the Phase 5 section at the end of the file:

```makefile
# ---------------------------------------------------------------------------
# Phase 5 — staging
# ---------------------------------------------------------------------------

# A pattern rule, like plan-% and apply-%, so Phase 6 gets `make smoke-prod`
# with no edit here. Same FORCE dependency and the same reason: a pattern rule
# cannot be declared .PHONY, and without it this would silently stop running
# the day a file named smoke-staging appears.
# LISTED: smoke-ENV      Smoke test an environment over TLS (needs an AWS session)
smoke-%: FORCE
	@./scripts/smoke.sh $*
```

And in the Phase 3 section, add `staging` to the layer list:

```makefile
TF_LAYERS := bootstrap foundation network staging
```

Then delete the now-satisfied planned line:

```makefile
# PLANNED: smoke          Smoke test an environment over TLS (Phase 5)
```

- [ ] **Step 5: Verify `make help` and the full gate**

```bash
make help
make tf-check
```

Expected: `smoke-ENV` appears under **Available now** and no longer under **Planned**; `rebuild` is the only remaining planned entry. `make tf-check` passes across all four layers, including `staging` for the first time through `TF_LAYERS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/smoke.sh makefile
git commit -m "feat(staging): scripts/smoke.sh and make smoke-ENV

Asserts that /version's image_digest equals the digest Terraform deployed, which
is what makes this a deployment check rather than a liveness check — and why
Phase 8 runs this script rather than inventing a smoke stage of its own.

/ready gets --max-time 40 rather than the conventional 10. Measured: with
DynamoDB unreachable it takes 25.6s to return its 503, because botocore retries
with backoff. A 10s timeout would hide the 503 that names the cause on exactly
the misconfiguration this check exists to catch.

TF_LAYERS gains staging, so make tf-check now covers all four layers."
```

### Task 9: The Phase 5 runbook

The applies this session cannot perform. It has three preconditions rather than Phase 4's one, and the third — a seeded ECR tag — is the one most likely to be forgotten, because Phase 3's runbook lists it as a step rather than as a handover.

**Files:**
- Create: `docs/runbooks/phase-05-staging.md`

- [ ] **Step 1: Write the runbook**

Follow the structure of [the Phase 4 runbook](../../runbooks/phase-04-network.md), with these sections:

1. **Preconditions** — `foundation` and `network` applied, and an ECR tag to deploy. Give the exact commands that check each, and say what the failure looks like:
   ```bash
   terraform -chdir=infra/foundation output -raw certificate_arn
   terraform -chdir=infra/network  output -raw nat_gateway_public_ip
   aws ecr describe-images --repository-name bgd-us-east-1-api \
     --query 'reverse(sort_by(imageDetails,&imagePushedAt))[:5].imageTags' --output table
   ```
   The third is the one to run even when it feels unnecessary: without a tag, `terraform plan` fails inside `data.aws_ecr_image` with a message about the data source rather than about seeding.
2. **AWS session** — `aws sso login --profile bootcamp-administrator-access`, then confirm account and region.
3. **Set `image_tag`** — copy `terraform.tfvars.example`, set the tag chosen in step 1.
4. **Re-run the offline gate against the real toolchain** — `make tf-check`.
5. **Plan** — `make plan-staging`. State what a correct plan contains: roughly 15 resources to add and no changes to anything existing. Call out that the plan is the first moment the ECR data source runs for real.
6. **Apply** — `make apply-staging`. Note that it takes several minutes, most of it the ALB, and that the ECS service reaching a steady state is the slow part after that.
7. **Verify — the exit criterion** — `make smoke-staging`, and separately the three raw curls so the runbook shows the expected bodies:
   ```bash
   curl -s https://staging-api.carloscloudengineer.com/health  | jq .
   curl -s https://staging-api.carloscloudengineer.com/ready   | jq .
   curl -s https://staging-api.carloscloudengineer.com/version | jq .
   ```
   `/version`'s `image_digest` must equal `terraform -chdir=infra/environments/staging output -raw image_digest`.
8. **Exercise the application, not just its health.** `/health` and `/ready` between them prove the ALB, the task and DynamoDB reachability. Neither touches the LSI, so neither would catch the F6 trap. These three calls do:

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
    # everything else green means exactly that (plan §F6) — confirm it by
    # looking for AccessDeniedException in the log group.
    curl -s "$BASE/api/transactions?account_id=$ACCOUNT_ID&limit=10" | jq .
    ```

    Expected: `201`, then `201` (and `200` on a repeat), then `200` with one item. `account_id` is required on the list call and returns `422` without it.
9. **Confirm the tags actually landed on the tasks** — this is the check that `propagate_tags` worked, and it cannot be done from Terraform:
   ```bash
   aws ecs list-tasks --cluster bgd-us-east-1-staging-cluster \
     --query 'taskArns[0]' --output text
   aws ecs describe-tasks --cluster bgd-us-east-1-staging-cluster \
     --tasks <arn> --include TAGS --query 'tasks[0].tags'
   ```
   Expect all four convention tags with `environment = staging`.
10. **Watch a rolling deployment** — force a new deployment and observe the second task start before the first stops:
    ```bash
    aws ecs update-service --cluster bgd-us-east-1-staging-cluster \
      --service bgd-us-east-1-staging-api --force-new-deployment
    aws ecs describe-services --cluster bgd-us-east-1-staging-cluster \
      --services bgd-us-east-1-staging-api --query 'services[0].deployments'
    ```
11. **Teardown and rebuild once** — `make teardown` then `make apply-network && make apply-staging && make smoke-staging`. This is the first time teardown has a second layer to order, so it is also the first real test of the ordering `teardown.sh` encodes.
12. **What goes wrong** — a table of the failures this shape actually produces:

    | Symptom | Cause |
    |---|---|
    | Plan fails in `data.aws_ecr_image` | `image_tag` is not in ECR. Run `make seed-ecr`, or pick a tag from the precondition check. |
    | Apply fails: *target group does not have an associated load balancer* | The `depends_on` in `ecs.tf` was removed. |
    | Service never stabilises; tasks stop immediately | Almost always the ARM64/image mismatch. Check the stopped task's reason in the console. |
    | `/health` 503 from the ALB | No healthy targets. Check the task is running and the security group path from ALB to task on 8080. |
    | `/ready` 503 while `/health` is 200 | The task cannot reach DynamoDB: task role policy, or the gateway endpoint's route table association. |
    | `GET /api/transactions` 500, everything else fine | The task role is missing the LSI index ARN (plan §F6). |
    | `/version` reports `image_digest: unknown` | `BGD_IMAGE_DIGEST` is absent from the task definition. |
    | Tasks are untagged in the console | `propagate_tags` was dropped; `terraform plan` will not show it. |

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/phase-05-staging.md
git commit -m "docs: the Phase 5 runbook

Three preconditions rather than Phase 4's one. The third — an ECR tag to deploy
— is the one most likely to be missed, because Phase 3's runbook lists seeding
as one of its own steps rather than as a handover to this phase.

Step 8 exercises GET /api/transactions specifically. It is the only check that
touches the LSI, and therefore the only one that proves the task role's index
ARN is right."
```

### Task 10: Documentation amendments and the verification record

Every phase so far has amended the documents it contradicted rather than leaving them wrong. This phase contradicts three.

**Files:**
- Modify: `docs/2026-08-04-implementation-phase-roadmap.md`
- Modify: `docs/2026-08-04-blue-green-deployment-platform-design-research.md`
- Modify: `docs/naming-and-tagging-convention.md`
- Create: `docs/phases/phase5/2026-08-28-local-verification.md`

- [ ] **Step 1: Amend the roadmap**

Two amendments, both in the Phase 5 section of §3, in the style the Phase 2, 3 and 4 amendments established:

- **The branch alone does not meet the exit criterion.** Same note Phases 3 and 4 carry: the branch's gate is `make tf-check`, and the criterion is met when the runbook is executed.
- **The layer builds more than the task list names.** The circuit breaker (D8), the explicit `containerInsights = disabled` (D7), `scripts/smoke.sh` (D4), and the digest-resolution approach to image pinning (D3) are all decisions the task list does not mention. Each gets a line with its reason.

Also correct one detail in the §2 branch table if needed: row 5 reads `feat/Phase5_Staging`, which is the branch used. No amendment required — say so explicitly, as the Phase 3 note did.

- [ ] **Step 2: Amend the design research document**

One amendment, to §5 or §10: design §10's cost table prices staging's Fargate at part of a combined `$27` line for three tasks. Nothing here contradicts it, so this amendment is small — record that the staging half is one 0.25 vCPU / 0.5 GB ARM64 task, and that ARM64 was not what §10 priced. Graviton Fargate is cheaper than x86 at the same size, so the estimate is conservative rather than wrong.

- [ ] **Step 3: Amend the naming and tagging convention**

§6.3's timeline table says "Phases 5 and 6 — set `propagate_tags = "SERVICE"` on both ECS services". Mark the Phase 5 half done, and add the verification command from the runbook's step 9, because the convention currently states the requirement without saying how to confirm it landed.

- [ ] **Step 4: Write the local verification record**

Create `docs/phases/phase5/2026-08-28-local-verification.md`, following [the Phase 4 record](../phase4/2026-08-26-local-verification.md):

1. **The gate** — the full `make tf-check` output, and a table of every assertion in this layer with what it protects against.
2. **Static analysis triage** — checkov before and after, the eight skips and their reasons.
3. **The container evidence** — the F5 read-only run and the two `scripts/smoke.sh` runs from Task 8 Step 3, with their real output. This is the only part of Phase 5 that is genuinely *executed* rather than mocked, so it carries more weight than the rest of the record.
4. **No AWS resource was created** — the same proof Phase 4's §3 gives: no session existed, and `terraform test` against `mock_provider` makes no API call.
5. **What remains before the exit criterion is met** — the runbook, enumerated.
6. **Carried forward** — what Phase 6 inherits from this layer, and what it must do differently.

- [ ] **Step 5: Run the full gate one last time**

```bash
make tf-check
```

Expected: all four layers pass.

- [ ] **Step 6: Commit**

```bash
git add docs/
git commit -m "docs: Phase 5 amendments and the local verification record

Amends the roadmap (the branch alone does not meet the exit criterion; four
decisions the task list does not name), the design document (staging's Fargate
half is one ARM64 task, which §10 did not price), and the tagging convention
(§6.3's Phase 5 half is done, with the command that confirms it)."
```

- [ ] **Step 7: Open the pull request**

```bash
git push -u origin feat/Phase5_Staging
```

The description is §5 below, with each criterion marked as met by the branch or deferred to the runbook.

---

## 5. Exit criteria

The roadmap states one:

> `https://staging-api.carloscloudengineer.com/health`, `/ready` and `/version` all respond correctly over TLS, serving the seeded image.

**This is not met by the branch alone**, and the plan says so rather than letting the pull request blur it. It is met when [the runbook](../../runbooks/phase-05-staging.md) is executed.

The branch's own gate, all of which is verifiable offline:

| # | Criterion | Verified by |
|---|---|---|
| 1 | `make tf-check` passes across all four layers | `make tf-check` |
| 2 | The tables match `app/src/bgd/repository/schema.py`, LSI included | `tests/data_and_iam.tftest.hcl` |
| 3 | The task role grants exactly the four calls the application makes, on three ARNs including the LSI index | `tests/data_and_iam.tftest.hcl` |
| 4 | The execution role's only wildcard is the ECR auth token | `tests/data_and_iam.tftest.hcl` |
| 5 | `runtime_platform` is ARM64 and `BGD_IMAGE_DIGEST` equals the resolved digest | `tests/compute.tftest.hcl` |
| 6 | `propagate_tags = "SERVICE"` is set | `tests/compute.tftest.hcl` |
| 7 | Tasks run in private subnets with no public IP, in the `staging` security group | `tests/compute.tftest.hcl` |
| 8 | The health check polls `/health`, never `/ready` | `tests/edge.tftest.hcl` |
| 9 | 80 redirects to 443; 443 uses the foundation certificate; no `:8443` | `tests/edge.tftest.hcl` |
| 10 | Every name fits the convention and the 32-character cap | `tests/edge.tftest.hcl`, `tests/compute.tftest.hcl` |
| 11 | The consumed output surface is present and correctly shaped | `tests/outputs.tftest.hcl` |
| 12 | checkov reports zero failures; every skip carries a written reason | `./scripts/lint-infra.sh` |
| 13 | `scripts/smoke.sh` detects a digest mismatch and a failing `/ready` | Task 8 Step 3, against the real image |
| 14 | The image serves under a read-only root filesystem | Plan §F5, against the real image |

Criteria 13 and 14 are the two executed against something real rather than mocked, which is why they are listed rather than folded into the gate.

---

## 6. Risks this phase adds

| Risk | Handling |
|---|---|
| **The ECR data source makes `terraform plan` fail when the tag is absent** | Deliberate (D3). The alternative applies a task definition ECS cannot pull. The runbook checks for a tag before planning and the error names the missing tag. |
| **`staging` now depends on `foundation`'s state being readable to destroy** | Accepted. `foundation` is never destroyed — that is why it is a separate layer. |
| **The circuit breaker removes the broken task set before it can be inspected** | Accepted (D8). The log group retains what the container printed, which is the part worth reading. Phase 6's production service keeps the bake period and alarms, which is a slower and more inspectable failure mode. |
| **Four test files repeat the same mock block** | Structural: Terraform's test framework has no shared-setup construct for `mock_provider`. `tests/mocks.tftest.hcl` is the reference copy, and Task 7's interface test is what catches a drift between copies. |
| **checkov skips could accumulate into a habit** | Each of the eight names its trade-off and its scope, and three say explicitly that Phase 6 decides again for production. A skip that does not survive being read is a skip to revisit. |
| **`/ready`'s 25-second failure mode is slow enough to look like a hang** | Documented in F5, handled in `scripts/smoke.sh` with `--max-time 40`, and named in the runbook's failure table. Phase 9 should consider whether `/ready` deserves a shorter botocore retry configuration — noted here rather than changed, because it is an application change and this is an infrastructure phase. |
