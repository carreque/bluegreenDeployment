# Phase 8 — local verification record

**Date:** 2026-08-30
**Branch:** `feat/Phase8_AppPipeline`
**AWS resources created:** none. **AWS API calls made:** none that succeeded —
this machine has no session, and §4 records what that proves and what it does
not.

Everything below was executed. Where a command's output is quoted, it is the
output, not a description of it.

**Companion documents:**
[plan](./2026-08-30-phase-08-implementation-plan.md) ·
[runbook](../../runbooks/phase-08-app-pipeline.md) ·
[Phase 7 verification record](../phase7/2026-08-29-local-verification.md)

---

## 1. The gate

```
$ make tf-check          # on a machine that has never run `aws sso login`

  ✓ bootstrap clean          terraform validate — 5 layers, all valid
  ✓ foundation clean
  ✓ network clean
  ✓ staging clean
  ✓ prod clean               tflint, all five layers

  Passed checks: 457, Failed checks: 0, Skipped checks: 101
  ✓ checkov clean

  bootstrap    Success!  5 passed, 0 failed
  foundation   Success! 65 passed, 0 failed
  network      Success! 17 passed, 0 failed
  staging      Success! 16 passed, 0 failed
  prod         Success! 35 passed, 0 failed

  all infra checks passed
```

138 test runs across five layers. The foundation layer went from **35 to 65** —
30 new runs carrying 77 assertions, all in the two new files. No existing run
was changed except the infra trigger's, which now asserts the narrowed list.

### The application gates, proved unchanged

```
$ make lint            All checks passed! · 45 files already formatted
                       All checks passed! ·  3 files already formatted
$ make test            135 passed, 13 deselected · coverage 92.01% (gate 90%)
$ make test-lambdas     17 passed · coverage 100.00% (gate 95%)
$ make image-verify
  build 1  sha256:9e870c412fa09df5bff5b49b74306da0986094e37acf9a4c4aacbff400fe6647
  build 2  sha256:9e870c412fa09df5bff5b49b74306da0986094e37acf9a4c4aacbff400fe6647
  ✓ reproducible — both builds produced the same manifest digest
```

That digest is worth a second look: it is **the same digest the pipeline build
script produced** in §3's end-to-end run. The build reached through
`scripts/pipeline-app-build.sh` and the build reached through `make build` are
the same build, which is the claim D8 and F2 exist to protect.

### The 30 new runs

`tests/app_pipeline_shape.tftest.hcl` — 22 runs, 57 assertions:

```
the_scope_table_gates_the_two_deploy_stages_and_nothing_else
the_exported_variable_names_are_declared_once
app_scope_defaults_to_all_because_a_git_run_supplies_no_variables
only_the_image_build_is_arm_and_only_the_image_build_is_privileged
the_production_apply_may_block_through_a_bake
each_project_runs_its_own_buildspec_under_its_own_role
every_app_build_writes_to_its_own_log_group_with_retention
the_buildspecs_export_exactly_what_the_pipeline_interpolates
the_two_buildspecs_that_need_no_terraform_do_not_install_it
only_the_production_plan_publishes_a_workspace
the_stages_are_source_build_staging_then_prod
the_source_action_hands_the_build_a_clone_not_a_zip
the_deploy_staging_stage_deploys_then_smokes_in_that_order
the_prod_stage_plans_then_approves_then_applies
the_build_action_is_namespaced_so_its_tag_can_be_interpolated
both_deploy_stages_are_scope_gated_and_skip_rather_than_fail
app_scope_is_an_execution_variable_defaulting_to_all
the_trigger_watches_app_and_this_pipelines_own_executable_content
the_infra_trigger_narrowed_when_the_app_buildspecs_arrived
the_two_pipelines_share_a_connection_a_bucket_and_nothing_else
app_pipeline_artifacts_expire_and_the_build_outputs_do_not
the_outputs_phase_9_and_the_runbook_consume_are_present
```

`tests/app_pipeline_iam.tftest.hcl` — 8 runs, 20 assertions:

```
the_two_deploy_roles_are_two_roles
no_role_but_the_two_deploy_roles_is_an_administrator
every_app_pipeline_role_trusts_the_right_service_and_only_this_account
the_smoke_role_makes_no_aws_call_at_all
the_image_role_pushes_to_one_repository_and_records_nothing
the_four_roles_whose_builds_clone_the_repository_may_use_the_connection
the_app_pipeline_role_names_everything_it_may_touch
the_production_plan_role_can_lock_state_but_cannot_write_it
```

