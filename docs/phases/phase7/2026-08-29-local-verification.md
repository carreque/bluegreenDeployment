# Phase 7 — local verification record

**Date:** 2026-08-29 to 2026-08-30
**Branch:** `feat/Phase7_InfraPipeline`
**AWS resources created:** **none.** See §4.

What this branch actually proves, and what it does not. The plan's D1 split
this phase in two: everything here was written and verified with no AWS
session, and everything that needs one is
[the runbook](../../runbooks/phase-07-infra-pipeline.md).

**Neither of the phase's two exit criteria is met by this branch.** Both need a
pipeline that exists and a run that happened. §5 enumerates exactly what
remains.

---

## 1. The gate

Run on a machine that has never run `aws sso login`. `scripts/tf.sh`
initialises with `-backend=false` for `validate` and `test`, and tflint and
checkov read files, so the whole gate is offline.

```
$ make tf-check

==> terraform validate — bootstrap    Success! The configuration is valid.
==> terraform validate — foundation   Success! The configuration is valid.
==> terraform validate — network      Success! The configuration is valid.
==> terraform validate — staging      Success! The configuration is valid.
==> terraform validate — prod         Success! The configuration is valid.

==> tflint — bootstrap    ✓ bootstrap clean
==> tflint — foundation   ✓ foundation clean
==> tflint — network      ✓ network clean
==> tflint — staging      ✓ staging clean
==> tflint — prod         ✓ prod clean

==> checkov — infra/
    Passed checks: 378, Failed checks: 0, Skipped checks: 82
  ✓ checkov clean
  ✓ static analysis passed

  bootstrap    Success!  5 passed, 0 failed.
  foundation   Success! 35 passed, 0 failed.
  network      Success! 17 passed, 0 failed.
  staging      Success! 16 passed, 0 failed.
  prod         Success! 35 passed, 0 failed.

  all infra checks passed
```

108 run blocks across five layers. `foundation` went from 14 to 35 — the 21
new ones are this phase, split across two files.

```
$ make tf-fmt-check
$                                    # silent; exit 0
```

### The 21 new runs

`tests/pipeline_iam.tftest.hcl` — five runs, the boundary D6 argues for:

```
plan_and_apply_are_different_roles_with_different_reach
every_pipeline_role_trusts_the_right_service_and_only_this_account
the_plan_role_can_lock_state_but_cannot_write_it
the_validate_role_makes_no_aws_call_at_all
the_pipeline_role_names_everything_it_may_touch
```

`tests/pipeline_shape.tftest.hcl` — sixteen runs (the ordering, the projects,
the pipeline, the lifecycle rule and the outputs):

```
the_layer_list_is_in_dependency_order_not_lexical_order
every_environment_layer_has_an_image_tag_parameter
only_the_validate_project_runs_containers
every_project_is_x86_because_the_lint_digests_are
each_project_runs_its_own_buildspec_under_its_own_role
the_build_log_groups_have_retention
the_stages_are_source_validate_then_the_four_layers_in_order
every_layer_stage_plans_then_approves_then_applies
apply_consumes_the_plan_action_output_and_never_replans
only_the_three_later_stages_are_scope_gated
the_trigger_filters_the_paths_the_pipeline_actually_owns
deploy_scope_is_an_execution_variable_defaulting_to_all
the_approval_shows_the_plan_it_is_approving
the_buildspec_still_exports_what_the_approval_interpolates
pipeline_artifacts_expire_and_the_existing_rule_does_not_cover_them
the_outputs_phase_8_and_9_consume_are_present
```

### What each group of assertions protects against

**Stage order and layer order.** `local.pipeline_layers` is a *list*, and the
first assertion is why. Terraform iterates a map in lexical key order, which
for these four names is foundation, network, **prod, staging** — so a map would
build a pipeline that applies production before staging. Nothing about the
resulting configuration looks wrong; the stages are all present, in an order
that is only visibly incorrect if you happen to read all six names.

**The artifact hand-off.** `Apply`'s `input_artifacts` must equal `Plan`'s
`output_artifacts`, in every one of the four layer stages. If they diverge, the
Apply action has no saved plan, computes a new one, and applies something
nobody approved — with no error at any point (D9). It is two strings in two
different blocks that have to match, which is precisely what a plan review does
not catch.

