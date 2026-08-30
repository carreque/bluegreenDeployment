# Phase 9 — local verification record

**Date:** 2026-08-30
**Branch:** `feat/Phase9_Observability`
**AWS resources created:** none. **AWS API calls made:** none — every command
below runs against `mock_provider "aws"` or the local interpreter, with no
`aws sso login` on this machine.

Everything below was executed. Where a command's output is quoted, it is the
output, not a description of it.

**Companion documents:**
[plan](./2026-08-30-phase-09-implementation-plan.md) ·
[runbook](../../runbooks/phase-09-observability.md) ·
[Phase 8 verification record](../phase8/2026-08-30-local-verification.md)

---

## 1. The gate

```
$ make tf-check          # on a machine that has never run `aws sso login`

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
Passed checks: 488, Failed checks: 0, Skipped checks: 110
  ✓ checkov clean

==> terraform test — bootstrap    Success! 5 passed, 0 failed.
==> terraform test — foundation   Success! 75 passed, 0 failed.
==> terraform test — network      Success! 17 passed, 0 failed.
==> terraform test — staging      Success! 16 passed, 0 failed.
==> terraform test — prod         Success! 35 passed, 0 failed.

  all infra checks passed
```

148 test runs across five layers, all green. Foundation carries the whole of
this phase's Terraform: **65 → 75**, ten new runs across two new files —
`observability.tftest.hcl` (7 `run` blocks) and `dashboard.tftest.hcl` (3
`run` blocks, the suite that covers the widget rendered wrong by the
`flatten()` bug in §3.6) — on top of four pre-existing suites
(`pipeline_iam.tftest.hcl`, `pipeline_shape.tftest.hcl`,
`app_pipeline_iam.tftest.hcl`, `app_pipeline_shape.tftest.hcl`) that each
gained one `override_resource` block (§3.2) with no new `run` block of their
own; `pipeline_shape.tftest.hcl` also gained the `lambdas/**` pattern inside
an *existing* run's assertion rather than a new run. Network, staging and
bootstrap are untouched by this phase and their counts (17, 16, 5) match
Phase 8's record exactly. Prod stays at **35** — Task 8 inverted an existing
assertion rather than adding a run.

```
$ make test-lambdas

.....................................                                    [100%]
================================ tests coverage ================================
_______________ coverage: platform darwin, python 3.14.6-final-0 _______________

Name                         Stmts   Miss Branch BrPart  Cover   Missing
------------------------------------------------------------------------
lifecycle_hook/handler.py       49      0      6      0   100%
release_metrics/handler.py     132      3     34      3    96%   73, 83, 137, 281->280
------------------------------------------------------------------------
TOTAL                          181      3     40      3    97%
Required test coverage of 95.0% reached. Total coverage: 97.29%
37 passed in 0.19s
```

37 handler tests (up from `lifecycle_hook`'s original count as `release_metrics`
went from zero tests to 28), at 97.29% against a 95% gate — cleared one task
earlier than the plan predicted (Task 3, not Task 4), because the two
pipeline-execution paths carry more lines than the MTTR path turned out to
need. The three uncovered statement lines (73, 83, 137) and one partial branch
(281→280) are all in unexercised failure-string edge cases inside functions
whose success and primary-failure paths are both covered.

```
$ make lint

All checks passed!
45 files already formatted
All checks passed!
5 files already formatted
```

`terraform fmt -check -recursive infra` — run separately for this task, since
the only `.tf` edit in Task 12 is a comment — also exits 0:

```
$ terraform fmt -check -recursive infra
$ echo $?
0
```

These four command outputs were captured directly during this task's own
verification pass; they are cell-for-cell identical to Task 10's re-verified
gate (`.superpowers/sdd/2026-08-30-phase-09-implementation-plan/task-10-report.md`),
confirming that Task 11's runbook (documentation only) and this task's
documentation and one-comment edit changed nothing the gate measures.

