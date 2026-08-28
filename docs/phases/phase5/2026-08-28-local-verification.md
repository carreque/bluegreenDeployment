# Phase 5 — Local Verification

**Date:** 2026-08-28
**Branch:** `feat/Phase5_Staging`
**Status:** Local gate green. **The phase's one exit criterion is not met**
— see §5.
**Plan:** [Phase 5 implementation plan](./2026-08-28-phase-05-implementation-plan.md)
**Runbook:** [staging apply, verification and teardown](../../runbooks/phase-05-staging.md)

Everything Phase 5 could build and prove without an AWS session was built and
proved. **Nothing was applied.** No AWS session exists on this machine —
`aws sts get-caller-identity --profile bootcamp-administrator-access` fails
with an expired SSO token (plan §D1) — and the Phase 3 and Phase 4 runbooks,
which this layer depends on for a readable `foundation`/`network` state and a
seeded ECR image, have not been executed either. This document records what
was run, what it returned, and what is left.

**Headline:** one Terraform layer, sixteen `terraform test` run blocks against
a mocked provider, zero AWS API calls, plus the one part of this phase that
*was* run against something real — a local container, not AWS — which is
Task 8's read-only-root and digest-mismatch evidence in §3.

---

## 1. The gate

`make tf-check` runs `validate`, `tflint`, `checkov` and `terraform test`
across all four layers now in the repository — `bootstrap`, `foundation`,
`network` and `staging`. None of it needs credentials: `scripts/tf.sh`
initialises with `-backend=false`, so the whole gate runs on a machine that
has never logged in.

```
$ make tf-check

==> terraform validate — bootstrap
Success! The configuration is valid.

==> terraform validate — foundation
Success! The configuration is valid.

==> terraform validate — network
Success! The configuration is valid.

==> terraform validate — staging
Success! The configuration is valid.

==> tflint — installing rulesets
==> tflint — bootstrap
  ✓ bootstrap clean
==> tflint — foundation
  ✓ foundation clean
==> tflint — network
  ✓ network clean
==> tflint — staging
  ✓ staging clean
==> checkov — infra/
terraform scan results:

Passed checks: 212, Failed checks: 0, Skipped checks: 32


  ✓ checkov clean

  ✓ static analysis passed
==> terraform test — bootstrap
Success! 5 passed, 0 failed.
==> terraform test — foundation
Success! 14 passed, 0 failed.
==> terraform test — network
Success! 17 passed, 0 failed.
==> terraform test — staging
tests/compute.tftest.hcl... in progress
  run "the_task_definition_carries_the_phase_2_inheritances"... pass
  run "the_container_environment_points_at_this_environments_tables"... pass
  run "the_container_is_hardened_and_logs_where_terraform_says"... pass
  run "the_cluster_is_named_by_convention_and_insights_is_an_explicit_choice"... pass
  run "the_service_runs_private_tasks_with_attributable_tags"... pass
  run "the_service_deploys_by_rolling_and_rolls_itself_back"... pass
tests/compute.tftest.hcl... tearing down
tests/compute.tftest.hcl... pass
tests/data_and_iam.tftest.hcl... in progress
  run "the_tables_match_the_application_schema"... pass
  run "the_task_role_grants_exactly_what_the_application_calls"... pass
  run "the_execution_role_can_pull_only_this_projects_registry"... pass
  run "both_roles_are_assumable_only_by_ecs_tasks_in_this_account"... pass
tests/data_and_iam.tftest.hcl... tearing down
tests/data_and_iam.tftest.hcl... pass
tests/edge.tftest.hcl... in progress
  run "the_load_balancer_is_public_and_uses_this_environments_security_group"... pass
  run "the_target_group_health_checks_liveness_only"... pass
  run "http_redirects_and_https_terminates_with_the_foundation_certificate"... pass
  run "the_hostname_aliases_this_environments_load_balancer"... pass
tests/edge.tftest.hcl... tearing down
tests/edge.tftest.hcl... pass
tests/mocks.tftest.hcl... in progress
  run "the_mock_reference_resolves"... pass
tests/mocks.tftest.hcl... tearing down
tests/mocks.tftest.hcl... pass
tests/outputs.tftest.hcl... in progress
  run "the_consumed_surface_is_present_and_correctly_shaped"... pass
tests/outputs.tftest.hcl... tearing down
tests/outputs.tftest.hcl... pass

Success! 16 passed, 0 failed.

  all infra checks passed
```