### What each group protects against

**The wiring a plan review cannot see.** Stage order is a list position;
artifact hand-off is a string that has to match another string in a different
block; `run_order` inside a stage decides whether smoke probes the new
deployment or races it. `apply_consumes_the_plan_action_output` is the sharpest
of these: if `Prod`/`Apply` took `source` instead of `plan_prod` it would
re-plan, the approval would have approved something else, and **no error would
appear at any point**.

**The two namespaces.** `namespace` does not default. Without
`namespace = "Build"` every `#{Build.IMAGE_TAG}` resolves to nothing and every
later stage deploys an empty tag; without `namespace = "PlanProd"` the approval
shows the literal placeholder. Both are asserted, and so is the reverse: that
every action which deploys or plans actually receives `#{Build.IMAGE_TAG}`
rather than reading SSM.

**The buildspecs' exported names.** Read with `yamldecode` rather than
`strcontains`, unlike Phase 7's equivalent, so the assertion is that the list
under `env.exported-variables` **is** the list in `locals.tf` — a name left
behind in a comment satisfies `strcontains` and would not satisfy this.

**`ARM_CONTAINER` on the image build, and only there.** An x86 build produces an
amd64 manifest that pushes cleanly and fails minutes later at task start with an
exec format error. That assertion is worth its line.

**D6's two boundaries.** The smoke role holds nothing outside `logs:` and `s3:`;
the two deploy roles are two distinct roles. Both erode quietly and nothing
fails when they do.

**Design §4.2's history.** No expiry rule may cover `app-builds/`. See §1.1.

### One assertion was mutation-tested rather than trusted

The `app-builds/` guard is the one whose failure would be silent and permanent —
an SBOM deleted thirty days after a deployment is not recoverable — so it was
attacked in both directions rather than read.

```
$ # mutation 1: point the app-pipeline rule's prefix at app-builds/
  run "app_pipeline_artifacts_expire_and_the_build_outputs_do_not"... fail

$ # mutation 2: replace the prefix filter with an unscoped `filter {}`
  run "app_pipeline_artifacts_expire_and_the_build_outputs_do_not"... fail
```

The second mutation is the reason the assertion is not just
`!startswith(prefix, "app-builds")`. A rule with a **null** prefix covers
everything including `app-builds/`, and a naive check passes it. The condition
requires both that an expiring rule has a non-empty prefix and that
`app-builds/` does not start with it.

---

## 2. Static analysis triage

checkov: **457 passed, 0 failed, 101 skipped.** tflint: clean on all five
layers. Every finding this phase introduced was skipped with the argument
attached, and F10 predicted all four correctly:

| Check | Where | Argument |
|---|---|---|
| `CKV_AWS_147` | all five projects | SSE-S3 rather than a customer-managed key, decided once in Phase 3 §D4 |
| `CKV_AWS_338` | all five log groups | thirty days is what `var.pipeline_log_retention_days` says, and the durable record lives in `app-builds/` |
| `CKV_AWS_158` | all five log groups | AES256, Phase 3 §D4; each skip names what its own group actually holds |
| `CKV_AWS_316` | `app_image` only | privileged twice over — the `docker-container` buildx driver Phase 2 §F1 proved is the only one honouring `rewrite-timestamp`, and D10's two test containers |
| `CKV_AWS_274` | both deploy roles | `AdministratorAccess`, argued in D6 |
| `CKV_AWS_219` | the pipeline | SSE-S3 on the artifact bucket, Phase 3 §D4 |

The `CKV_AWS_338`/`CKV_AWS_158` skips are written per group rather than
copy-pasted: each names what that group holds, because a skip that could be
about any resource is a skip nobody will re-read.

### One tflint finding, and it was the plan working

```
foundation/variables.tf:187:1: Warning - variable
  "app_pipeline_artifact_retention_days" is declared but not used
```

Task 1 declares the variable and Task 10 consumes it, so the gate correctly
reported an unused declaration in between. It cleared when the lifecycle rule
landed. Recorded because a warning that resolves itself two tasks later is
easy to mistake for a warning that was suppressed.

---

## 3. The executed evidence

### 3.1 The scope gate — D4's second gate actually refuses

The whole of D3's table, executed, in all three modes:

```
SCOPE    MODE     ENV      RESULT
build    deploy   staging  exit 0 — staging is outside APP_SCOPE=build — nothing to do
build    deploy   prod     exit 0 — prod is outside APP_SCOPE=build — nothing to do
build    plan     staging  exit 0 — staging is outside APP_SCOPE=build — nothing to do
build    plan     prod     exit 0 — prod is outside APP_SCOPE=build — nothing to do
build    apply    staging  exit 0 — staging is outside APP_SCOPE=build — nothing to do
build    apply    prod     exit 0 — prod is outside APP_SCOPE=build — nothing to do
staging  deploy   staging  exit 1 — Error: validating provider credentials … STS
staging  deploy   prod     exit 0 — prod is outside APP_SCOPE=staging — nothing to do
staging  plan     staging  exit 1 — ✗ terraform plan failed for staging (exit 1)
staging  plan     prod     exit 0 — prod is outside APP_SCOPE=staging — nothing to do
staging  apply    staging  exit 1 — ✗ no saved plan at infra/environments/staging/pipeline.tfplan
staging  apply    prod     exit 0 — prod is outside APP_SCOPE=staging — nothing to do
all      deploy   staging  exit 1 — Error: validating provider credentials … STS
all      deploy   prod     exit 1 — Error: validating provider credentials … STS
all      plan     staging  exit 1 — ✗ terraform plan failed for staging (exit 1)
all      plan     prod     exit 1 — ✗ terraform plan failed for prod (exit 1)
all      apply    staging  exit 1 — ✗ no saved plan at infra/environments/staging/pipeline.tfplan
all      apply    prod     exit 1 — ✗ no saved plan at infra/environments/prod/pipeline.tfplan
bogus    deploy   staging  exit 1 — ✗ APP_SCOPE is 'bogus'; expected one of build, staging, all
bogus    deploy   prod     exit 1 — ✗ APP_SCOPE is 'bogus'; expected one of build, staging, all
bogus    plan     staging  exit 1 — ✗ APP_SCOPE is 'bogus'; expected one of build, staging, all
bogus    plan     prod     exit 1 — ✗ APP_SCOPE is 'bogus'; expected one of build, staging, all
bogus    apply    staging  exit 1 — ✗ APP_SCOPE is 'bogus'; expected one of build, staging, all
bogus    apply    prod     exit 1 — ✗ APP_SCOPE is 'bogus'; expected one of build, staging, all
```

Read it against D3's table. Every out-of-scope cell exits **0** having skipped;
every in-scope cell reaches Terraform and fails for want of an AWS session,
which is expected on this machine and is not what this is testing. `bogus`
refuses all six rather than ranking as a silent `build`.

**This is the finding that matters most in this phase**, exactly as its
counterpart was in Phase 7: it is what makes being wrong about `MATCHES` cost an
unwanted approval rather than an unwanted production deployment.

### 3.2 The ordering constraint, demonstrated

The six `build`-scope rows in `apply` mode are the demonstration. An
out-of-scope apply reports a skip rather than dying on a plan file the skipped
plan never wrote — which is only true because the scope check runs **before**
the saved-plan check:

```
$ APP_SCOPE=build IMAGE_TAG=… ./scripts/pipeline-deploy.sh apply prod
==> prod is outside APP_SCOPE=build — nothing to do                    # exit 0

$ APP_SCOPE=all IMAGE_TAG=… ./scripts/pipeline-deploy.sh apply prod
  ✗ no saved plan at infra/environments/prod/pipeline.tfplan — the Plan action
    in this stage must run first
```

The first would be a **red stage on a correct skip** if the two checks were the
other way round.

### 3.3 Every other refusal path

```
$ ./scripts/pipeline-deploy.sh deploy staging
  ✗ APP_SCOPE is unset — the pipeline action must pass it as an EnvironmentVariables override

$ APP_SCOPE=all ./scripts/pipeline-deploy.sh deploy bogus
  ✗ unknown environment: bogus (expected staging or prod)

$ APP_SCOPE=all ./scripts/pipeline-deploy.sh destroy prod
  ✗ unknown mode: destroy (expected deploy, plan or apply)

$ APP_SCOPE=all ./scripts/pipeline-deploy.sh deploy
  ✗ usage: pipeline-deploy.sh <deploy|plan|apply> <staging|prod>

$ APP_SCOPE=all ./scripts/pipeline-deploy.sh plan prod
  ✗ IMAGE_TAG is unset — the pipeline action must pass it as #{Build.IMAGE_TAG}

$ APP_SCOPE=all IMAGE_TAG=unset ./scripts/pipeline-deploy.sh plan prod
  ✗ IMAGE_TAG is 'unset' — the Build stage did not export a tag, and deploying
    that literal would fail one layer deeper in data.aws_ecr_image
```