**Which project each action points at.** An `Apply` action pointed at the plan
project runs `pipeline-terraform.sh plan`, applies nothing, and reports
success.

**The service role, not the action role.** `aws_codebuild_project.infra_plan`
must carry `aws_iam_role.infra_plan.arn`. Crossing plan and apply gives the
plan build `AdministratorAccess`, which is the entire property F3 and D5 exist
to secure, and nothing else in the configuration would show it.

**What the validate role may do.** Every action in its policy must start with
`logs:` or `s3:`. This is the one that erodes: someone adds a step needing
"just one read", grants it, and the claim in D6 that the validate stage cannot
see the account becomes quietly false. A new prefix here fails the suite.

**The state lock grant, asserted both ways.** Once that
`arn:aws:s3:::…-tfstate-…/*.tflock` is present, and once that
`arn:aws:s3:::…-tfstate-…/*` is *not*. The second is the one that matters: a
grant broadened to the bucket prefix would still satisfy the first.

**The trigger's path filter.** Invisible until the wrong commit starts a run.
`scripts/**` would cross-trigger a four-approval infra deployment on every
application change; `infra/**` alone would ignore edits to the pipeline's own
logic (D12).

**`DetectChanges = "false"`.** The failure mode is a second, unfiltered webhook
that fires on every push while the `trigger` block sits beside it looking as
though it were working — and `terraform plan` stays clean forever (D13).

**The approval interpolation.** `CustomData` must contain `.PLAN_SUMMARY}`, and
`pipelines/infra-plan.yml` must still export every name in
`local.plan_exported_variables`. A renamed exported variable fails nothing: the
approval message simply displays the literal `#{PlanProd.PLAN_SUMMARY}`. This
pair of assertions is the only thing that notices.

**The lifecycle rule's prefix.** Scoped to `bgd-us-east-1-infra-pipeline/`. An
unscoped expiration would delete the SBOMs and test reports the bucket exists
to keep (design §4.2).

### Three assertions were mutation-tested rather than trusted

The test harness changed substantially during Task 3 (below), so the three
assertions that carry the most weight were checked by breaking the code and
confirming the suite noticed:

| Mutation | Result |
|---|---|
| `infra_plan` project given the apply role's ARN | `each_project_runs_its_own_buildspec_under_its_own_role` fails |
| `StateLockOnly` broadened from `/*.tflock` to `/*` | `the_plan_role_can_lock_state_but_cannot_write_it` fails, on both assertions |
| `RunTheBuilds` resource replaced with `["*"]` | `the_pipeline_role_names_everything_it_may_touch` fails |

All three were reverted; the suite returned to 35 passed.

### Three departures from the plan's literal text, all in the tests

The plan's task snippets were written before any of them ran. Three did not
work as written, and the fixes are recorded here rather than left as silent
edits.

**1. A trailing `&&` does not continue a line in HCL.** Three assertions were
written as

```hcl
condition = one(a).buildspec == "x" &&
one(b).buildspec == "y"
```

which fails to parse: a newline terminates an expression in HCL native syntax
unless it is inside brackets or parentheses. The error is `Invalid expression`
on the continuation line and `Missing required argument` on the enclosing
`assert` block, which points at the wrong thing. Fixed by wrapping each in
parentheses. No assertion changed meaning.

**2. `mock_provider "aws" {}` alone cannot assert on a rendered policy.** Every
IAM policy in this phase interpolates a computed ARN — a log group's, the
artifact bucket's, the connection's, a build project's. Under `command = plan`
those are unknown, one unknown input makes the whole `jsonencode` unknown, and
the condition fails with `Unknown condition value` rather than false.

Adding `mock_resource` defaults was tried first and **does not fix it**:
measured, and defaults do not resolve computed attributes at plan time. The
working answer is the one `infra/network/tests/routing.tftest.hcl` already
records for the same problem — `command = apply` against the mocked provider,
which creates nothing and needs no credentials but does resolve the values.

Apply mode on `foundation` then needed two mocks, each added because omitting
it produced a hard error:

| Mock | Error without it |
|---|---|
| `aws_acm_certificate.domain_validation_options` | mocks to an empty set; `acm.tf`'s `one([...])` over it yields `null` for a required argument of the validation records |
| `aws_sns_topic.arn` | `aws_sns_topic_subscription` validates `topic_arn` client-side, and a random eight-character string is not an ARN |

