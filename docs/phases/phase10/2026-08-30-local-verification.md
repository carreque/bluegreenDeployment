# Phase 10 — local verification record

**Date:** 2026-08-30
**Branch:** `feat/Phase10_TeardownRebuild`
**Plan:** [2026-08-30-phase-10-implementation-plan.md](./2026-08-30-phase-10-implementation-plan.md)
**Pull request:** described in `2026-08-30-pull-request.md`, deleted in `e3583cf`
once the pull request itself was merged — the description lives on the PR.

Everything below ran on a laptop with **no AWS session**. `aws sts
get-caller-identity` returns `InvalidClientTokenId` throughout, which is what
makes §4's claim checkable rather than asserted.

---

## 1. The gate

Three suites, all green.

### `make test-scripts` — new in this phase

```
==> test_common.sh
  test_common.sh: 37 checks, 0 failed

==> test_operator_scripts.sh
  test_operator_scripts.sh: 43 checks, 0 failed

==> test_pipeline_scope.sh
  test_pipeline_scope.sh: 36 checks, 0 failed

  ✓ 3 test files passed
```

**116 checks**, none of which existed before this branch. What each file
protects against:

| File | Checks | The failure it exists to catch |
|---|---|---|
| `test_common.sh` | 37 | A wrong rank is a wrong deployment. Also: the marker read failing *open* on a lost permission, and `put-parameter --overwrite` creating a parameter outside Terraform's state (F5). |
| `test_pipeline_scope.sh` | 36 | A clamp bug in either driver reaches production. Includes Phase 7's and Phase 8's full scope matrices, re-asserted against the clamped scripts so the clamp cannot have changed them. |
| `test_operator_scripts.sh` | 43 | The three scripts that destroy and create. Every `SCOPE` value on both, all six rebuild preconditions, and the marker-before-destroy ordering asserted against the fake CLI's call log. |

Four of `test_common.sh`'s checks assert one property directly, because it is
the property the whole clamp rests on: **`foundation` is in scope under every
valid marker value**, so the layer that creates the marker can always be
applied. Without it a fresh account deadlocks on its first run (D6).

### `make tf-check`

```
Success! 76 passed, 0 failed.     (infra/foundation)
Success! 35 passed, 0 failed.     (infra/environments/prod)
  all infra checks passed
```

`foundation` gains **five new assertions** across two run blocks: four in
`the_platform_carries_a_deployed_scope_marker` (the name, the `all` default, the
`String` type, and a description naming both writers) and one appended to
`the_outputs_phase_8_and_9_consume_are_present`.

`ignore_changes = [value]` is **not** asserted, and the test says why in a
comment rather than leaving the gap silent: `lifecycle` is a meta-argument with
no representation in a resource's plan object. What is asserted instead is the
property that makes it necessary — the value is a literal every apply would
otherwise reassert — plus a description naming `teardown.sh` and `rebuild.sh`,
so a reader who deletes the lifecycle block has been told what it was for.

### `make test-lambdas`

```
45 passed in 0.21s
Required test coverage of 95.0% reached. Total coverage: 97.46%
```

Unchanged by this phase; run to prove it.

### `bash -n`

```
bash -n scripts/*.sh scripts/lib/common.sh scripts/tests/*.sh scripts/tests/fake-bin/aws
```

Silent, across all fourteen scripts, the shared library, the three test files
and the fake CLI.

---

## 2. Static analysis triage

```
./scripts/lint-infra.sh foundation

  ✓ foundation clean                                    (tflint)
  Passed checks: 490, Failed checks: 0, Skipped checks: 110
  ✓ checkov clean
```

Phase 9 left this at **489 / 0 / 109**. The delta is exactly one pass and one
skip, both from the single resource this phase adds.

| Finding | Resource | Disposition |
|---|---|---|
| `CKV2_AWS_34` — "SSM parameters should be encrypted" | `aws_ssm_parameter.deployed_scope` | **Skipped, with the reason written at the resource.** The value is one of four English words, printed in every pipeline skip message and in the console. `SecureString` would imply it is a secret and would cost both pipeline roles a KMS grant to read the word `staging`. This is the identical trade `image_tag` above it already made and states. |

No finding was suppressed without a reason naming the trade-off, and no bare
skip was added.

---

## 3. The executed evidence

Every refusal path below was run by hand against `scripts/tests/fake-bin/aws`,
not merely unit-tested. The fake **exits 90 on any unstubbed subcommand**, so
none of these could have passed by reaching a path nobody wrote.