The last one matters: `unset` is the literal value `foundation` seeds the SSM
parameters with, so it is the value a mis-wired pipeline is most likely to
carry, and it is refused **by name** rather than passed to `data.aws_ecr_image`.

### 3.4 Both variables files, written and sourced back

Every script writes its variables file on **every** path including the skip,
because the buildspec sources it and a missing file would fail the build —
turning a correct skip into a red stage.

```
$ APP_SCOPE=build … ./scripts/pipeline-deploy.sh deploy staging >/dev/null
$ cat deploy-vars.env
SMOKE_URL=''
SMOKE_DIGEST=''
$ set -a && . ./deploy-vars.env && set +a
SMOKE_URL=[]
SMOKE_DIGEST=[]

$ APP_SCOPE=staging … ./scripts/pipeline-deploy.sh plan prod >/dev/null
$ cat plan-vars.env
PLAN_STATUS=skipped
PLAN_SUMMARY=Skipped.\ prod\ is\ outside\ APP_SCOPE=staging.
PLAN_URL=''
$ set -a && . ./plan-vars.env && set +a
PLAN_STATUS=[skipped]
PLAN_SUMMARY=[Skipped. prod is outside APP_SCOPE=staging.]
```

The `%q` quoting is what makes `set -a && . ./plan-vars.env` safe for a summary
containing spaces — the round trip above is the proof, not the intention. Both
files are in `.gitignore` and were removed afterwards.

### 3.5 Phase 7's matrix, re-run against the refactored script

Task 5 moved `write_vars`, `build_url` and the plan-summary formatting out of
`scripts/pipeline-terraform.sh` into `lib/common.sh`. **A refactor of the file
holding the second of two safety gates is not verified by reading it**, so the
whole of Phase 7's recorded matrix was executed again:

```
SCOPE       LAYER       RESULT
foundation  foundation  exit 1 — terraform plan failed for foundation (exit 1)
foundation  network     exit 0 — network is outside DEPLOY_SCOPE=foundation — nothing to do
foundation  staging     exit 0 — staging is outside DEPLOY_SCOPE=foundation — nothing to do
foundation  prod        exit 0 — prod is outside DEPLOY_SCOPE=foundation — nothing to do
network     foundation  exit 1 — terraform plan failed for foundation (exit 1)
network     network     exit 1 — terraform plan failed for network (exit 1)
network     staging     exit 0 — staging is outside DEPLOY_SCOPE=network — nothing to do
network     prod        exit 0 — prod is outside DEPLOY_SCOPE=network — nothing to do
staging     foundation  exit 1 — terraform plan failed for foundation (exit 1)
staging     network     exit 1 — terraform plan failed for network (exit 1)
staging     staging     exit 1 — cannot read /bgd/staging/image_tag — apply the foundation layer before planning staging
staging     prod        exit 0 — prod is outside DEPLOY_SCOPE=staging — nothing to do
all         foundation  exit 1 — terraform plan failed for foundation (exit 1)
all         network     exit 1 — terraform plan failed for network (exit 1)
all         staging     exit 1 — cannot read /bgd/staging/image_tag — apply the foundation layer before planning staging
all         prod        exit 1 — cannot read /bgd/prod/image_tag — apply the foundation layer before planning prod
bogus       foundation  exit 1 — DEPLOY_SCOPE is 'bogus'; expected one of foundation, network, staging, all
bogus       network     exit 1 — DEPLOY_SCOPE is 'bogus'; expected one of foundation, network, staging, all
bogus       staging     exit 1 — DEPLOY_SCOPE is 'bogus'; expected one of foundation, network, staging, all
bogus       prod        exit 1 — DEPLOY_SCOPE is 'bogus'; expected one of foundation, network, staging, all
```

**Cell for cell identical to the Phase 7 record.** So are its four other
refusal paths, its skip-path `plan-vars.env`, and its console deep link with
CodeBuild's variables faked:

```
$ CODEBUILD_BUILD_ARN=arn:aws:codebuild:us-east-1:590184028094:build/…:abc-123 \
  CODEBUILD_BUILD_ID=bgd-us-east-1-infra-plan-build:abc-123 \
  DEPLOY_SCOPE=foundation ./scripts/pipeline-terraform.sh plan prod
$ grep PLAN_URL plan-vars.env
PLAN_URL=https://us-east-1.console.aws.amazon.com/codesuite/codebuild/590184028094/projects/bgd-us-east-1-infra-plan-build/build/bgd-us-east-1-infra-plan-build%3Aabc-123/\?region=us-east-1
```