and four `override_resource` blocks, one per IAM role.
`aws_codebuild_project` validates `service_role` client-side for the same
reason, so the roles need real-looking ARNs — but a single `mock_resource`
default would give all four the *same* ARN, and "the plan project runs as the
plan role" would then hold even with the plan and apply roles crossed. Prod's
`bluegreen.tftest.hcl` reached the same conclusion for the same reason. The
three build projects are deliberately left unmocked: their distinct generated
ARNs are what make the `RunTheBuilds` assertion notice a missing one.

**3. `privileged_mode` is null, not false, when unset.** It is optional with no
schema default, so the plan's `!one(...).privileged_mode` raises `argument must
not be null` rather than passing. Wrapped in `coalesce(…, false)`.

---

## 2. Static analysis triage

Fourteen findings across seven check IDs, all on this phase's new resources. To
get the real list rather than the post-skip one, `infra/` was copied to a
scratch directory, every `checkov:skip` comment added by this phase was
stripped, and checkov 3.3.13 was run against the copy.

| Check | Resources | Response |
|---|---|---|
| `CKV_AWS_316` privileged mode enabled | `aws_codebuild_project.infra_validate` | **Skip.** Docker-in-docker is how `scripts/lint-infra.sh` runs its digest-pinned tflint and checkov containers — the identical command used locally, installing nothing on the host. Removing it means installing both tools into the build image at floating versions, which is the drift the pins exist to prevent. Plan and apply do not get it. |
| `CKV_AWS_274` `AdministratorAccess` | `aws_iam_role_policy_attachment.infra_apply_admin` | **Skip**, with D6's argument attached in full: this role creates IAM roles in four layers, and a principal that can create a role and attach a policy can already grant itself anything. The real control is the manual approval on a saved plan. |
| `CKV_AWS_147` CodeBuild not encrypted with a CMK | all three projects | **Skip.** SSE-S3 and AWS-owned keys throughout, decided once in the Phase 3 plan §D4 and applied to every encrypted-at-rest resource in this project. |
| `CKV_AWS_158` log group not encrypted by KMS | all three log groups | **Skip.** Same Phase 3 §D4 decision. These groups hold `terraform plan` output, tflint and checkov findings and plan summaries — all derived from the commit, none of it a credential or a customer record. |
| `CKV_AWS_338` log group retains < 1 year | all three log groups | **Skip.** Thirty days is what `var.pipeline_log_retention_days` says and it is deliberate: a pipeline log is worth keeping until the deployment it describes is understood, and retention is the entirety of what a log group costs. Same reasoning as network's flow logs and both ECS log groups. |
| `CKV_AWS_219` CodePipeline artifact store not using a KMS CMK | `aws_codepipeline.infra` | **Skip.** Same Phase 3 §D4 decision, applied to the bucket this pipeline stores into. The artifacts are a source zip of a public repository and four Terraform plans of infrastructure whose configuration is in that repository. |
| `CKV2_AWS_34` SSM parameter should be encrypted | both `image_tag` parameters | **Skip.** The value is a container image tag printed in every build log, every task definition and every `/version` response. Encrypting it would imply it is a secret, and both readers would need a KMS grant to read a tag. |

`Skipped checks` stands at 82 across the whole of `infra/`, of which these 14
are this phase's. Every skip carries the trade-off in the comment; none is
bare.

### Where F9's prediction was wrong

F9 predicted five responses. Three were right, and the three ways it was wrong
are worth stating plainly.

**It missed two checks entirely.** `CKV_AWS_158` (log group KMS) and
`CKV_AWS_219` (CodePipeline artifact store CMK) were not predicted. Both follow
the same Phase 3 §D4 decision the ones it did predict follow, so the responses
were not in doubt — but the prediction was assembled from the resource types
this phase adds, and it did not project a decision already taken three times
onto two more resource types that carry it.

**It predicted a fix where the answer is a skip.** F9 said `CKV_AWS_338` —
"log group without retention" — would be **fixed** by giving the three groups
`var.pipeline_log_retention_days`. They do have it, and the check still fires,
because it does not ask for retention: it asks for **at least a year**. The fix
was made *and* the skip is still required. The prediction described the check
by its resource rather than by its threshold.

**It named the wrong identifier for the SSM finding.** F9 predicted
`CKV_AWS_337`. checkov 3.3.13 raises `CKV2_AWS_34` and never raises
`CKV_AWS_337` against these resources. A skip for the predicted ID was written
first, and then **removed**: an inert skip for a check this checkov version does
not raise is a comment that describes a suppression which is not happening, and
the next reader has no way to tell it apart from a live one.

### One tflint finding

```
foundation/locals.tf:60:3: Warning - local.plan_exported_variables is declared
  but not used (terraform_unused_declarations)