Four layers, **52 `terraform test` run blocks** (5 + 14 + 17 + 16), zero AWS
API calls. `./scripts/tf.sh test staging` and
`./scripts/lint-infra.sh environments/staging` were each re-run standalone
and match: `Success! 16 passed, 0 failed.` and
`Passed checks: 212, Failed checks: 0, Skipped checks: 32` respectively.

### 1.1 The staging layer's sixteen assertions

Sixteen `run` blocks, one row each, across five test files. Every run that
reads a block-typed or computed attribute (target group health check, the
service's network configuration, the container definition JSON) uses
`command = apply` against the mocked provider — those attributes stay
`(known after apply)` under `plan`. Nothing is created; the provider is
mocked, so `apply` here makes no API call and needs no credential.

| File | Run | Protects against |
|---|---|---|
| `mocks` | `the_mock_reference_resolves` | the reference mock block and both `override_data` overrides actually reach `locals.tf` — the sanity check every other file's copy is diffed against |
| `data_and_iam` | `the_tables_match_the_application_schema` | the two tables and the `created_at-index` LSI drifting from `app/src/bgd/repository/schema.py` — the LSI cannot be added after the table exists, so this is a destroy-and-recreate if wrong, not a fix |
| `data_and_iam` | `the_task_role_grants_exactly_what_the_application_calls` | the task role granting a different action set than `dynamodb.py` calls — six actions (`GetItem`, `PutItem`, `Query`, `Scan`, `UpdateItem`, `TransactWriteItems`), the corrected set from R5/F6's amendment, plus the LSI index ARN and a single-statement scope |
| `data_and_iam` | `the_execution_role_can_pull_only_this_projects_registry` | the ECR pull being scoped to this project's repository ARN rather than every repository in the account, and the registry-wide `GetAuthorizationToken` wildcard staying isolated to its own statement |
| `data_and_iam` | `both_roles_are_assumable_only_by_ecs_tasks_in_this_account` | a confused-deputy trust policy — only `ecs-tasks.amazonaws.com` conditioned on this account may assume either role |
| `compute` | `the_task_definition_carries_the_phase_2_inheritances` | the two Phase 2 inheritances that fail silently: `runtime_platform.cpu_architecture == ARM64` (an X86_64 definition cannot start the image) and the container pinned to the ECR-resolved digest with `BGD_IMAGE_DIGEST` equal to it (or `/version` reports `unknown`) |
| `compute` | `the_container_environment_points_at_this_environments_tables` | the container pointed at staging's own table names, and `BGD_DYNAMODB_ENDPOINT_URL` staying absent (set, it would point the client at DynamoDB Local instead of real AWS) |
| `compute` | `the_container_is_hardened_and_logs_where_terraform_says` | `readonlyRootFilesystem` staying `true` (measured safe against the real image in §3/plan F5), logs routed to the Terraform-managed group by exact name, and the container port matching what `network`'s security groups opened |
| `compute` | `the_cluster_is_named_by_convention_and_insights_is_an_explicit_choice` | the cluster name breaking convention, and `containerInsights` reverting to an implicit default instead of the explicit `"disabled"` the plan's D7 requires |
| `compute` | `the_service_runs_private_tasks_with_attributable_tags` | the service name, `propagate_tags = "SERVICE"` (optional and **not computed** — silently dropped tasks go untagged with `plan` staying clean), private subnets, no public IP, and the staging (not prod) task security group |
| `compute` | `the_service_deploys_by_rolling_and_rolls_itself_back` | `strategy = "ROLLING"` (the one-word difference from Phase 6), the circuit breaker enabled with rollback (D8), the `load_balancer` block's container name matching the task definition, and `desired_count == 1` |
| `edge` | `the_load_balancer_is_public_and_uses_this_environments_security_group` | the ALB name/32-char cap, internet-facing, correct public subnets, the staging (not prod) ALB security group, deletion protection off, and malformed headers dropped at the edge |
| `edge` | `the_target_group_health_checks_liveness_only` | target type `ip` (required for `awsvpc`/Fargate), the health check polling `/health` and never `/ready` (which would deregister every task on one DynamoDB hiccup), the port, and a 30s deregistration delay instead of the 300s default that would make every rolling deploy take five minutes |
| `edge` | `http_redirects_and_https_terminates_with_the_foundation_certificate` | port 80 redirecting (not serving) with a permanent 301 to 443, the HTTPS listener using the certificate ARN read from `foundation`'s remote state, the TLS 1.2-floor/1.3 policy, and no `:8443` test listener (Phase 6 only) |
| `edge` | `the_hostname_aliases_this_environments_load_balancer` | the Route 53 record using the hostname `foundation` derives (not one recomposed here), the correct hosted zone, an alias A record (not a CNAME, which cannot sit at an apex), and the alias targeting this layer's own ALB |
| `outputs` | `the_consumed_surface_is_present_and_correctly_shaped` | all nine outputs — `api_url`, `image_digest`, `cluster_name`, `service_name`, `task_definition_family`, `log_group_name`, both table names, `alb_dns_name` — drifting from what `scripts/smoke.sh`, the runbook and Phase 6/8 read by name; this is the run the plan's own test code originally left `task_definition_family` unguarded on (R9, corrected — see the [plan's amendment](./2026-08-28-phase-05-implementation-plan.md)) |