### 3.6 The build script, run end-to-end

`scripts/pipeline-app-build.sh`, run locally with `aws` stubbed (this machine
has no session) and `push-image.sh` stubbed (the tree is dirty, and the real
script correctly refuses a `-dirty` tag). Everything else is the real thing —
the two containers, the real suite, the real buildx build, the real syft.

```
$ BGD_ARTIFACT_BUCKET=… BGD_ECR_REPOSITORY_URL=… ./scripts/pipeline-app-build.sh
==> starting DynamoDB Local
  amazon/dynamodb-local@sha256:ff89bd48…
==> running the test suite
  python:3.14.6-slim@sha256:7bec7ddc…
  TOTAL                       542     30     84     18    92%
  Required test coverage of 90.0% reached. Total coverage: 92.01%
  135 passed, 13 deselected in 1.35s
  ✓ tests passed
  ✓ built bgd-us-east-1-api:0.1.0-b946aef-dirty
  digest    sha256:9e870c412fa09df5bff5b49b74306da0986094e37acf9a4c4aacbff400fe6647
==> generating the SBOM with syft
  ✓ SBOM written — 130 packages
==> publishing build outputs
  s3://…/app-builds/0.1.0-b946aef-dirty/sbom.spdx.json
  s3://…/app-builds/0.1.0-b946aef-dirty/coverage.xml
  s3://…/app-builds/0.1.0-b946aef-dirty/junit.xml
  s3://…/app-builds/0.1.0-b946aef-dirty/build-metadata.json
  ✓ build complete
```

**135 passed and 92.01% coverage — the identical numbers `make test` produces
on this machine**, which is the whole of D10's claim: the same suites on the
same interpreter, reached differently.

Both variables were exported and the metadata written:

```
$ cat build-vars.env
IMAGE_TAG=0.1.0-b946aef-dirty
IMAGE_DIGEST=sha256:9e870c412fa09df5bff5b49b74306da0986094e37acf9a4c4aacbff400fe6647

$ cat app/dist/build-metadata.json
{
  "image_tag": "0.1.0-b946aef-dirty",
  "image_digest": "sha256:9e870c…fe6647",
  "git_sha": "b946aefc67ebfcc9c6e14521bc1c96f3fdf5baa1",
  "build_number": "0",
  "build_url": ""
}
```

`build_number: 0` and the `-dirty` suffix are both correct here and both are
the local fallbacks: `CODEBUILD_BUILD_NUMBER` is unset on a laptop, and the
tree has uncommitted work. In the pipeline the number is the project's counter
and the workspace is a clone of a commit, so neither appears — which is Phase
2's stated intent and is what stops a hand-built image being mistaken for a
pipeline one (F5).

The trap cleaned up: no `bgd-dynamodb-*` container and no `bgd-build-*` network
survived the run.

### 3.7 The smoke build genuinely needs no Terraform

D6 claims `scripts/smoke.sh` reads no state when handed both overrides. Run
with `terraform` removed from `PATH` entirely:

```
$ PATH=/usr/bin:/bin command -v terraform
  (absent)

$ BGD_SMOKE_URL=https://127.0.0.1:1 BGD_SMOKE_DIGEST=sha256:deadbeef \
  PATH=/usr/bin:/bin ./scripts/smoke.sh staging
  url     https://127.0.0.1:1
  digest  sha256:deadbeef

  /health    ✗ no response within 10s
  /ready     ✗ no response within 40s
  /version   ✗ no response within 10s
  digest     ✗ no /version response to check

  ✗ 4 smoke check(s) failed against staging
```

It failed on **HTTP**, not on `required command not found: terraform`. That is
the property, demonstrated rather than asserted.

### 3.8 Shell syntax, and the buildspecs

```
$ bash -n scripts/push-image.sh              exit 0
$ bash -n scripts/seed-ecr.sh                exit 0
$ bash -n scripts/pipeline-app-build.sh      exit 0
$ bash -n scripts/pipeline-deploy.sh         exit 0
$ bash -n scripts/pipeline-terraform.sh      exit 0
$ bash -n scripts/lib/common.sh              exit 0
```

`shellcheck` is not installed on this machine, so it was not run. Recorded as
a gap rather than passed over.

All five buildspecs parse, and their `exported-variables` are the lists
`locals.tf` declares:

```
app-build.yml   version=0.2  phases=['build']            exported=['IMAGE_TAG', 'IMAGE_DIGEST']
app-deploy.yml  version=0.2  phases=['build','install']  exported=['SMOKE_URL', 'SMOKE_DIGEST']
app-smoke.yml   version=0.2  phases=['build']            exported=None
app-plan.yml    version=0.2  phases=['build','install']  exported=['PLAN_STATUS','PLAN_SUMMARY','PLAN_URL']
app-apply.yml   version=0.2  phases=['build','install']  exported=None
```

### 3.9 `seed-ecr.sh` behaves as it did before the refactor

Task 4 was a refactor with no behaviour change, so the check is that the
failure is the same failure:

```
$ ./scripts/seed-ecr.sh
  ✗ refusing to push a dirty build (0.1.0-84d4eb0-dirty) — commit the tree and rebuild

$ ./scripts/push-image.sh
  ✗ refusing to push a dirty build (0.1.0-84d4eb0-dirty) — commit the tree and rebuild
```

Same message, same exit code, same point in the sequence — the `-dirty`
refusal precedes the repository-URL resolution in both the original and the
split, which is why neither reaches Terraform or AWS.

### 3.10 Every name fits — F9 confirmed against rendered values

| Resource | Longest name | Length | Limit |
|---|---|---|---|
| CodePipeline | `bgd-us-east-1-app-pipeline` | 26 | 100 |
| CodeBuild project | `bgd-us-east-1-app-deploy-staging-build` | 38 | 255 |
| IAM role | `bgd-us-east-1-app-deploy-staging-role` | 37 | 64 |
| IAM role policy | `bgd-us-east-1-app-deploy-staging-policy` | 39 | 128 |
| Log group | `/bgd/us-east-1/shared/app-deploy-staging` | 40 | 512 |

F9 listed four rows; the fifth — the inline role policies — was not in the plan
and is added here. All nineteen rendered names were extracted from the
configuration rather than retyped.

---

## 4. No AWS resource was created

This machine has no session. `aws sts get-caller-identity` fails, and the
in-scope cells of both scope matrices fail at exactly that point — visible in
§3.1 as `validating provider credentials: … InvalidClientTokenId` and in §3.5
as `cannot read /bgd/<env>/image_tag`.

What that proves and what it does not:

- **It proves** the whole offline gate — 138 test runs, tflint, checkov,
  formatting — passes with no credentials, which is the stated constraint.
- **It proves** the scope gates refuse before reaching AWS, because the skip
  cells exit 0 without a credential error while the in-scope cells produce one.
- **It does not prove** any policy grants enough. A policy that is too narrow
  fails at apply time or, worse, at build time; only the runbook finds that.
- **It does not prove** `MATCHES` is an accepted `VariableCheck` operator. See
  §6.

---

## 5. What remains before the exit criterion is met

The criterion — *a commit under `app/` reaches production through the full
path, with the blue/green deployment and its hooks firing as designed* — needs
a pipeline that exists, a merge that happened and a deployment that ran. This
session created no AWS resource, so **the branch does not meet it** and the
roadmap amendment says so rather than letting a green branch imply a green
pipeline.

[The runbook](../../runbooks/phase-08-app-pipeline.md) meets it at step 6, and
carries four other things this session could not do: the `APP_SCOPE=build` and
`APP_SCOPE=staging` runs (step 7), the direct confirmation that the SSM
parameter is written **after** the apply (step 8), the retirement of Phase 7's
F2, and the confirmation that the infra pipeline's trigger narrowed as intended
(step 5).

---

## 6. Findings discovered during implementation

Numbered from F11, continuing the plan's list, and back-referenced from the
files that act on them.

### F11 — `file_paths.includes` accepts eight patterns, and D14's list has eleven

The largest structural surprise in the phase, and it failed loudly:

```
│ Error: Too many list items
│   with aws_codepipeline.app,
│   on codepipeline-app.tf line 112:
│ Attribute trigger.0.git_configuration.0.push.0.file_paths.0.includes
│ supports 8 item maximum, but config has 11 declared.
```

The provider schema does not express this as a `max_items` on a block — it is
attribute-level validation that runs at plan, which is why `terraform validate`
accepts twelve patterns happily and the test suite rejects eleven.

**The fix is not to drop three patterns.** Every consolidation available
over-matches into the other pipeline's territory: `scripts/pipeline-*.sh` would
match Phase 7's `pipeline-terraform.sh`, and `scripts/**` would match six
local-only helper scripts — both re-creating F4's cross-trigger, in the
opposite direction. Dropping `tf.sh`, `lib/common.sh` or `install-terraform.sh`
would contradict D14's own argument for including them.