---

## 2. Static analysis triage

checkov: **488 passed, 0 failed, 110 skipped.** tflint: clean on all five
layers. Every check this phase introduced either holds for a stated reason or
turned out, on investigation, to be inert (§3.4).

The module's six pre-existing checkov skips were re-examined for the first
Lambda in this project invoked **asynchronously** rather than synchronously
(plan D11):

| Check | Still holds for the collector? |
|---|---|
| `CKV_AWS_50` (X-Ray) | Yes — four boto3 calls, each already logged with its outcome |
| `CKV_AWS_116` (DLQ) | **No, rewritten.** Written for hooks ECS invokes synchronously and itself consumes the result of; the collector is invoked asynchronously by EventBridge, so a dropped invocation is real. Still no DLQ — nothing in this project polls a queue, and the substitute control is the collector's own `Errors` alarm plus a bounded `retry_policy` |
| `CKV_AWS_115` (reserved concurrency) | Yes — bounded by how rarely deployments and pipeline executions happen |
| `CKV_AWS_117` (VPC) | Yes — CloudWatch, SNS and CodePipeline are public API endpoints |
| `CKV_AWS_173` (env encryption) | Yes — namespace, topic ARN, two pipeline names, all public facts |
| `CKV_AWS_272` (code signing) | Yes — zip built by `archive_file` in the same apply |

Two new skips appear in `infra/foundation/observability.tf`, both
`CKV_AWS_355` on the collector's IAM policy statements — and both are the
subject of §3.4 below, which found them **inert**.

---

## 3. The executed evidence

### 3.1 A defect in the plan itself, caught mid-flight

The plan's own rollback matcher, as written in its Task 2 brief, was
`"rollback" in reason.lower()`. The plan's own test for that brief passed
`reason="rolling back to revision 4"` — a string that substring does not
match. **The brief could not pass its own test.**

The first implementer's fix widened the match to the bare substring `"back"`,
which is worse, not better: `"backend unhealthy"`, `"exponential backoff"` and
`"fallback target"` all contain `"back"`, so an ordinary failure phrased any
of those ways would have been filed as a rollback and silently removed from
the change-failure-rate numerator — the exact quantity plan D8 exists to
protect. `lambdas/tests/test_release_metrics.py`'s six-test run at that point
was green and wrong.

Resolved with three explicit phrases and `any()`:

```python
ROLLBACK_REASON_PHRASES = ("rollback", "rolling back", "rolled back")
...
if "ROLLBACK" in event_name or any(p in lowered_reason for p in ROLLBACK_REASON_PHRASES):
```

plus a regression test,
`test_an_ordinary_failure_whose_reason_merely_contains_back_is_not_a_rollback`,
asserting `reason="backend unhealthy, backoff limit"` is filed as
`DeploymentFailed`, never `DeploymentRolledBack` — a test that fails under the
rejected bare-`"back"` matcher, verified by the reviewer running it in
isolation against that matcher before accepting the fix.

**The preflight conflict scan run before this plan's execution began missed
this.** It checked that Task 2's rollback-before-failed *ordering* matched the
test asserting it, and recorded the pair "clean" — it never checked whether
the matcher's *substring* actually matched the string the plan's own test
handed it. Recorded here because that scan's table said clean and it was not.
Cost, had it gone unnoticed: a rollback phrased a fourth way is filed as a
plain failure — visible as a `DeploymentFailed` with no `DeploymentRolledBack`
beside it on the dashboard, and a one-line fix. That is the safe direction —
under-reporting rollbacks rather than over-reporting them — but it was luck,
not design, that the direction came out safe.

### 3.2 F15 — the first Lambda in a layer breaks every `command = apply` suite in it

Adding `module.release_metrics` to `foundation` broke four **pre-existing**
test suites at once — `pipeline_iam.tftest.hcl`, `pipeline_shape.tftest.hcl`,
`app_pipeline_iam.tftest.hcl`, `app_pipeline_shape.tftest.hcl` — none of which
have anything to do with observability:

```
Error: "role" (uklsg5sl) is an invalid ARN: arn: invalid prefix
  with module.release_metrics.aws_lambda_function.this,
  on ../modules/lambda/main.tf line 138, in resource "aws_lambda_function" "this":
 138:   role          = aws_iam_role.this.arn
```

Cause: `mock_provider "aws"` fills an un-overridden computed attribute with a
random 8-character string, and `aws_lambda_function` validates `role`
client-side as an ARN shape. Every one of those four files uses
`command = apply`, which applies the **whole root module**, so the first
Lambda declared in a layer breaks every apply-command suite in it
simultaneously, regardless of what that suite is actually testing.

Fixed additively — one `override_resource` block per file, pinning
`module.release_metrics.aws_iam_role.this`'s ARN to
`arn:aws:iam::590184028094:role/bgd-us-east-1-release-metrics-exec-role` — the
same nine-line shape those same four files already carry **ten times each**
for `aws_codebuild_project.service_role`, for the identical reason.
`pipeline_iam.tftest.hcl`'s own Phase-8-era comment had predicted this exactly
("a Phase 9 role set will need the same three lines"). Confirmed by `git log`:
Phase 8 made the identical edit to two of these same files when it added the
app pipeline's roles.

The reviewer verified the whole four-file collateral diff was **purely
additive** — every hunk is `+` lines only, with the diff's small number of
deletions confined entirely to a module comment rewrite elsewhere — so no
existing assertion was weakened to reach green.

### 3.3 F14 handled first, so the deliberate F9 failure landed cleanly

Plan finding F14, recorded before implementation began: the `override_data`
for `data.terraform_remote_state.foundation`, repeated verbatim across all six
files in `infra/environments/prod/tests/` (there is no shared-setup construct
for `mock_provider`), supplies five foundation outputs and **does not include
`alerts_topic_arn`**. Left alone, the moment `alarms.tf` referenced
`local.foundation.alerts_topic_arn` all six files would fail with *"This
object does not have an attribute named alerts_topic_arn"* — before any
assertion ran, in five files with nothing to do with alarms — and that failure
would have been indistinguishable from the deliberate one plan finding F9
predicts (Phase 6's test asserting the bake alarms carry **no** `alarm_actions`
now needing to be inverted).

Task 8 added the sixth mock output to all six files **first**, confirmed the
suite stayed green, and only then added `alarm_actions` to the four bake
alarms. That second step failed exactly where F9 predicted —
`bluegreen.tftest.hcl:504`, on Phase 6's own message — and nowhere else: 34
passed, 1 failed, no other failure. F9's assertion was inverted in place
rather than deleted, keeping the same comment history the resource carries.
Both F9 and F14 retired cleanly, in the order that let each fail on the
assertion it was meant to.

### 3.4 The two `checkov:skip=CKV_AWS_355` comments are inert

`infra/foundation/observability.tf` carries two `# checkov:skip=CKV_AWS_355`
comments, on the collector policy's `PutMetricData` and `GetMetricData`
statements — both actions accept only `Resource: "*"`, since CloudWatch
metrics are not ARN-addressable resources. Whether `CKV_AWS_355` is really the
check ID that fires on a wildcard `Resource` for those actions had been
carried as an open question since Task 6 and was due to be settled at the
static-analysis gate.

It was settled, and the answer was neither of the two anticipated outcomes.
Both skip comments were replaced with a plain marker comment (no
`checkov:skip=` directive) and checkov was re-run directly against `infra/`
with the digest-pinned container the makefile uses:

```
$ docker run --rm --volume "$(pwd)/infra:/infra:ro" \
    bridgecrew/checkov@sha256:c5fb7154bed784fc19a69779c308fddba564f19a37c25d306c0e9765c4f0aa1d \
    --directory /infra --framework terraform --compact

Passed checks: 489, Failed checks: 0, Skipped checks: 109

Check: CKV_AWS_355: "Ensure no IAM policies documents allow "*" as a statement's resource for restrictable actions"
	PASSED for resource: aws_iam_role_policy.release_metrics
	File: /foundation/observability.tf:50-100
```

**Zero failures with the skips removed.** `CKV_AWS_355` evaluates and
**passes** on this policy shape even completely unsuppressed — the skip
directives suppress nothing that was ever going to fail. The file was restored
to its exact committed content (`git status --short` showed no diff) rather
than removed, because the task doing this investigation was permitted to
touch `observability.tf` only for a checkov finding, and no finding under any
ID required a change here.

The skip count itself says something sharper than "inert": removing **both**
directives moved the totals from 488 passed / 110 skipped to 489 passed / 109
skipped — one check moved from skipped to passed, not two, even though two
`checkov:skip=CKV_AWS_355` comments were removed. Both statements belong to
the same single `aws_iam_role_policy.release_metrics` resource, and checkov
evaluates `CKV_AWS_355` **per resource, not per statement** — so the second
comment could never have suppressed anything even in principle, independent
of whether the check fires at all. That is what makes the ruling below
straightforward rather than a judgment call: a directive that cannot possibly
act on the statement it sits beside has no honest reading as a suppression.

**Ruling:** the two comments become ordinary comments carrying the same
reasoning, in this documentation-only task's fix wave, since their content —
"`PutMetricData` accepts no resource ARN, so `*` is the only value it takes,
and the namespace `Condition` is the real control" — is worth keeping, but
dressing it as a suppression is a small untruth: if checkov ever adds a rule
that *does* fire on a wildcard `Resource` there, a reader seeing an existing
skip would wrongly assume it was already considered. This was explicitly
**not** treated as a fix round, because nothing behaves wrongly — it is a
Minor finding recorded here rather than acted on with a behaviour change, and
`observability.tf` in the committed tree still reads `checkov:skip=CKV_AWS_355`
on both statements as of this record. Cost if this ruling is wrong: two
comment lines read slightly differently than they should.

### 3.5 A known limitation, not a defect

Task 8's inverted assertion on the four bake alarms — checking that
`alarm_actions == toset([local.foundation.alerts_topic_arn])` rather than
`== toset([])` — cannot distinguish "this resource reads
`local.foundation.alerts_topic_arn`" from "someone hand-typed that exact ARN
string as a literal". Under `override_data`, both evaluate to the identical
string at assertion time; Terraform's test framework asserts on evaluated
values, not on source expressions, and there is no way to ask it "is this an
expression or a literal" from inside a `.tftest.hcl` run block. The guard rail
this test provides is real — an alarm with the wrong action, or no action,
fails it — but it is weaker than a reader skimming the assertion would assume.
This is inherent to the framework, not a gap this phase could have closed.

### 3.6 A dashboard bug the offline gate could not see