```

Correct as far as tflint can see, and wrong about the code. The only consumer
is `tests/pipeline_shape.tftest.hcl`, which tflint does not read — and that is
the declaration doing its job rather than a leftover: the whole point is to keep
the three exported-variable names in one place a test can compare the buildspec
against. Suppressed with an inline
`# tflint-ignore: terraform_unused_declarations` and that reason written above
it.

---

## 3. The executed evidence

Everything below was run, not reasoned about.

### The scope gate — D4's second gate actually refuses

The whole of D3's table, executed. `plan` mode, every scope against every
layer:

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

Read it against D3's table: the ten cells below the diagonal exit 0 having
skipped, and the six on or above it reach Terraform or the SSM lookup and fail
for want of an AWS session — which is expected on this machine and is not what
this is testing. `bogus` refuses all four rather than ranking as a silent
`foundation`.

**This is the finding that matters most in this phase.** It is what makes being
wrong about `MATCHES` (F2) cost an unwanted approval rather than an unwanted
production apply.

The other refusal paths:

```
$ DEPLOY_SCOPE=all ./scripts/pipeline-terraform.sh plan bogus
  ✗ unknown layer: bogus (expected foundation, network, staging or prod)

$ ./scripts/pipeline-terraform.sh plan prod
  ✗ DEPLOY_SCOPE is unset — the pipeline action must pass it as an EnvironmentVariables override

$ DEPLOY_SCOPE=all ./scripts/pipeline-terraform.sh destroy foundation
  ✗ unknown mode: destroy (expected plan or apply)
```

### The ordering constraint the plan's §2 names, demonstrated

An out-of-scope **apply** must report a skip rather than dying on a plan file
the skipped plan never wrote — which is only true because the scope check runs
before the saved-plan check:

```
$ DEPLOY_SCOPE=foundation ./scripts/pipeline-terraform.sh apply prod
==> prod is outside DEPLOY_SCOPE=foundation — nothing to do          # exit 0

$ DEPLOY_SCOPE=all ./scripts/pipeline-terraform.sh apply foundation
  ✗ no saved plan at infra/foundation/pipeline.tfplan — the Plan action in this stage must run first
```

The first would be a red stage on a correct skip if the two checks were the
other way round.

### The variables file, written and sourced back

```
$ DEPLOY_SCOPE=foundation ./scripts/pipeline-terraform.sh plan prod >/dev/null
$ cat plan-vars.env
PLAN_STATUS=skipped
PLAN_SUMMARY=Skipped.\ prod\ is\ outside\ DEPLOY_SCOPE=foundation.
PLAN_URL=''

$ set -a && . ./plan-vars.env && set +a
PLAN_STATUS=[skipped]
PLAN_SUMMARY=[Skipped. prod is outside DEPLOY_SCOPE=foundation.]
PLAN_URL=[]
```

The `%q` quoting is what makes `set -a && . ./plan-vars.env` safe for a summary
containing spaces — the round trip above is the proof, not the intention. The
file was removed afterwards and is in `.gitignore`.

The console deep link, with CodeBuild's variables faked:

```
$ CODEBUILD_BUILD_ARN=arn:aws:codebuild:us-east-1:590184028094:build/…:abc-123 \
  CODEBUILD_BUILD_ID=bgd-us-east-1-infra-plan-build:abc-123 \
  DEPLOY_SCOPE=foundation ./scripts/pipeline-terraform.sh plan prod
$ grep PLAN_URL plan-vars.env
PLAN_URL=https://us-east-1.console.aws.amazon.com/codesuite/codebuild/590184028094/projects/bgd-us-east-1-infra-plan-build/build/bgd-us-east-1-infra-plan-build%3Aabc-123/\?region=us-east-1
```

### Shell syntax and the Terraform checksum

```
$ bash -n scripts/install-terraform.sh      # exit 0
$ bash -n scripts/pipeline-terraform.sh     # exit 0
$ bash -n scripts/seed-ecr.sh               # exit 0
```