`push` accepts **three** filters and the service ORs them, while `branches` and
`file_paths` are ANDed *within* a filter. So the list is split across two push
blocks — six patterns and five — which is exactly equivalent to one list of
eleven, with one trap: **each filter must repeat the branch filter.** A push
block that omits `branches` matches every branch, and this pipeline would then
deploy a feature branch's commit to production. Asserted.

The test asserts the **union** of both filters, so a future re-split is
invisible to it, and separately asserts no filter exceeds eight — which names
the fix when someone adds a twelfth pattern.

### F12 — `ARM_CONTAINER` offers SMALL and LARGE, not MEDIUM

CodeBuild's documented compute matrix gives `ARM_CONTAINER` only
`BUILD_GENERAL1_SMALL` and `BUILD_GENERAL1_LARGE`. Which sizes a region
actually accepts is not in the provider schema and cannot be confirmed offline,
so `var.app_build_compute_type` defaults to `SMALL` — the value that is
certainly valid — with a validation block refusing anything but those two.

`LARGE` is the escalation if the build turns out to be the long pole of a
deployment, and it is one variable away. Choosing a plausible-looking `MEDIUM`
would have failed at apply, in the runbook, on a value nothing offline could
have caught.

### F13 — the smoke role cannot satisfy D6 and D8 in one policy

D6 says the smoke role's policy holds nothing outside `logs:` and `s3:`, and a
test asserts it. D8 says every role whose build clones the repository needs
`codeconnections:UseConnection` — and the smoke build clones, because
`scripts/smoke.sh` is in the repository. Both are right and they collide.

Merging them would have meant **relaxing the D6 assertion** to admit a
`codeconnections:` prefix, and the next thing added under a relaxed assertion is
the "just one read" the assertion exists to refuse. So `app_smoke` has two
policy resources: one holding its log group and the artifact bucket, asserted to
contain nothing else, and one holding the clone grant alone, asserted to contain
exactly `["codeconnections:UseConnection"]` and nothing beside it.

The honest restatement of D6 is therefore: the smoke build reads no account
state and describes no resource. It does make one API call, to clone the
repository it runs from.

### F14 — `seed-ecr.sh`'s `--profile` default would have failed every call in CodeBuild

`seed-ecr.sh` did `PROFILE="${AWS_PROFILE:-bootcamp-administrator-access}"` and
passed `--profile "$PROFILE"` to every `aws` invocation. Correct while it only
ever ran on a laptop; inside CodeBuild `AWS_PROFILE` is unset — deliberately,
per Phase 7 §F6, which made the makefile's export conditional — and there is no
such profile in any config file. Every call would have failed with *The config
profile could not be found*: a credentials-shaped error with a profile-shaped
cause.

`push-image.sh` mirrors the makefile's rule rather than re-deciding it, keying
on `CODEBUILD_BUILD_ID` so local behaviour is byte-identical to before and a
build falls back to its service role. `seed-ecr.sh` keeps the old default for
the two SSM writes it still owns, which only ever run locally.

### F15 — the test container needs two different DynamoDB endpoint variables

The first end-to-end run of `pipeline-app-build.sh` produced **1 failure and 27
errors**, all of which looked like an unreachable database and none of which
was:

- `tests/contract/conftest.py` reads **`BGD_TEST_DYNAMODB_ENDPOINT`**, defaulting
  to `localhost:8000`, and calls `pytest.fail` — not `skip` — when nothing
  answers. Setting only `BGD_DYNAMODB_ENDPOINT_URL` left all 27 contract tests
  pointed at localhost inside the container. Coverage then fell to 76.68% and
  failed the 90% gate for a third, unrelated-looking reason.
- `tests/unit/test_config.py::test_defaults_are_local_development_values`
  constructs `Settings(_env_file=None)` and asserts `dynamodb_endpoint_url is
  None`. A container-wide `BGD_DYNAMODB_ENDPOINT_URL` breaks it.

So `BGD_TEST_DYNAMODB_ENDPOINT` is set container-wide and
`BGD_DYNAMODB_ENDPOINT_URL` is set **only for the `create_tables` invocation**,
which refuses to run without it so that a stray `AWS_PROFILE` cannot point it at
a real account. That is exactly the split
`.github/workflows/pr-validate.yml` already makes, and the finding is really
that it should have been read first.

### F16 — Phase 7's two test files need overrides for this phase's six roles