`infra/foundation/tests/dashboard.tftest.hcl` (the suite gaining three of
this phase's ten new Terraform runs, §1) proves `dashboard_body` is valid
JSON with a `widgets` array present; it does not prove any individual widget
is well-formed CloudWatch shape. Task 9's offline structural render — copying
`dashboard.tf`'s locals
into a standalone scratch config, substituting literals for the two
`aws_codepipeline.*.name` references and `local.observability`, and
`jsonencode`-ing the result through an output with `terraform apply` on zero
real resources — found one real bug this way.

Widget 10 ("Production tables") originally merged the two DynamoDB tables'
three-metric groups with `flatten([for table : [...]]...)`. Terraform's
`flatten()` recurses through **every** nesting level, not just the outer one:
it collapsed each table's `[["AWS/DynamoDB", metric, "TableName", table],
...]` structure all the way down into one flat list of bare strings — exactly
a structurally invalid CloudWatch `metrics` array, since each element must be
an array or object, never a scalar. This would not have failed `terraform
test` (the JSON stayed valid, the widget stayed a `metric` widget, all six
required top-level keys stayed present) and would have rendered as a broken
or empty tile only in the console, which is precisely the class of gap the
plan's F8 names.

Fixed by replacing `flatten(...)` with `concat([for table : [...]]...)` —
`concat()` merges only its top-level arguments, preserving the one level of
inner nesting each metric tuple needs. Re-rendered: 12 widgets, `ALL OK` on
the structural check (every widget carries `type`, `x`, `y`, `width`,
`height`, a `properties` object; every metric widget carries `region` and a
`metrics` array of arrays, never a bare scalar). The reviewer independently
searched the whole file for other `flatten(` calls: zero remain.

### 3.7 The runbook's step 5 was wrong as planned

The plan's runbook draft proposed provoking a pipeline failure with
`APP_SCOPE=bogus`. Tracing the mechanism against
`infra/foundation/codepipeline-app.tf` and `scripts/pipeline-deploy.sh` before
writing the runbook found that this cannot fail the pipeline at all: the
`Prod` stage's `before_entry` `VariableCheck` condition is `EQ "all"`
(`DeployStaging`'s is `MATCHES "^(staging|all)$"`), and `bogus` matches
neither — so the affected stages **skip** rather than reach
`scripts/pipeline-deploy.sh`'s own `die "APP_SCOPE is '$scope'; expected one
of build, staging, all"` refusal at all. The execution would finish
**green**, with no email sent, and the runbook as planned would have declared
the alert path tested when it had tested nothing.

Replaced runbook step 5 with **declining the production approval** — the one
point in the pipeline a human is already asked to decide — which produces a
genuine `Failed` execution and exercises the real
`_handle_codepipeline`/`FAILED` path. Verified this does not distort change
failure rate: `dashboard.tf`'s ratio is computed from
`DeploymentFailed`/`DeploymentSucceeded`, a declined approval emits
`PipelineFailed` with a `PipelineName` dimension, and the two never share a
metric. `APP_SCOPE=bogus` was kept as its **own** runbook step (step 6) rather
than dropped, because whether an unrecognised scope skips silently or fails
loudly is Phase 7's own still-open, unverified claim (F2) about a
`VariableCheck` operator the provider schema cannot confirm offline — and this
runbook is the first thing that can settle it. Recording the answer earns a
step; relying on it as a test does not.

---

## 4. No AWS resource was created

This machine has no session. Every command above ran against
`mock_provider "aws"` during `terraform test`, or against files and the local
Python interpreter. What that proves and what it does not:

- **It proves** the whole offline gate — 148 Terraform test runs, tflint,
  checkov, 37 handler tests, formatting — passes with no credentials.
- **It proves** the collector's deployment package really builds:
  `mock_provider` does not mock the `archive` provider, so `data.archive_file`
  really zipped `lambdas/release_metrics/handler.py` during every foundation
  `terraform test` run above.
- **It does not prove** any IAM policy grants enough, or too much, against a
  real account.
- **It does not prove** which ECS event names a blue/green deployment or a
  bake-alarm rollback actually produce (F3), whether
  `artifactRevisions[].created` is populated for this account's CodeConnections
  source (F4), or whether any `SEARCH()` widget matches a real metric (F8).
  Nothing offline can answer any of the three — see §7.

---

## 5. What remains before the exit criteria are met

Both criteria — *a real deployment produces metrics on the dashboard* and *a
deliberately failed deployment produces an email* — need a pipeline execution
against a running production service. This session created no AWS resource,
so **the branch does not meet either criterion by itself**, and the roadmap
amendment says so rather than letting a green branch imply a green dashboard.

[The runbook](../../runbooks/phase-09-observability.md) meets them: the email
criterion at **step 5** (decline the production approval — not the
`APP_SCOPE=bogus` value the plan originally proposed, per §3.7 above), the
dashboard criterion at **step 10** (open the dashboard and confirm every
widget draws, including the ALB `SEARCH()` widgets against a sibling widget on
literal dimensions as the control). Steps 8, 11, 12 and 13 close the three
findings the branch alone could not (§7) and confirm the watchdog alarm path
that does not travel through the collector.

---

## 6. Findings discovered during implementation

Continuing the plan's numbering. F13 and F14 were recorded in the plan
*before* implementation began (§1 of the plan document) and are cross-referenced
above where each was retired; only F15 is new.

### F15 — the first Lambda in a layer breaks every `command = apply` suite in it

See §3.2. `mock_provider` fills computed attributes with a random 8-character
string and `aws_lambda_function` validates `role` client-side as an ARN, so
adding `module.release_metrics` broke four pre-existing suites guarding
Phases 7 and 8 simultaneously. Fixed with one `override_resource` block per
file — purely additive, verified by the reviewer reading the diff rather than
counting it.

### Recorded but not formally numbered

Four more items belong in this ledger and are not given an F-number because
none of them is a gap in an offline source of truth the way F1–F16 are —
each is a defect, a ruling, or a limitation discovered while building or
verifying this phase, and each is described in full in §3 above:

- The plan's own rollback-matcher defect (§3.1), caught before any review and
  missed by the preflight conflict scan that checked ordering but not
  substring matching.
- The two inert `checkov:skip=CKV_AWS_355` comments (§3.4), ruled to become
  ordinary comments in a later cleanup — not yet done, since nothing offline
  requires it.
- The inverted bake-alarm assertion's known limitation (§3.5) — it cannot
  distinguish an evaluated expression from a hand-typed literal, which is a
  property of Terraform's test framework rather than of this phase's tests.
- The dashboard's `flatten()`/`concat()` bug (§3.6), caught by an offline
  structural render `terraform test` could not have performed.

---

## 7. What is not verified

Everything the runbook covers needs a real AWS session and a real
deployment, none of which this session performed. Three specific findings can
only be retired by a real deployment, and no amount of additional offline work
closes them:

- **F3 — the ECS blue/green event vocabulary.** `SUCCEEDED_EVENTS =
  {"SERVICE_DEPLOYMENT_COMPLETED"}` and `FAILED_EVENTS =
  {"SERVICE_DEPLOYMENT_FAILED"}` are a starting guess, not a confirmed set.
  The ECS rule deliberately does not filter on `eventName` precisely so a
  wrong guess costs a log line rather than a lost rollback; runbook step 8
  reads the collector's log after a real deployment and records the truth.
- **F4 — whether `artifactRevisions[].created` is populated** for this
  account's CodeConnections source. `_release_started_at` falls back to the
  execution's own start time when it is absent and logs which basis it used
  either way; runbook step 8 records which of `lead_time_basis=commit` or
  `=merge` this account actually produces.
- **F8 — whether every dashboard `SEARCH()` expression matches anything.**
  `PutDashboard` validates widget structure, not whether a search string
  resolves to a real metric; a `SEARCH()` that matches nothing renders as a
  permanently empty tile that fails nothing, ever. Runbook step 10 opens the
  dashboard and checks each ALB-search widget against a sibling widget on
  literal dimensions (`ClusterName`/`ServiceName`, which cannot fail this way)
  as the control.

Also not verified by this session, and not closable offline at all: whether
any IAM policy in this phase grants enough (or too much) against a real
account; whether a rollback produces its own ECS event distinct from a
`SERVICE_DEPLOYMENT_FAILED` event, which is the runbook's own step 8 item 2 —
explicitly deferred there to Phase 11's alarm-triggered rollback demonstration,
since nothing in this runbook's deployment produces a rollback to observe;
and whether the four bake alarms' thresholds, recorded throughout as *chosen,
not measured*, are the right numbers under real traffic (runbook steps 11–12).