### 3.1 No `SCOPE` value reaches `foundation` or `bootstrap` (D16)

```
SCOPE=sideways   →  ✗ SCOPE is 'sideways'; expected one of prod, staging, network
SCOPE=foundation →  ✗ SCOPE is 'foundation'; expected one of prod, staging, network
SCOPE=bootstrap  →  ✗ SCOPE is 'bootstrap'; expected one of prod, staging, network
```

`foundation` and `bootstrap` are refused **as unrecognised values**, not by a
special case. There is nothing to forget to update.

`rebuild.sh` refuses the same way on its own vocabulary:

```
SCOPE=sideways   →  ✗ SCOPE is 'sideways'; expected one of network, staging, prod
SCOPE=foundation →  ✗ SCOPE is 'foundation'; expected one of network, staging, prod
```

`verify-idle.sh` likewise:

```
SCOPE=sideways   →  ✗ SCOPE is 'sideways'; expected one of prod, staging, network
```

### 3.2 Both dry runs

`BGD_TEARDOWN_DRY_RUN=1`, all three scopes, showing the derived marker value
rather than one typed twice:

```
SCOPE=prod      will destroy: prod                     will record: … = staging
SCOPE=staging   will destroy: prod, staging            will record: … = network
SCOPE=network   will destroy: prod, staging, network   will record: … = foundation
```

Each also prints what survives, and the `prod` and `staging` cases name the
layers below them explicitly (`…and so are network and staging`).

`BGD_REBUILD_DRY_RUN=1 SCOPE=prod` runs every precondition and stops:

```
==> preconditions
  ✓ account 590184028094
  ✓ state bucket bgd-us-east-1-tfstate-590184028094
  ✓ foundation state present
==> marker currently reads all
  ✓ /bgd/staging/image_tag → 1.0.0-abc1234, present in ECR
  ✓ /bgd/prod/image_tag → 1.0.0-abc1234, present in ECR

  ✓ dry run — preconditions pass; nothing was applied and nothing was written
```

The placement is the value of the flag: a dry run that checks nothing tells you
nothing.

### 3.3 All six rebuild preconditions refuse, before any apply

```
wrong account   ✗ wrong account: session is 111122223333, this project is 590184028094
bucket gone     ✗ state bucket bgd-us-east-1-tfstate-590184028094 is unreachable — bootstrap
                  has not been applied, or the session cannot see it
marker gone     ✗ cannot read /bgd/platform/deployed_scope — apply the foundation layer,
                  which is what creates it
tag unset       ✗ /bgd/staging/image_tag is 'unset' — run 'make seed-ecr' to record a tag,
                  or let the app pipeline set one
tag not in ECR  ✗ /bgd/staging/image_tag names '1.0.0-abc1234', which is not in ECR —
                  data.aws_ecr_image would fail at the staging layer, after the network
                  already exists and is billing
```

The fifth is the one worth having: `data.aws_ecr_image` would catch a missing
tag anyway, but one layer later, after the NAT Gateway exists and has started
billing. The message says so.

`SCOPE=network` with **no** image tag at all exits 0 — there is no container in
that layer, so a network-only rebuild must not demand one.

### 3.4 The marker is written before the first destroy (D3)

Asserted against `FAKE_AWS_LOG`, which records every fake-CLI invocation:

```
$ FAKE_AWS_LOG=$LOG SCOPE=prod ./scripts/teardown.sh <<<"yes"
  type "destroy" to continue:   ✗ aborted — nothing was destroyed and no marker was written

$ cat "$LOG"
(empty)
```

A confirmation that is not the word `destroy` aborts, and aborts **before** the
write — otherwise declining the prompt would still tell both pipelines the
platform is down. Zero AWS calls were made.