---

## 2. Static analysis triage

### 2.1 Before and after

Plan §F4 ran checkov against a complete draft of this layer, before any skip
was added:

```
Passed checks: 72, Failed checks: 10, Skipped checks: 0
```

Ten failures across six categories: `CKV_AWS_150`, `CKV_AWS_91`,
`CKV2_AWS_28` on the ALB; `CKV_AWS_28` and `CKV_AWS_119` on both tables (four
findings); `CKV_AWS_158` and `CKV_AWS_338` on the log group; `CKV_AWS_65` on
the cluster. Every one became a written skip — nothing in the task
definition failed at any point: `readonlyRootFilesystem`, the non-root user
inherited from the image, and the log configuration all passed as drafted.

checkov has no per-layer scope — it scans `infra/` as one tree — so there is
no isolated "staging only" after-number the way Phase 4's record could
produce for `network` alone. What this session confirmed instead, twice
(`make tf-check` and `./scripts/lint-infra.sh environments/staging`), is the
whole-repository state with staging complete:

```
Passed checks: 212, Failed checks: 0, Skipped checks: 32
```

### 2.2 The eight skips in `infra/environments/staging`

Eight distinct check codes, ten annotated locations — `CKV_AWS_28` and
`CKV_AWS_119` each apply once per table, so each appears twice.