The pinned checksum was confirmed against the source rather than transcribed:

```
$ curl -sS https://releases.hashicorp.com/terraform/1.15.7/terraform_1.15.7_SHA256SUMS | grep linux_amd64
73bbb8f5188ad75d4fb853fd100ae4d7e146ef7af7db18776109642fdb7759d2  terraform_1.15.7_linux_amd64.zip
```

which is the value in `scripts/install-terraform.sh`. `linux_amd64` because all
three infra projects are `LINUX_CONTAINER` (D7).

### The three buildspecs parse

The plan called for the system `python3` deliberately, to avoid making the
infra gate depend on `app/.venv`. **The system interpreter has no PyYAML** —
neither `/usr/bin/python3` nor Homebrew's. Ruby's stdlib parser is present on
macOS and keeps the intent, and the project virtualenv was used as a second
opinion:

```
$ ruby -ryaml -e 'ARGV.each { |f| YAML.safe_load(File.read(f)) }' pipelines/infra-*.yml
ok (ruby/psych)

$ app/.venv/bin/python -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]" pipelines/infra-*.yml
ok (pyyaml 6.0.3)
```

and the parsed structure of the one that carries the most:

```
infra-plan.yml keys: ["version", "env", "phases", "artifacts"]
  env:       {"exported-variables" => ["PLAN_STATUS", "PLAN_SUMMARY", "PLAN_URL"]}
  artifacts: {"files" => ["**/*"], "exclude-paths" => ["**/.terraform/**"]}
```

### `AWS_PROFILE` is not exported inside CodeBuild — F6

```
$ CODEBUILD_BUILD_ID=fake:1 make -p 2>/dev/null | grep -c '^AWS_PROFILE'
0
$ make -p 2>/dev/null | grep -c '^AWS_PROFILE'
1
```

`0` then `1`. Phase 3's `:=` reasoning is preserved exactly for a local shell —
an inherited `AWS_PROFILE` still cannot redirect an apply — and the trap is
removed for the one environment where a profile name is meaningless.

`make help` still lists `tf-fmt-check` under **Available now** with its
description, and the Planned list is unchanged.

### One correction to the plan, in `seed-ecr.sh`

The plan places the SSM write "after the digest assertion and before the
closing `ok`/`dim` lines". Written there, it never runs on the path that
matters: `seed-ecr.sh` exits early when the tag is already in ECR with the
digest we hold — and once Phases 5 and 6 have run, **that is the common path**.
Both parameters would have stayed at `unset` on exactly the machines where the
image was pushed before Phase 7 existed, which is the one case the infra
pipeline cannot plan through and the case the runbook's precondition is meant
to close.

The write is therefore a function, `record_image_tag_parameters`, called on
both exit paths.

---

## 4. No AWS resource was created

The same statement Phases 3 to 6 each carry, with the same evidence.

- **No `aws` command that mutates anything was run.** The only `aws` invocations
  in this session were inside `scripts/pipeline-terraform.sh`, reaching
  `ssm get-parameter`, and every one of them failed for want of a session —
  visible in §3's matrix as `cannot read /bgd/<env>/image_tag`. Read calls that
  never authenticated.
- **`terraform plan` was never run against a backend.** `make tf-check` runs
  `validate` and `test`, both of which `scripts/tf.sh` initialises with
  `-backend=false`. `terraform test` executed `command = apply` run blocks
  against `mock_provider "aws"`, which creates nothing and makes no API call —
  the same mechanism `infra/network`'s suite has used since Phase 4.
- **The in-scope cells of the scope matrix fail before reaching AWS.**
  `terraform plan failed for foundation (exit 1)` is `terraform init` unable to
  reach the S3 backend, on a machine with no credentials.
- **No `terraform apply`, no `make apply-*`, no `make seed-ecr`.**

The only network access in the session was `curl` to
`releases.hashicorp.com` to confirm the Terraform checksum, and `docker pull`
of the two digest-pinned lint images `make tf-lint` already uses.

---

## 5. What remains before the exit criteria are met

Both criteria need a pipeline that exists and a run that happened. The full
procedure is [the runbook](../../runbooks/phase-07-infra-pipeline.md); this is
the summary of what it does.