The positive direction is asserted in `test_common.sh`: `write_deployed_scope`
reads before it writes (so `--overwrite` cannot create a parameter outside
Terraform's state, F5), and the log then shows `get-parameter` followed by
`put-parameter` carrying the new value.

### 3.5 The two skip messages differ, and neither lies

```
marker, infra    ==> staging is torn down (/bgd/platform/deployed_scope = network) — nothing to do
                 ==> run `make rebuild` to bring it back
scope,  infra    ==> staging is outside DEPLOY_SCOPE=network — nothing to do

marker, app      ==> staging is torn down (/bgd/platform/deployed_scope = network) — nothing to do
                 ==> run `make rebuild` to bring it back
scope,  app      ==> staging is outside APP_SCOPE=build — nothing to do
```

This is asserted, not just observed: `test_pipeline_scope.sh` greps the clamp's
output for `outside DEPLOY_SCOPE` and requires it to be **absent**. A clamp that
blamed the scope would send an operator looking for a bug in scope handling.

Both skips exit 0 and both still write their vars file — `plan-vars.env` for
`plan`, `deploy-vars.env` for `deploy`:

```
PLAN_STATUS=skipped
PLAN_SUMMARY=Skipped.\ prod\ is\ torn\ down\ \(/bgd/platform/deployed_scope\ =\ foundation\)\;\ run\ make\ rebuild.
PLAN_URL=''
```

A skip that wrote nothing would fail the buildspec's `. <file>` and turn a
correct decision into a red stage — the exact failure the ordering exists to
prevent.

### 3.6 `foundation` is exempt, and an unreadable marker is otherwise fatal

```
$ FAKE_SSM_DEPLOYED_SCOPE="" ./scripts/pipeline-terraform.sh apply foundation
  ✗ no saved plan at infra/foundation/pipeline.tfplan — the Plan action in this stage must run first
```

It reached the saved-plan check, which sits immediately after both gates — so
the marker was never read. Exercised through `apply` rather than `plan`
deliberately: an exempt layer proceeds *past* the gates, and `plan foundation`
would then run Terraform, which is the one thing this suite must not do.

Every other layer, same conditions:

```
$ FAKE_SSM_DEPLOYED_SCOPE="" ./scripts/pipeline-terraform.sh plan staging
  ✗ cannot read /bgd/platform/deployed_scope — apply the foundation layer, which is what creates it
```

Fatal, not assumed-`all`. A gate that fails open is not a gate.

---

## 4. No AWS resource was created

- **No AWS session existed at any point.** `aws sts get-caller-identity` returns
  `InvalidClientTokenId` on this machine.
- **Every script under test reached AWS only through
  `scripts/tests/fake-bin/aws`**, put on `PATH` by each test file. It answers
  five subcommand families from environment variables and exits 90 on anything
  else.
- **No `terraform apply` and no `terraform destroy` ran.** The two `terraform`
  invocations in this session were `./scripts/tf.sh validate network` and
  `./scripts/tf.sh fmt prod` (Task 1, step 7), plus `terraform test` runs, all
  of which init with `-backend=false` against `mock_provider`.
- **The one exception is recorded rather than hidden.** In Task 4's and Task 6's
  *watch it fail* steps — before the clamp and before the rewrite — the
  unmodified scripts proceeded past their gates and invoked `terraform`, which
  failed at provider credential validation (`InvalidClientTokenId`, 403 from
  STS). That is a network call to STS and nothing else: no plan was produced, no
  state was read, no resource was created or destroyed. The plan anticipates
  this and says to run the step with no AWS session for exactly that reason.

---

## 5. What remains before the exit criterion is met

The roadmap's criterion — *after a teardown-and-rebuild cycle, both environments
serve traffic again with no manual step other than waiting* — and its fourth
task-list bullet asking for **an executed cycle** are **not met by this branch**.

They are met by [the runbook](../../runbooks/phase-10-teardown-and-rebuild.md),
steps 3 through 6:

1. `make teardown` — typed confirmation, three destroys, timing table.
2. `make verify-idle` — nine direct checks, exit 0.
3. `BGD_REBUILD_DRY_RUN=1 make rebuild` — six preconditions, no resources.
4. `make rebuild` — three applies, two smoke runs, exit 0.

Step 4 exiting 0 **is** the criterion: by D11 it returns 0 only after both
environments were smoke-tested and served the digest Terraform deployed.

The runbook's §7 timing table is deliberately labelled **estimates, not
measurements**. Both scripts print a measured table so the first real run
replaces those numbers; until then nobody has observed them.

---

## 6. Findings discovered during implementation

**F9 — every role that will read the marker already can, but through a managed
policy rather than an explicit grant.**

Verified rather than assumed, because a missing `ssm:GetParameter` would make
every non-`foundation` stage of both pipelines die at the new gate:

| Role | Reads the marker in | Grant |
|---|---|---|
| `infra_plan` | `pipeline-terraform.sh plan` | `ReadOnlyAccess` (managed) |
| `infra_apply` | `pipeline-terraform.sh apply` | `AdministratorAccess` |
| `app_deploy_staging` | `pipeline-deploy.sh deploy` | `AdministratorAccess` |
| `app_plan_prod` | `pipeline-deploy.sh plan` | `ReadOnlyAccess` (managed) |
| `app_deploy_prod` | `pipeline-deploy.sh apply` | `AdministratorAccess` |
| `app_image` | — never reaches the gate | (no SSM read needed) |

So F3's claim holds and this phase changes no IAM, as §0 says it does not.

**The tension worth recording:** `iam-pipeline.tf:236-245` grants
`ssm:GetParameter` on the `image_tag` ARNs *explicitly*, and its own comment
argues why — *"granted explicitly although ReadOnlyAccess almost certainly
covers it: a plan that cannot read the image tag fails inside
`data.aws_ecr_image` with a message about a missing image rather than about a
missing permission, which is a slow way to find a fast problem."* The identical
argument applies to the marker, with a **wider** blast radius: `image_tag` gates
two layers, the marker gates every layer above `foundation`.

It was raised before implementation and the decision was to follow the plan: no
IAM change on this branch. The mitigating fact is that the failure mode differs
— an unreadable marker dies with the parameter's full name and the words *apply
the foundation layer*, which is not a slow way to find anything. Recorded here
so a future phase adding the one-line grant reads it as a deliberate second look
rather than a fix for an oversight.

**F10 — the makefile is not watched by either pipeline trigger, and
`make test-scripts` is now run by a stage.**

`pipelines/infra-validate.yml` runs `make test-scripts`, but neither `makefile`
nor `scripts/tests/**` appears in the infra trigger's seven `filePaths.includes`
patterns. A commit that changed only the suite, or only the target that runs it,
would not fire the pipeline.

This is **pre-existing** rather than introduced here — the trigger has never
watched `makefile`, and every `make` target the Validate stage runs has had the
same property since Phase 7. It is not fixed on this branch: the trigger is at
seven of its eight permitted patterns (F3), and spending the last slot needs an
argument this phase does not have. Recorded so the next phase to touch the
trigger inherits the question rather than rediscovering it.

---

## 7. Departures from the plan's literal text

**Two, both documentation, both agreed before implementation.**

1. **`scripts/README.md`'s Phase 10 paragraph was rewritten, not just appended
   to.** It described `make teardown` as having *"confirmation prompts"*
   (plural) and *"waits on ECS draining"* — written in Phase 3 as a forecast of
   this phase, and wrong after D8 replaced the three Terraform prompts with one
   typed word. The plan's Task 9 step 3 only adds a table and a new paragraph.
   Leaving the old one would have left the file contradicting itself.

2. **Both pipeline drivers' header comments were corrected.** Each stated that
   the layer-name-to-directory map *"already exists in three places (tf.sh,
   lint-infra.sh, teardown.sh)"*. After Task 1 that is false: the map is in
   `lib/common.sh` and `lint-infra.sh` keeps a variant with a different contract.
   Corrected in Task 9's commit, which is where the rest of the documentation
   catch-up lives.