| File:line | Code | Reason |
|---|---|---|
| `dynamodb.tf:11` | `CKV_AWS_28` | Point-in-time recovery buys nothing on tables `make teardown` destroys and a rebuild recreates empty. There is no point in time worth recovering to. Plan §D6. |
| `dynamodb.tf:12` | `CKV_AWS_119` | The AWS-owned key, not a customer-managed CMK, for the reason recorded in the Phase 3 plan §D4 — a CMK bills a request per read and write on the application's entire data path. |
| `dynamodb.tf:35` | `CKV_AWS_28` | Same reason, on `transactions` — plan §D6. |
| `dynamodb.tf:36` | `CKV_AWS_119` | Same reason, on `transactions` — Phase 3 plan §D4. |
| `ecs.tf:2` | `CKV_AWS_338` | Fourteen-day log retention is deliberate on an environment destroyed when idle; retention is the entirety of what a log group costs. Same reasoning as `network`'s flow logs. |
| `ecs.tf:3` | `CKV_AWS_158` | AES256 rather than KMS — application logs from a staging environment carrying no production data, same family as the Phase 3 plan §D4 precedent. |
| `ecs.tf:9` | `CKV_AWS_65` | Container Insights bills per custom metric on the layer whose purpose is being cheap to leave running; Phase 9 owns observability and builds the dashboard that would consume it. Written as an explicit `"disabled"` rather than omitted, so the choice is visible (plan §D7). |
| `alb.tf:7` | `CKV_AWS_150` | Deletion protection would make `terraform destroy` fail and break `make teardown`, the policy the five-layer split exists to serve (roadmap §1). |
| `alb.tf:8` | `CKV_AWS_91` | ALB access logging is deliberately off for staging, which carries no production data; the ALB's CloudWatch metrics and Phase 4's VPC flow logs answer the same questions. Enabling it means either a bucket policy in `foundation` or a bucket in this disposable layer. Phase 6 decides separately for production, where access logs are genuine blue/green evidence. Plan §D5. |
| `alb.tf:9` | `CKV2_AWS_28` | A WAF web ACL is a monthly charge plus per-request billing for a demo API with no attack surface worth the spend, and was never part of the design. |

`tflint` 0.60.0 with AWS ruleset 0.44.0 reports **no findings** on the
staging layer, confirmed by both `make tf-check` and
`./scripts/lint-infra.sh environments/staging` above. This was not always
true offline: see §6's `lint-infra.sh` entry.

---

## 3. The executed evidence