| Step | What it does | Why it cannot be done here |
|---|---|---|
| 1 | Confirm the CodeConnections link is `AVAILABLE`, and that both `/bgd/<env>/image_tag` parameters hold a real tag | Needs the account. The link is authorised by a console click; the parameters do not exist until step 4 has run |
| 2 | `aws sso login`, `make verify-aws` | — |
| 3 | Re-run `make tf-check` with credentials present | Confirms nothing in the gate depended on being offline |
| 4 | `make plan-foundation`, read it, `make apply-foundation` | **The handover.** 14 resources created, 1 changed. The last apply of this layer that has to be local |
| 5 | `get-pipeline-state` — six stages in order; confirm `V2`, `QUEUED`, the variable and the trigger | The V2 attributes are rejected at apply, not at plan |
| 6 | **Exit criterion 1.** Merge a trivial change under `infra/environments/staging/`, follow the run through four approvals, record the Staging approval message verbatim | Needs a merge and a running pipeline |
| 7 | **Exit criterion 2.** `start-pipeline-execution --variables name=DEPLOY_SCOPE,value=network`, then prove it three ways: Staging and Prod report `Skipped`, the execution status is `Succeeded` not `Failed`, and prod's ECS task definition revision is unchanged | Needs a running pipeline and a running production service |
| 8 | Read the approval message and the plan link — a real summary, not a literal `#{PlanStaging.PLAN_SUMMARY}` | The offline test covers the export side; only a run covers the interpolation side |
| 9 | The repair procedure, described rather than demonstrated | Nothing is deliberately broken to practise it |

---

## 6. Carried forward

### F2 — `MATCHES` is unconfirmed, and runbook step 7 closes it

`stage.before_entry.condition.rule.configuration` is an untyped `map(string)`.
The provider validates nothing inside it and the service validates it at
execution time, so the schema proves a rule can be attached and proves nothing
about whether `Operator = "MATCHES"` is accepted, or whether `Variable` takes
`#{variables.DEPLOY_SCOPE}` rather than a bare name.

Three of the four stages need an operator; `Prod` uses `EQ`, which is the one a
`VariableCheck` certainly has. `Network` and `Staging` use `MATCHES` with a
regex, because a condition's rules are ANDed and `network` runs under three of
the four scopes — there is no arrangement of `EQ` and `NE` that expresses an OR
of two values in one condition.

**This may be wrong, and the honest position is that it is unconfirmed rather
than likely.** What makes being wrong cheap is §3's matrix: the plan build
re-reads `DEPLOY_SCOPE` and refuses an out-of-scope layer itself, so a condition
that wrongly *enters* a stage costs an approval nobody wanted, not a production
apply.

Runbook step 7 settles it, and asks for the answer to be recorded either way —
because "it worked" and "it worked for the reason we thought" are different
findings, and only the second one retires F2.

The fallback, if `MATCHES` is rejected: change `DEPLOY_SCOPE`'s accepted values
to the ordinals `1`, `2`, `3`, `4` and every rule to `LTE <n>`. It is worse to
read and it is a Terraform-only change — `scripts/pipeline-terraform.sh`
already ranks the scope numerically, so only `local.pipeline_layers`'
`scope_operator`/`scope_value` pairs and the script's two `case` blocks move.

### One thing worth revisiting with real data

**`execution_mode = "QUEUED"` and four approvals per run.** D10 accepted that a
`DEPLOY_SCOPE=all` run where only `prod` changed still asks for four approvals,
three of them on empty plans, and made the empty case unmistakable instead —
the summary is the literal `No changes. <layer> is up to date.` and nothing
else.

That is the right trade at one merge a day. It may not be at ten: three
reflexive clicks before the one that matters is exactly the habit an approval
gate exists to prevent, and a queue of runs each needing four clicks is a queue
that grows. The alternative D10 rejected — a second `before_entry` condition
per stage reading an exported `HAS_CHANGES` — is rejected on the strength of
F2, and becomes cheap the moment F2 is settled. Worth reconsidering after
Phase 9 has a deployment-frequency number to look at.

### What Phase 8 inherits

D8 makes the SSM parameters the whole handoff. The app pipeline pushes an image
and writes `/bgd/<env>/image_tag`; nothing about the infra pipeline needs to
know it happened, and `ignore_changes = [value]` is what stops the next
`foundation` apply reverting it. `scripts/seed-ecr.sh` already demonstrates the
exact call. Recorded here so Phase 8 inherits it as a requirement rather than
discovering it.