**One thing the plan specifies that is kept despite being arguably wrong.**
`scripts/verify-idle.sh` calls `require_cmd jq`, but never invokes `jq` — every
check uses the AWS CLI's own `--query` and `--output text`. It is a dependency
the script does not have. Raised before implementation and the decision was to
implement the plan verbatim, so it stays. The cost is that `make verify-idle`
refuses to run on a machine without `jq`; `verify-tools.sh` already pins `jq`, so
no supported machine is affected. Noted here so a future removal reads as a
correction rather than a regression.

---

## 8. Carried forward

**Phase 11 needs a rebuilt environment, and `make rebuild` is now the way to get
one.** Its three demonstrations — hook rejection, alarm-triggered rollback during
bake, manual rollback — all require a live production service with the blue/green
controller running. If the account is torn down when Phase 11 starts, that is now
one command and roughly fifteen minutes rather than three `make apply-*` calls in
a remembered order against a remembered image tag.

**Two consequences Phase 11 should know before it starts:**

- **`APP_SCOPE=build` still works while the platform is down.** Phase 11 pushes a
  deliberately broken image to ECR before deciding to deploy it, and the Build
  stage is a different script that never reaches the marker gate. The broken
  image can be built and pushed with the platform torn down, and deployed after
  a rebuild.
- **A merge to `main` will not rebuild anything.** If Phase 11's evidence-taking
  is interrupted by a teardown, the way back is `make rebuild` and not a merge.
  The runbook's §9 has the one-line escape hatch if the pipeline is wanted for it
  instead.

**Nothing in this phase is blocked on Phase 11**, and the reverse is only true if
the account is left down.