This is the part of Phase 5 that carries the most weight, because it is the
only part run against something real rather than mocked — a local container,
not AWS. Taken verbatim from
[Task 8's report](../../../.superpowers/sdd/2026-08-28-phase-05-implementation-plan/task-8-report.md).

**Read-only root filesystem, against the real Phase 2 image:**

```
$ docker run -d --name bgd-smoke-probe --read-only -p 18080:8080 \
    -e BGD_IMAGE_DIGEST=sha256:aaaa \
    -e BGD_DYNAMODB_ENDPOINT_URL=http://127.0.0.1:9 \
    "$(cat app/dist/image-ref.txt)"
```

The container started and served under `--read-only`, confirming
`readonlyRootFilesystem = true` in `ecs.tf` is safe rather than merely hoped:
the image sets `PYTHONDONTWRITEBYTECODE=1` and nothing in the request path
writes to disk.

**Run (a) — correct digest (`sha256:aaaa`), timed:**

```
==> smoke — staging
  /health    ✓
  /ready     ✗ HTTP 503 (expected 200)
    {"status":"not_ready","checks":{"dynamodb":"unavailable"}}
  /version   ✓
  digest     ✓

  ✗ 1 smoke check(s) failed against staging
exit=1
elapsed_total=25.776803000
```

`/health` and `/version` return effectively instantly, so essentially all of
the measured **~25.8 seconds** is the `/ready` probe itself — this is the
direct evidence that `--max-time 40` (not the conventional 10) is necessary
in `scripts/smoke.sh`: a 10-second timeout would have reported "no response"
rather than the 503 that names DynamoDB as the cause. Only `/ready` failed;
digest matched and passed, exactly as expected against a dead DynamoDB
endpoint.

**Run (b) — deliberately wrong digest (`sha256:bbbb`):**

```
==> smoke — staging
  /health    ✓
  /ready     ✗ HTTP 503 (expected 200)
  /version   ✓
  digest     ✗ serving sha256:aaaa, Terraform deployed sha256:bbbb

  ✗ 2 smoke check(s) failed against staging
exit=1
```

The digest row correctly fails and names **both** values — what is actually
being served (from the container's own `/version` response) and what
Terraform "deployed" (the deliberately wrong value injected for the test) —
which is what makes `scripts/smoke.sh` a deployment check rather than a
liveness check. The container was removed cleanly afterward; no leftover
container.

---

## 4. No AWS resource was created

No AWS session exists on this machine. The same proof Phase 4's §3 gives:

```
$ aws sts get-caller-identity --profile bootcamp-administrator-access
aws: [ERROR]: Error when retrieving token from sso: Token has expired and refresh failed
```

`terraform test` against `mock_provider "aws"` makes no API call at all —
`mock_provider` replaces every data source and resource the AWS provider
owns, including `aws_iam_policy_document` and `aws_ecr_image`, with local
computation (plan §F1, §F2). `data.terraform_remote_state` is handled the
same way via `override_data` (plan §F3), whose failure mode when forgotten is
the safe one: the test reaches for the real S3 backend and dies on
credentials, not on a silent `null`. This layer's Task 8 container evidence
in §3 above ran entirely against a locally built Docker image on this
machine — it is real execution, but it is not AWS.

---

## 5. What remains before the exit criterion is met

Roadmap §3 gives Phase 5 one exit criterion:

> `https://staging-api.carloscloudengineer.com/health`, `/ready` and
> `/version` all respond correctly over TLS, serving the seeded image.

It is **not met by this branch** — it needs
[the runbook](../../runbooks/phase-05-staging.md), which needs an AWS session
and both the Phase 3 and Phase 4 runbooks already executed, none of which
this machine has.

- [ ] Confirm all three preconditions (runbook §1): `foundation` applied,
      `network` applied, and an image tag seeded in ECR — **blocked on the
      Phase 3 and Phase 4 runbooks having been executed first**
- [ ] `aws sso login --profile bootcamp-administrator-access` (runbook §2)
- [ ] Set `image_tag` in `terraform.tfvars` (runbook §3)
- [ ] `make tf-check` against the real toolchain (runbook §4) — expected
      green; this is a re-run of §1 above, not a new gate
- [ ] `make plan-staging` (runbook §5) — confirm exactly 15 resources to add,
      0 to change or destroy; **this is the first time `data.aws_ecr_image`
      runs against real ECR**
- [ ] `make apply-staging` (runbook §6) — **`terraform apply` succeeds
      cleanly**
- [ ] `make smoke-staging` (runbook §7) — **`/health`, `/ready`, `/version`
      and the digest match all pass**, the exit criterion itself
- [ ] Exercise the write path: `POST /api/accounts`, `POST
      /api/transactions` twice (idempotency), `GET /api/transactions`
      (runbook §8) — the only calls in the whole runbook that exercise the
      LSI query and the `transact_write_items` compound write; report whether
      the POST succeeds (see §6 below)
- [ ] Confirm `propagate_tags` actually tagged the running tasks via the AWS
      CLI (runbook §9) — `terraform plan` cannot show this, since the
      attribute is optional and not computed
- [ ] Force a rolling deployment and observe it (runbook §10)
- [ ] `make teardown` then rebuild once and re-verify (runbook §11) — proves
      the layer is reproducible, then leaves the account at the
      foundation-only baseline per the session teardown practice

Until then the branch's own gate is `make tf-check`, and it is green.

---

## 6. Carried forward

| Item | Why it matters |
|---|---|
| **The task role's real action set is six, not four** | Plan §F6 undercounted (R5/R7 — see the [plan's amendment](./2026-08-28-phase-05-implementation-plan.md)): `dynamodb:UpdateItem` and `dynamodb:TransactWriteItems` are required alongside `GetItem`/`PutItem`/`Query`/`Scan`, for `post_transaction`'s compound write. Phase 6's production task role grants the same application, so it needs the same six actions — this is not a staging-only fact. |
| **Whether `TransactWriteItems` is separately required is still open** | Granted together with `UpdateItem`, so a successful `POST /api/transactions` proves the pair sufficient but cannot isolate which member was necessary (Ruling R12 — the runbook's Step 8 originally overclaimed that it would). The isolating experiment — remove `TransactWriteItems`, apply, repeat the call — is described in the runbook as optional tidying, not a required step. Phase 6 inherits the same open question and the same policy shape; if it is settled during the Phase 5 runbook's execution, carry the answer into Phase 6's plan rather than re-deriving it. |
| **Provider-schema facts confirmed against the installed 6.61 binary (plan §F7)** | `aws_ecs_service.deployment_configuration` exposes `strategy`, `bake_time_in_minutes`, `canary_configuration`, `linear_configuration` and a `lifecycle_hook` set (`hook_target_arn`, `lifecycle_stages`, `role_arn`); `load_balancer.advanced_configuration` exposes `production_listener_rule`, `test_listener_rule`, `role_arn` and `alternate_target_group_arn`. `production_listener_rule` is a listener **rule** ARN and `role_arn` is required — design §5's and §8.1's Phase 0 amendments hold. **No provider upgrade is needed for Phase 6.** This layer pins `deployment_configuration { strategy = "ROLLING" }` explicitly even though it is the default, precisely so the one-word change to `BLUE_GREEN` is the visible difference between the two layers. |
| **The `lint-infra.sh` layer-path bug was latent since Phase 3, fixed here** | `scripts/lint-infra.sh` passed its layer argument straight to `tflint --chdir`, relative to `infra/`. `scripts/tf.sh` and `scripts/teardown.sh` both already mapped `staging`/`prod` to `infra/environments/<layer>`; `lint-infra.sh` did not. Invisible until this phase put a layer below `infra/` for the first time and `TF_LAYERS` fed it `staging` directly — `make tf-check` failed with `chdir staging: no such file or directory` (Ruling R10). Fixed with a `layer_path()` helper carrying the same mapping; verified against the bare name, the explicit `environments/staging` form, and the no-argument auto-discovery form, all clean. Any future layer added below `infra/environments/` should re-check this helper covers it. |
| **The provider lock file needs the same three-platform check on every new layer** | Task 1's freshly generated `.terraform.lock.hcl` resolved AWS provider 6.62.0 with a single `darwin_arm64` h1 hash, while the three sibling layers all lock 6.61.0 across three platforms (Ruling R4). A single-platform lock would have failed Phase 7's CodeBuild `terraform init` on Linux two phases later, with no obvious link back to this layer. Re-locked at 6.61.0 across the same three platforms and verified byte-identical to `network`'s hashes. Phase 6 should verify its own lock file's platform count before merging, not after CI fails on it. |
| **The deployment circuit breaker is a staging-only mechanism, not a Phase 6 pattern to copy as-is** | Enabled with rollback (D8): a task that never becomes healthy reverts staging automatically, and the broken task set is gone before anyone can inspect it — the log group is what is left to read. Production keeps the five-minute bake period and CloudWatch alarms instead, a slower and more inspectable failure mode, by design (roadmap §3, risk table). |
| **The IAM policies are built with `jsonencode`, not `aws_iam_policy_document`, for a reason that also applies to Phase 6** | `mock_provider` mocks every data source the AWS provider owns, including the policy document generator, even though it is a pure local computation — it returns a random string under test and `aws_iam_role` rejects it client-side (plan §F1/D9). `jsonencode` keeps the JSON real under mocks, which is what let this layer's tests assert exactly what each policy grants rather than merely that policies exist. Phase 6's additional Lambda-execution roles should follow the same pattern if they are to be tested the same way. |
| **`tests/mocks.tftest.hcl` duplication is structural, and Task 7's interface test is the only thing that catches drift** | Terraform's test framework has no shared-setup construct for `mock_provider`, so all five test files in this layer repeat the same mock block verbatim. `tests/mocks.tftest.hcl` is the reference copy a reviewer diffs against; nothing mechanical enforces the copies stay identical except the outputs test noticing a real behavioural difference. Phase 6's own test files should follow the same convention and carry the same caveat. |