Both `pipeline_iam.tftest.hcl` and `pipeline_shape.tftest.hcl` use
`command = apply`, which applies the **whole module** — so the five new
CodeBuild projects validate their `service_role` client-side there too, and an
un-overridden mock ARN is an eight-character string:

```
│ Error: "service_role" (4n2l1as6) is an invalid ARN: arn: invalid prefix
│   with aws_codebuild_project.app_image
```

Six `override_resource` blocks were added to each, with a comment saying why
they are in a file that asserts nothing about them. **Phase 9 will need the same
three lines**, and the comment says so, because this is the second time a new
role set has broken an older phase's test file for a reason unrelated to what
that file tests.

---

## 7. Departures from the plan's literal text

Three, all in the direction the plan's own reasoning points.

**The two container digests are read, not copied.** The plan asks for a third
pin at the top of `pipeline-app-build.sh` with a "re-record with" comment, and
in the same breath says "a third pin that can drift from the other two is worse
than no pin". The script reads them from `app/Dockerfile` and
`app/docker-compose.yml` with a targeted `sed`, and dies loudly naming the file
if either shape changes. Drift is removed rather than documented.

**`push-image.sh` writes `app/dist/pushed.env` rather than emitting the tag on
stdout.** The plan says it "writes `TAG` and the pushed digest to stdout in a
form the caller can read". Both callers — `seed-ecr.sh` and
`pipeline-app-build.sh` — need the two values as variables, and a file matches
the `plan-vars.env` / `build-vars.env` shape the phase already uses. It is
written on both the pushed and the already-pushed paths, and sourced rather than
re-derived, so the tag recorded can never disagree with the tag pushed.

**Tasks 2 and 3 landed together.** The plan orders the roles before the projects
because `service_role` interpolates a role ARN — but the roles interpolate their
log group ARNs, and the log groups live in Task 3's file. Task 2's suite was
written and seen to fail first, as the plan requires; it could not go green
until Task 3's file existed.

One addition rather than a departure: **`local.app_deploy_exported_variables`**.
The plan declares locals for the build's and the plan's exported variables but
not the staging deploy's, and `app-deploy.yml` exports `SMOKE_URL` and
`SMOKE_DIGEST` — which the smoke action interpolates, and which are therefore
exactly as rename-fragile as the other five. It is declared and asserted like
them.

---

## 8. Carried forward

### F2 is still open, and is now load-bearing in two pipelines

`MATCHES` cannot be confirmed as a `VariableCheck` operator offline: the rule's
`configuration` is an untyped `map(string)`, so the provider validates nothing
and the service decides at execution time. The staging condition uses it; `prod`
uses `EQ`, which is certainly supported.

**What makes being wrong cheap is §3.1's matrix.** `pipeline-deploy.sh` re-reads
`APP_SCOPE` and refuses an out-of-scope environment itself, so a condition wrong
in the direction of *entering* a stage costs an unwanted approval, not an
unwanted production deployment. Runbook step 7 closes it for both pipelines at
once, and the fallback if it is unsupported is the ordinal-and-`LTE` change both
plans name.

### What Phase 9 inherits

- **Two pipelines emitting execution state changes, and neither notifying
  anyone.** D17: notification is Phase 9's alone, and adding an SNS action here
  would have put it in two places to reconcile. `app_pipeline_name` and
  `app_pipeline_arn` are outputs for the EventBridge rule to filter on.
- **`app-builds/<tag>/`**, holding an SBOM, a coverage report, a JUnit report
  and `build-metadata.json` per build, kept indefinitely. The metadata file
  carries the tag, digest, git SHA, build number and build URL — which is what a
  lead-time metric needs.
- **A third role set is coming**, and F16 says what it will break.
- **Python 3.14 is not a Lambda runtime**, which F3 noted in passing and Phase 9
  meets directly: the metrics Lambda cannot assume the interpreter this project
  pins everywhere else.

### What Phase 11 inherits

`APP_SCOPE=build` builds, tests, SBOMs and pushes a deliberately broken image
**without deploying it** — built now rather than improvised then, so the
rollback demonstration can be started by hand at the moment the screenshots are
being taken.

### One thing worth revisiting with real data

`var.app_build_compute_type` is `BUILD_GENERAL1_SMALL` — 2 vCPU and 3 GB for a
run that starts two containers, installs the dev locks, runs 135 tests, and then
does a `--no-cache` buildx build, a syft scan and a skopeo copy. It should work;
whether it is the *right* size is a question only a real build time answers.
Runbook step 6a is where that number first exists. Raising it to `LARGE` is a
one-variable change and F12 explains why there is nothing between the two.
