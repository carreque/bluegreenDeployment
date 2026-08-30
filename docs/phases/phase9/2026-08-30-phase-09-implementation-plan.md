# Phase 9 — Observability and release metrics: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-30
**Status:** Proposed
**Branch:** `feat/Phase9_Observability`
**AWS cost incurred by this phase as planned:** **$0.** Every deliverable is written and verified locally, against mocked providers and with no AWS session. The applies that create the collector, the rules and the dashboard, and the exit-criteria demonstration, are handed to you as a runbook — see §0.1 D1. Once applied, the phase adds roughly **$2.10/month in months a deployment happens** (seven custom metric streams at $0.30) and nothing in months none does.
**Companion documents:**
[design research](../../2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 6 plan](../phase6/2026-08-28-phase-06-implementation-plan.md) ·
[Phase 7 plan](../phase7/2026-08-29-phase-07-implementation-plan.md) ·
[Phase 8 plan](../phase8/2026-08-30-phase-08-implementation-plan.md) ·
[Phase 8 runbook](../../runbooks/phase-08-app-pipeline.md) ·
[naming and tagging convention](../../naming-and-tagging-convention.md)

**Goal:** Make the platform's release behaviour legible — EventBridge rules on both pipelines and on the production ECS service feeding one Lambda that writes deployment frequency, lead time, change failure rate and MTTR under a `ReleaseMetrics` namespace, a single CloudWatch dashboard covering pipeline health and application health in both environments, and SNS email on pipeline failure, deployment failure and rollback — and prove it correct offline before a single resource is created.

Every claim the previous eight phases make about how this platform behaves is currently unmeasured. This phase is where the platform starts describing itself.

**Architecture:** Everything new is added to the existing `infra/foundation/` root module. That is not a preference — `infra/environments/prod` already reads `foundation` through `terraform_remote_state`, so `foundation` reading `prod` back would be a layer cycle (F1), and the destroy-when-idle policy requires the collector and the dashboard to outlive `make teardown` anyway. The one exception is four lines in `prod/alarms.tf`, because `alarm_actions` can only be set where the alarm is. Two EventBridge rules target one Lambda; the Lambda — not an `input_transformer` — decides what is worth an email, which is what makes that decision unit-testable. Correctness is asserted by Terraform's native test framework against `mock_provider` and by `pytest` against injected fake clients; the whole gate stays offline.

**Tech stack:** Terraform 1.15.7, AWS provider 6.61.0, `aws_cloudwatch_event_rule` / `aws_cloudwatch_event_target` / `aws_lambda_permission` / `aws_cloudwatch_dashboard` / `aws_cloudwatch_metric_alarm`, Lambda `python3.14` on `arm64` through the existing [`infra/modules/lambda`](../../../infra/modules/lambda), boto3 from the managed runtime (F2), CloudWatch metric math and `SEARCH()` expressions.

**Spec:** [phase roadmap §3, Phase 9](../../2026-08-04-implementation-phase-roadmap.md#phase-9--observability-and-release-metrics), elaborated by [design research §8](../../2026-08-04-blue-green-deployment-platform-design-research.md#8-observability-and-release-metrics), and taking the three decisions [Phase 5's D7](../phase5/2026-08-28-phase-05-implementation-plan.md), [Phase 6's D9](../phase6/2026-08-28-phase-06-implementation-plan.md) and the [Lambda module's README](../../../infra/modules/lambda/README.md) each deferred to this phase by name.

---

## Global Constraints

Project-wide requirements. Every task's requirements implicitly include this section.

- **Naming:** `bgd-us-east-1-<resource>`, all lowercase, hyphen-separated. Everything this phase creates lives in `foundation` and is project-wide, so it takes **no `<env>` segment** — convention §2 — even where the name contains the word `prod`, which here names *what a rule watches*, not which environment owns it. That is Phase 8's amendment to §2, applied again.
- **Tagging:** exactly four keys — `environment`, `projectName`, `region`, `owner` — applied through the provider's `default_tags`. This layer's `environment` is `shared`; this phase adds no tag and changes no tag.
- **Terraform:** `required_version >= 1.10`, AWS provider `~> 6.61`, S3 backend with `use_lockfile = true`. Unchanged since Phase 3; this phase adds no provider.
- **The offline gate:** `make tf-check` **and** `make test-lambdas` must both pass on a machine that has never run `aws sso login`.
- **Every checkov finding is either fixed or skipped with a written reason.** A bare skip is not acceptable; the reason names the trade-off.
- **Lambda coverage is gated at 95%**, above the application's 90. `lambdas/pyproject.toml` sets it and this phase adds a second package to the same gate.
- **Nothing under `infra/network`, `infra/bootstrap` or `infra/environments/staging` changes.** If this phase needs to edit any of them, something has been misread; stop and re-read D2.

---

## 0. Purpose and non-goals

After Phase 8 a commit under `app/` becomes a production blue/green deployment without anyone touching a laptop. Nobody is told when that fails. No number anywhere records how often it happens, how long it took, or how often it had to be undone — and design §8 promises all four.

This phase closes that. Its job is not dashboards for their own sake: it is that **a failure reaches you without you looking, and a claim about this platform's release behaviour can be checked against a number rather than a memory.**

**This phase deliberately does not:**

- create any AWS resource, or make any AWS API call, in this session (D1)
- enable Container Insights on either cluster (D14)
- measure staging releases (D15) — the dashboard shows staging's health, but staging is *built* to fail and counting its deployments would inflate frequency and deflate change failure rate at once
- send an email when something recovers, or when a run succeeds (D16)
- change any pipeline stage, any buildspec, any IAM role belonging to either pipeline, or any application code
- produce the rollback evidence — Phase 11 owns that, and needs these alerts and this dashboard to exist first so that the evidence has somewhere to be read from
- add a teardown/rebuild step. Phase 10 owns that, and this phase's whole output is deliberately on the surviving side of the teardown line

### 0.1 Decisions taken before this plan was written

#### D1 — This session writes and verifies; you apply

Same as Phases 3 through 8, and for the same reason. Everything that can be built and proved without an AWS session is; the applies and the exit-criteria demonstration are handed over as [a runbook](../../runbooks/phase-09-observability.md).

The branch's own gate is `make tf-check` plus `make test-lambdas`. **Neither exit criterion in §5 is met by the branch alone** — both need a real deployment to have happened — and the roadmap amendment says so rather than letting a green branch imply a green dashboard.

#### D2 — Everything lands in `foundation`, and a layer cycle is what forces it

The tempting split is "release metrics belong with the release", which would put the ECS rule and half the dashboard in `infra/environments/prod`. It cannot be done, for two independent reasons, and the first is structural rather than stylistic.

`prod/locals.tf` already declares `data.terraform_remote_state.foundation`. A dashboard in `foundation` that read prod's ALB ARN through remote state would make each layer read the other. Terraform would not detect it as a cycle — the two states are read at plan time, not linked in one graph — so the symptom is not an error. It is `terraform plan` on `foundation` failing to read a state file that `make teardown` deleted, in the layer whose entire purpose is to survive teardown (F1).

The second reason survives even if the first were solved: **the metric history is the deliverable.** A dashboard destroyed and recreated every session is a dashboard nobody builds a habit of opening, and an EventBridge rule that only exists while prod exists cannot record that prod was torn down.

So the split is:

| Resource | Layer | Why it can only be there |
|---|---|---|
| collector Lambda, its policy, its errors alarm | `foundation` | must outlive teardown; needs the SNS topic and both pipeline ARNs |
| both EventBridge rules and targets | `foundation` | one reads pipeline names, the other survives prod |
| the dashboard | `foundation` | ditto, and it spans both environments |
| `alarm_actions` on the four bake alarms | `prod` | an alarm's actions can only be set where the alarm is |

`foundation` addresses prod by **name**, not by ARN: the ECS service ARN is `arn:aws:ecs:<region>:<account>:service/<prefix>-prod-cluster/<prefix>-prod-api`, and every segment of that is a convention variable `foundation` already holds. `prod/tests/outputs.tftest.hcl` already pins both names as string literals, which is what stops the two layers drifting apart (F13).

#### D3 — Two rules, one Lambda, and the Lambda decides what is alert-worthy

EventBridge can target SNS directly, and a rule with an `input_transformer` would need no Lambda for the alerting half of this phase. It is the wrong shape here for one reason: **"what deserves an email" would then live in a template string inside a Terraform resource, where nothing can test it.**

Routed through the collector instead, that decision is ordinary Python with a pytest suite around it, and the email can say

```
[bgd] Production deployment FAILED — bgd-us-east-1-prod-api
reason: tasks failed to start
https://us-east-1.console.aws.amazon.com/ecs/v2/clusters/…/deployments
```

rather than a JSON blob the recipient has to parse at 2am.

The obvious objection is that a broken collector means no alerts, silently. That is answered by D13, not by keeping EventBridge→SNS as a parallel path: two paths to the same inbox produce two emails per failure, and a duplicate alert trains the recipient to ignore the topic faster than a missing one does.

#### D4 — The ECS rule filters narrowly on the service and **not at all** on the event name

The rule matches `source`, `detail-type` and the exact production service ARN. It deliberately does **not** constrain `detail.eventName`.

The reason is F3: which event names ECS emits for a *blue/green* deployment — and specifically what a bake-alarm rollback produces — is a runtime API contract, not a provider attribute, and there is no offline source of truth for it. The failure modes are not symmetric:

- Filter on a guessed list and guess wrong: the rollback the whole project exists to demonstrate produces **no metric and no email**, and nothing anywhere reports a problem. The rule looks correct in the console.
- Filter on nothing and let the handler ignore what it does not recognise: an unrecognised event costs one Lambda invocation and one `INFO` log line naming the event it saw.

The second is also how the vocabulary gets discovered. The runbook's step 7 reads the collector's log group after the first real deployment and records the actual event names; if the guessed set in `handler.py` turns out wrong, the fix is a one-line edit to a `frozenset` with a test already around it. Same move Phase 6 made with the hook return contract, for the same reason.

#### D5 — Seven metric streams, and the ratios are computed on the dashboard

| Metric | Unit | Dimensions | Emitted when | Answers |
|---|---|---|---|---|
| `DeploymentSucceeded` | Count | `Environment=prod` | ECS deployment completed | deployment frequency |
| `DeploymentFailed` | Count | `Environment=prod` | ECS deployment failed | change failure rate |
| `DeploymentRolledBack` | Count | `Environment=prod` | rollback detected | how often the bake saved you |
| `LeadTimeSeconds` | Seconds | `Environment=prod` | app pipeline succeeded | commit → production |
| `RecoveryTimeSeconds` | Seconds | `Environment=prod` | first success after a failure | MTTR |
| `PipelineFailed` | Count | `PipelineName=<name>` | either pipeline failed | pipeline health |

Six metric *names*, seven metric *streams*, because `PipelineFailed` carries a dimension with two values and CloudWatch bills per unique combination. Seven at $0.30 is $2.10 a month, and only in months where at least one datapoint lands.

**Change failure rate is not among them, deliberately.** It is `100 * failed / (failed + succeeded)`, and a ratio stored as a metric can only ever be computed over whatever window the writer chose — which is never the window the reader is looking at. As dashboard metric math it recomputes for whatever range you drag to. Deployment frequency is the same argument: it is `SUM(DeploymentSucceeded)` over the period the viewer picked, not a rate anyone has to store.

#### D6 — Lead time comes from the application pipeline's own execution, commit-basis with a stated fallback

The app pipeline's last action is the production `terraform apply`, and Phase 6 set `wait_for_steady_state = true`, so **that pipeline reaching `SUCCEEDED` is exactly the moment the change is live in production.** Nothing else in the system knows that as precisely.

`codepipeline:GetPipelineExecution` returns `artifactRevisions[].created`, which for a source revision is the commit timestamp — genuine commit-to-production lead time. Whether that field is populated for a CodeConnections/GitHub source cannot be confirmed offline (F4), so the handler falls back to the execution's own `startTime` from `ListPipelineExecutions`, which is merge-to-production.

The two are not the same number and the handler never pretends otherwise: it logs `lead_time_basis=commit` or `lead_time_basis=merge` on every emission. The metric is emitted either way, because a lead-time series that silently stops when an API field is absent is worse than one whose basis is written in the log beside it. The runbook's step 7 records which basis is real, and the dashboard's text widget states it.

The alternative — correlating an ECS deployment back to its image tag, then to `app-builds/<tag>/build-metadata.json` in the artifact bucket — was rejected: three API calls and an S3 read to recover a timestamp the pipeline already knows, and it would break the moment someone deploys by `make apply-prod`.

#### D7 — MTTR needs no state store, and the ordering of two calls is what makes that true

MTTR is the gap between a failure and the next success, which normally means remembering the failure. This handler does not: on a success it asks CloudWatch what it already wrote.

One `GetMetricData` call over the last 30 days returns two series — `DeploymentFailed` and `DeploymentSucceeded` — scanned newest-first. If the most recent failure has no success after it, this success is the recovery, and `RecoveryTimeSeconds` is `now - that failure`.

**That call must happen before `DeploymentSucceeded` is written for this event**, or the success just written is the one it finds and every recovery measures zero. The ordering is load-bearing, it is one line apart in the code, and a test asserts it by making the fake CloudWatch client record call order.

No DynamoDB table, no S3 marker, no Lambda state. The metric store is the state store, which it already had to be for the dashboard.

#### D8 — A rollback emits `DeploymentRolledBack` only, and never also `DeploymentFailed`

A rollback is a change failure, so the tempting rule is "emit both". It is refused because of F3: if ECS emits **both** a rollback-shaped event and a `SERVICE_DEPLOYMENT_FAILED` event for the same deployment — which is likely and unconfirmable offline — every rollback would count twice in the change-failure-rate numerator, and a 50% number would read as 67%.

So each event produces at most one outcome metric, checked in this order: rollback, then failed, then succeeded. If ECS turns out to emit *only* a rollback event, change failure rate under-counts by exactly the rollbacks — and that gap is visible, because `DeploymentRolledBack` is its own widget sitting beside it on the same dashboard. An under-count you can see beats an over-count you cannot.

The runbook's step 7 records which events actually arrive, and the fix if it is the second case is one line in `_handle_ecs`.

#### D9 — The handler raises only on internal failure, never on an unrecognised event

The lifecycle hook raises when in doubt, because its failure mode is promoting a bad build. This handler's asymmetry runs the other way, and stating that here stops someone "making them consistent".

An exception in an EventBridge-invoked Lambda is retried, then fires the errors alarm (D13), then emails you. If the handler raised on every event shape it did not recognise, the `SERVICE_DEPLOYMENT_IN_PROGRESS` events that arrive on **every** deployment — which D4's deliberately broad rule delivers on purpose — would each produce retries and an alert. The alarm that exists to say "the collector is broken" would fire continuously while the collector worked perfectly.

So: unrecognised source, unrecognised event name, absent field → log and return a `{"handled": False, …}` dictionary. A failed `PutMetricData`, `Publish` or `GetPipelineExecution` → let it raise, because that is the collector actually being broken and is exactly what D13's alarm is for.

#### D10 — The Lambda module is reused unchanged; boto3 ships in the runtime

[`infra/modules/lambda/README.md`](../../../infra/modules/lambda/README.md) predicts this phase needs a module variant: *"a dependency-bearing package cannot be expressed as `archive_file` over a single file — it needs either a `source_dir` with vendored dependencies, a layer, or a build step."*

It does not, because **boto3 and botocore are present in the Lambda managed Python runtime** (F2). The collector imports `boto3` and `json` and nothing else, so the deployment package stays one file, `data.archive_file` keeps really building the zip during `terraform test` against a mocked AWS provider, and the offline gate keeps failing loudly if the handler path is wrong — the property that README calls "what keeps the offline gate honest".

The accepted cost is that the collector runs whatever boto3 version the runtime ships, which AWS may change. For `put_metric_data`, `get_metric_data`, `publish` and `get_pipeline_execution` — four calls whose signatures predate this project by a decade — that is not a risk worth a vendoring step, a layer, and a build. The README is amended to say so rather than left predicting work this phase then does not do.

#### D11 — The module's six checkov skips are re-examined, one no longer holds as written, and there is still no DLQ

`infra/modules/lambda/main.tf` carries a note in capitals: *"PHASE 9 MUST RE-EXAMINE THEM. These suppressions live on the module, so a metrics collector added here inherits every one of them."* This is that re-examination, and it found one reason that is false for the new function.

| Check | Written for a synchronous gate | Still true for an async collector? |
|---|---|---|
| `CKV_AWS_50` X-Ray | one urllib call, already logged in full | **Yes** — four boto3 calls, each logged with its outcome |
| `CKV_AWS_116` DLQ | *"invoked SYNCHRONOUSLY … there is no dropped event for a DLQ to catch"* | **No.** EventBridge invokes asynchronously; a dropped event is real |
| `CKV_AWS_115` reserved concurrency | bounded by the deployment controller | **Yes** — bounded by deployments and pipeline executions, both rare |
| `CKV_AWS_117` VPC | probes a public ALB | **Yes** — CloudWatch, SNS and CodePipeline are public API endpoints |
| `CKV_AWS_173` env encryption | URL, stage, digest — all public facts | **Yes** — namespace, topic ARN, two pipeline names |
| `CKV_AWS_272` code signing | zip built by `archive_file` in the same apply | **Yes** — unchanged |

So `CKV_AWS_116`'s reason is **rewritten to cover both invocation shapes**, and the answer is still no DLQ, for a different reason than before: nothing in this project polls a queue. A DLQ here would accumulate events no human or process ever reads while suggesting to the next reader that dropped invocations are handled somewhere. What actually handles them is D13's alarm, which mails a person within a minute.

What *does* change is the retry window. EventBridge's default is **185 attempts over 24 hours** (F11), which for an alert is absurd — a "production deployment failed" email arriving tomorrow is noise. Both targets set `retry_policy { maximum_retry_attempts = 2, maximum_event_age_in_seconds = 300 }`: three chances inside five minutes, and after that the errors alarm has already fired.

#### D12 — The four bake alarms gain `alarm_actions`, and Phase 6's test is inverted rather than deleted

`prod/outputs.tf` promises it: *"Phase 9 attaches SNS actions to these same alarms rather than creating parallel ones — which is the whole reason this layer creates them with no actions."* `prod/tests/bluegreen.tftest.hcl` asserts the absence, so **the first change this phase makes to `prod` fails the offline gate until that assertion is turned around** (F9). That is the test doing its job, and the inversion keeps the same shape and the same comment history rather than deleting the run.

Two consequences to accept, both of which the Phase 6 comment anticipated and neither of which is a reason to skip this:

- **Phase 11's deliberate demonstrations will send real email.** Phase 6 refused to attach actions partly to avoid "training the recipient to ignore the topic before it carries a real alert". That risk was about the eight phases where the topic carried nothing; from here the topic carries real alerts, and a demonstration rollback that mails you is the demonstration working.
- **The four thresholds gain a second consumer.** They are recorded in `alarms.tf` as *chosen, not measured*, and until now a wrong one only mis-gated a bake. From here a wrong one is also a 3am email about a p95 that was always that shape. The runbook's threshold-tuning step matters more than it did, and this plan's runbook repeats it rather than pointing at Phase 6's.

`ok_actions` stays empty (D16): an alarm returning to OK during a five-minute bake is the normal end of every successful deployment.

#### D13 — The collector's own errors alarm is the watchdog, and it does not go through the collector

`AWS/Lambda` `Errors` for the collector function, one datapoint in one minute, `alarm_actions` straight to the SNS topic. It is the answer to "who watches the watcher", and the only alert in this phase whose path does not include the Lambda.

`treat_missing_data = "notBreaching"`, for the reason prod's `unhealthy` alarms record: the collector is invoked a handful of times a week, so the metric is absent almost always, and the default would park the alarm in `INSUFFICIENT_DATA` permanently.

#### D14 — Container Insights stays disabled on both clusters

Phase 5's D7 and Phase 6's cluster both wrote `containerInsights = "disabled"` with a comment naming this phase as the one that decides. **The answer is no**, and the two checkov skips already in place stay true rather than needing rewording.

`AWS/ECS` publishes `CPUUtilization`, `MemoryUtilization` and `RunningTaskCount` at service level for free, which is every ECS signal this dashboard shows. Container Insights bills per metric per hour per task for per-container and per-task detail that answers questions this project does not ask — and it would bill it on the two layers the destroy-when-idle policy exists to keep cheap. The escalation is one word in each cluster's `setting` block if a future phase needs it.

#### D15 — Release metrics are production-only; the dashboard covers both environments

DORA metrics describe production releases. Staging is deliberately built to fail fast — Phase 5's circuit breaker exists to make it fail — so counting its deployments would inflate frequency and deflate change failure rate simultaneously, producing two numbers that are each wrong in a flattering direction.

The dashboard still shows staging's ALB and ECS health, because "staging is sick" is the answer to "why did the pipeline stop", and the person asking that question should not have to open a second console tab.

That is also why every release metric carries `Environment=prod` as a dimension rather than no dimension at all: the series is explicitly scoped, so a later phase that does decide to measure staging adds a dimension value instead of reinterpreting a namespace.

#### D16 — Alerts are failures and rollbacks; there are no success or recovery emails

Four things send email: either pipeline reaching `FAILED`, a production ECS deployment failing, a production rollback, and any bake alarm breaching. Nothing else — no `ok_actions`, no notification when a run succeeds, no "recovered" message.

The reasoning is that an alert's value is inversely proportional to how many of them arrive, and this project's whole alerting surface is one address. Recovery is visible on the dashboard within a minute of it happening, and `RecoveryTimeSeconds` records it permanently.

#### D17 — ALB widgets use `SEARCH()`; ECS and DynamoDB use literal dimensions

The `LoadBalancer` dimension value is `app/<name>/<16 hex characters>` — the hex is assigned at creation and is **not** derivable from the naming convention, which is the one dimension in this dashboard that D2's no-remote-state rule cannot supply.

So ALB and target-group widgets use metric-math search expressions:

```
SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName="HTTPCode_Target_5XX_Count" bgd-us-east-1-prod-alb', 'Sum', 60)
```

which matches on the name and therefore keeps working when `make teardown` and `make rebuild` give the load balancer a new suffix. Nothing else in the dashboard needs it: `ClusterName`, `ServiceName`, `TableName` and `FunctionName` are all exactly the convention's strings, so those widgets state their dimensions literally and are easier to read for it.

The cost is F8 — a `SEARCH` that matches nothing renders as an empty widget rather than failing the apply — which is why the runbook has a step that opens the dashboard and confirms every widget draws.

#### D18 — `lambdas/**` joins the infrastructure pipeline's trigger

Not in the roadmap's task list, and the phase is incomplete without it. F6: the infra pipeline watches six path patterns and none of them matches `lambdas/`. Both this phase's collector and Phase 6's three lifecycle hooks are packaged from that directory by a Terraform apply in a watched layer — but a commit that only edits a handler changes no watched file, so **the pipeline does not run and the fix never reaches the function.** No error, no failed run: nothing happens at all.

This is the same class of gap as the `scripts/tf.sh` one Phase 8 found, and predates this phase by three. Seven patterns still fits `filePaths.includes`'s cap of eight (F7), and `foundation/tests/pipeline_shape.tftest.hcl` asserts the set exactly, so the test is updated in the same commit as the trigger.

---

## 1. Findings recorded before this plan was written

### F1 — `foundation` cannot read `prod`'s remote state, and the failure would not look like a cycle

`infra/environments/prod/locals.tf` declares `data.terraform_remote_state.foundation`. Adding the mirror in `foundation` produces no Terraform error — the two states are separate files read at plan time, not nodes in one graph. What it produces is a `foundation` plan that reads `prod/terraform.tfstate`, which `make teardown` deletes the contents of, in the layer whose defining property is surviving teardown. Drives D2 and D17.

### F2 — boto3 is in the Lambda managed Python runtime, so the module needs no variant

AWS ships boto3 and botocore in every managed Python runtime. The collector's imports are `boto3`, `json`, `logging`, `os` and `datetime` — nothing to vendor, so `archive_file` over one source file still expresses the whole package and the offline gate still really builds the zip. Retires the prediction in `infra/modules/lambda/README.md`. Drives D10.

The caveat AWS attaches — the bundled version can change without notice — is accepted for four API calls whose signatures are a decade old, and recorded in the module README.

### F3 — The ECS blue/green event vocabulary is not in the provider schema

`aws_cloudwatch_event_rule` takes `event_pattern` as an opaque JSON string. Which `detail.eventName` values ECS emits for a `BLUE_GREEN` deployment, and specifically what an alarm-triggered rollback during the bake produces, is a runtime contract with no offline source of truth. The known-good rolling-deployment names — `SERVICE_DEPLOYMENT_IN_PROGRESS`, `SERVICE_DEPLOYMENT_COMPLETED`, `SERVICE_DEPLOYMENT_FAILED` — are the starting set. Drives D4, D8 and the runbook's step 7.

### F4 — `artifactRevisions[].created` may not be populated for a CodeConnections source

`GetPipelineExecution` documents `artifactRevisions` with a `created` timestamp, and for a Git source that is the commit date. Whether CodePipeline populates it for a `CodeStarSourceConnection` — as opposed to leaving it null and putting the commit date only in `revisionSummary`'s free text — cannot be checked without running a pipeline. Drives D6's fallback and the `lead_time_basis` log line.

### F5 — `cloudwatch:GetMetricData` cannot be resource-scoped

CloudWatch metrics are not resources with ARNs, so `GetMetricData` accepts only `Resource: "*"`. `PutMetricData` is the same, but it does support a `cloudwatch:namespace` condition key, which is used to confine the collector to `ReleaseMetrics`. Expect checkov to flag the wildcard on the `GetMetricData` statement; the skip's reason is that the action has no resource form, not that the wildcard is convenient.

### F6 — The infra pipeline's trigger has never watched `lambdas/**`

Current set, from `infra/foundation/codepipeline.tf`: `infra/**`, `pipelines/infra-*.yml`, `scripts/pipeline-terraform.sh`, `scripts/install-terraform.sh`, `scripts/tf.sh`, `scripts/lib/common.sh`. `infra/environments/prod/hooks.tf` has packaged `lambdas/lifecycle_hook/handler.py` since Phase 6. A handler-only commit therefore deploys nothing, silently. Drives D18.

### F7 — `filePaths.includes` accepts eight patterns and the list has six

Phase 8 recorded the cap when the application pipeline's eleven patterns had to be split across two `push` blocks. The infra list has room for one more without splitting. Confirms D18 is a one-line change.

### F8 — A dashboard body is validated for structure, not for whether a search matches anything

`PutDashboard` returns `DashboardValidationMessages` for a malformed widget, and the provider surfaces those as an apply error — so a typo in a widget's *structure* fails loudly. A `SEARCH()` expression that matches no metric is structurally valid and renders as an empty widget. There is no offline way to tell the two apart. Drives the runbook's dashboard-inspection step.

### F9 — Phase 6's test forbids what this phase must add

`infra/environments/prod/tests/bluegreen.tftest.hcl` asserts that all four bake alarms have zero `alarm_actions` and zero `ok_actions`, with a comment naming this phase. Adding the actions fails `make tf-check` until the assertion is inverted. Expected, and the reason Task 8 changes the test and the resource in one commit. Drives D12.

### F10 — Seven metric streams is about $2.10 a month, and only while they receive data

CloudWatch bills custom metrics per metric per month at $0.30 for the first 10,000, prorated by the hours in which the metric exists. A metric that receives no datapoint in a month is not billed for that month, so a session where nothing is deployed costs nothing here. The dashboard itself is free — the account's first three are.

### F11 — EventBridge's default retry policy is 24 hours

An unset `retry_policy` means up to 185 attempts across 24 hours. For a metric that is merely slow; for a "production deployment failed" email it is wrong, and it also means a genuinely broken collector keeps being invoked all day. Drives D11's explicit `maximum_retry_attempts = 2, maximum_event_age_in_seconds = 300`.

### F12 — `mock_provider "aws"` does not mock the `archive` provider

Phase 6's F4, unchanged and reused: `terraform test` really builds the collector's zip from `lambdas/release_metrics/handler.py`, so a wrong `source_file` path fails the offline gate rather than the first apply. It is the reason the module needs no test suite of its own and the reason Task 6's test can assert on a real package.

### F14 — `prod`'s foundation override is repeated in six files and does not carry the topic ARN

`infra/environments/prod/tests/mocks.tftest.hcl` says it plainly: *"Terraform's test framework has no shared-setup construct for `mock_provider`, so every other test file in this directory repeats these three blocks verbatim."* The `override_data` for `data.terraform_remote_state.foundation` supplies five outputs — `certificate_arn`, `zone_id`, `api_domain`, `ecr_repository_url`, `ecr_repository_arn` — and **`alerts_topic_arn` is not one of them.**

So the moment `alarms.tf` references `local.foundation.alerts_topic_arn`, all six files fail with *"This object does not have an attribute named alerts_topic_arn"* — before any assertion runs, in five files that have nothing to do with alarms. That is not the F9 failure Task 8 predicts and would read as the new code being wrong.

The override must be extended in **all six** files in the same commit. Drives Task 8's steps 4 and 5, and it is the reason those steps are ordered override-first.

### F13 — Every name fits, and the two cross-layer names are already pinned

| Name | Length | Cap |
|---|---|---|
| `bgd-us-east-1-release-metrics` | 29 | 64 (Lambda) |
| `bgd-us-east-1-release-metrics-exec-role` | 39 | 64 (IAM role) |
| `bgd-us-east-1-pipeline-executions` | 33 | 64 (rule) |
| `bgd-us-east-1-prod-deployments` | 30 | 64 (rule) |
| `bgd-us-east-1-release-metrics-errors` | 36 | 255 (alarm) |
| `bgd-us-east-1-release` | 20 | 255 (dashboard) |

The two names `foundation` reconstructs to address prod — `bgd-us-east-1-prod-cluster` and `bgd-us-east-1-prod-api` — are already asserted as literals by `infra/environments/prod/tests/outputs.tftest.hcl` lines 131–132, so a rename in `prod` fails there rather than silently orphaning this phase's rule.

### Findings discovered during implementation

_Appended as they are found, in the same shape as the ones above. Empty until Task 1 begins._

---

## 2. Global constraints

Restating the ones this phase breaks if it gets them wrong, with the symptom attached.

| Constraint | Symptom if missed |
|---|---|
| `GetMetricData` runs **before** `DeploymentSucceeded` is written (D7) | Every recovery measures ~0 seconds. MTTR is a flat line at zero and looks like excellent operations. |
| The ECS rule does not filter `detail.eventName` (D4) | A rollback produces no metric and no email; the console shows a healthy rule. |
| At most one outcome metric per event (D8) | Rollbacks counted twice; change failure rate inflated by half. |
| The handler returns rather than raises on unknown events (D9) | Every `IN_PROGRESS` event retries and alarms. The watchdog fires constantly while nothing is wrong. |
| `retry_policy` set on both targets (D11, F11) | A failure email can arrive up to 24 hours late, and a broken collector is invoked 185 times. |
| `PutMetricData` scoped by `cloudwatch:namespace` condition (F5) | Not a failure — a missed chance. The only least-privilege lever the action offers. |
| Phase 6's no-alarm-actions assertion inverted in the same commit (F9) | `make tf-check` fails and it looks like the new code is wrong. |
| `alerts_topic_arn` added to the foundation override in **all six** prod test files (F14) | Five test files unrelated to alarms fail with a missing-attribute error before any assertion runs. |
| `alarm_actions` on prod's alarms read from `local.foundation.alerts_topic_arn` | A hand-written ARN drifts the day the topic is recreated, and an alarm with a stale action fails silently. |
| `lambdas/**` in the infra trigger, and the shape test updated with it (D18) | A handler fix is merged, the pipeline does not run, and the old code keeps gating production. |
| Policies built with `jsonencode`, never `aws_iam_policy_document` | `mock_provider` mocks the policy-document data source too. Every assertion on the policy becomes vacuous. Phase 5 §F1. |
| The collector's log group exists before the function (module behaviour) | Lambda creates one itself with no retention, and the exec role's scoped policy points at a group nothing writes to. |
| Coverage source in `lambdas/pyproject.toml` lists **both** packages | The new package is untested at 0% and the 95% gate still passes, because coverage never looked at it. |

---

## 3. File structure

```
lambdas/
  release_metrics/
    handler.py                NEW   the collector: routing, metrics, alerts, lead time, MTTR
  tests/
    test_release_metrics.py   NEW   fake boto3 clients injected through the _CLIENTS seam
  pyproject.toml              MODIFIED  coverage source gains release_metrics
  README.md                   MODIFIED  the second package, its environment, its contract

infra/modules/lambda/
  main.tf                     MODIFIED  CKV_AWS_116's reason rewritten for both shapes (D11)
  README.md                   MODIFIED  no variant needed; boto3 is in the runtime (D10, F2)

infra/foundation/
  variables.tf                MODIFIED  three new variables
  locals.tf                   MODIFIED  the collector name and the derived prod identifiers
  observability.tf            NEW   the collector, its policy, two rules, two targets,
                                    two permissions, the errors alarm
  dashboard.tf                NEW   the widget locals and the dashboard
  codepipeline.tf             MODIFIED  the trigger gains lambdas/** (D18)
  outputs.tf                  MODIFIED  collector name, log group, dashboard name and URL
  README.md                   MODIFIED  the layer now owns the observability plane
  tests/
    observability.tftest.hcl  NEW   the function, the policy, both rules, both targets,
                                    the permissions, the retry policy, the alarm
    dashboard.tftest.hcl      NEW   the body parses, and every widget names a real thing
    pipeline_shape.tftest.hcl MODIFIED  the trigger's seven patterns

infra/environments/prod/
  alarms.tf                   MODIFIED  alarm_actions on all four (D12)
  tests/bluegreen.tftest.hcl  MODIFIED  the assertion inverts (F9)

docs/
  runbooks/phase-09-observability.md              NEW
  runbooks/README.md                              MODIFIED  the row that says "planned"
  phases/phase9/
    2026-08-30-phase-09-implementation-plan.md    this document
    2026-08-30-local-verification.md              NEW   the evidence record
  naming-and-tagging-convention.md                MODIFIED  §7's worked example gains the
                                                            observability plane
  2026-08-04-implementation-phase-roadmap.md      MODIFIED  the Phase 9 amendment, and a
                                                            second note on Phase 7's trigger
  2026-08-04-blue-green-deployment-platform-design-research.md
                                                  MODIFIED  §8: the metric set, the two rules,
                                                            and why the ratios are not stored
```

**Why these boundaries.** `observability.tf` and `dashboard.tf` are separate because they fail differently and are read at different times: the first is the wiring that decides whether an event ever reaches code, the second is presentation whose worst failure is an empty widget. Someone debugging "no email arrived" should not have to scroll past four hundred lines of widget JSON to reach the rule.

The collector's extra IAM policy lives in `observability.tf` rather than a third `iam-*.tf` file, which departs from the note in `iam-app-pipeline.tf` predicting "Phase 9 adds a third set". It is not a set — it is one `aws_iam_role_policy` attached to a role the module already created — and separating a single policy from the function it belongs to would cost a file and gain nothing. The prediction is corrected in that file's comment.

The two test files split the way the risk does. `observability.tftest.hcl` protects wiring a plan review cannot see: whether the rule's pattern names the right service ARN, whether the permission's `source_arn` matches the rule that invokes it, whether the retry policy was set at all. `dashboard.tftest.hcl` protects against the dashboard silently describing resources that do not exist, which is the failure F8 says the apply will not catch.

---

## 4. Tasks

Twelve tasks. Tests precede implementation throughout — for Python that means `pytest` red before green, and for Terraform it means the `.tftest.hcl` file is written and **seen to fail** before the resources it asserts on exist.

Every task ends with its suite passing and a commit **proposed for approval, never made automatically**. The full gate — `make tf-check` and `make test-lambdas` — runs at Task 10 and again at Task 12.

---

### Task 1: The collector package, the client seam, and event routing

First, because every later handler task hangs off the routing and the seam. Nothing here calls AWS; the seam is what lets the rest of the suite avoid it too.

**Files:**
- Create: `lambdas/release_metrics/handler.py`
- Create: `lambdas/tests/test_release_metrics.py`
- Modify: `lambdas/pyproject.toml` (coverage source)

**Interfaces:**
- Consumes: nothing.
- Produces: `handler(event, context) -> dict[str, object]`; `_client(service: str)` backed by the module-level `_CLIENTS: dict[str, object]` that tests write fakes into; `_now() -> datetime` returning an aware UTC datetime; the six metric-name constants `METRIC_DEPLOYMENT_SUCCEEDED`, `METRIC_DEPLOYMENT_FAILED`, `METRIC_DEPLOYMENT_ROLLED_BACK`, `METRIC_LEAD_TIME`, `METRIC_RECOVERY_TIME`, `METRIC_PIPELINE_FAILED`.

- [ ] **Step 1: Add the package to the coverage gate**

In `lambdas/pyproject.toml`:

```toml
[tool.coverage.run]
source = ["lifecycle_hook", "release_metrics"]
branch = true
```

Do this first and deliberately. With the source list unchanged, the new package is invisible to coverage: it could be entirely untested and the 95% gate would still pass, because coverage would never have looked at it.

- [ ] **Step 2: Write the failing routing tests**

Create `lambdas/tests/test_release_metrics.py`:

```python
"""The release metrics collector.

Every test injects fake clients through handler._CLIENTS, so the suite makes no
network call and needs no AWS session — the same property lifecycle_hook's suite
has, reached by a different seam because this handler legitimately calls AWS.
"""

from datetime import UTC, datetime

import pytest
from release_metrics import handler as h


class FakeCloudWatch:
    def __init__(self, metric_data_response=None):
        self.puts = []
        self.calls = []
        self._metric_data_response = metric_data_response or {"MetricDataResults": []}

    def put_metric_data(self, **kwargs):
        self.calls.append("put_metric_data")
        self.puts.append(kwargs)
        return {}

    def get_metric_data(self, **kwargs):
        self.calls.append("get_metric_data")
        self.get_metric_data_kwargs = kwargs
        return self._metric_data_response


class FakeSNS:
    def __init__(self):
        self.published = []

    def publish(self, **kwargs):
        self.published.append(kwargs)
        return {"MessageId": "fake"}


@pytest.fixture
def clients(monkeypatch):
    """Install fakes and a frozen clock; yield them for assertions."""
    cloudwatch, sns = FakeCloudWatch(), FakeSNS()
    monkeypatch.setattr(h, "_CLIENTS", {"cloudwatch": cloudwatch, "sns": sns})
    monkeypatch.setattr(h, "_now", lambda: datetime(2026, 8, 30, 12, 0, 0, tzinfo=UTC))
    monkeypatch.setenv("BGD_ALERT_TOPIC_ARN", "arn:aws:sns:us-east-1:590184028094:bgd-alerts")
    monkeypatch.setenv("BGD_APP_PIPELINE", "bgd-us-east-1-app-pipeline")
    return {"cloudwatch": cloudwatch, "sns": sns}


def test_an_unrecognised_source_is_ignored_rather_than_raised(clients):
    # D9. Raising here would retry, then fire the errors alarm, then email —
    # for an event the collector simply has no opinion about.
    result = h.handler({"source": "aws.s3", "detail": {}}, None)

    assert result["handled"] is False
    assert clients["cloudwatch"].puts == []
    assert clients["sns"].published == []


def test_an_event_with_no_source_at_all_is_ignored(clients):
    assert h.handler({}, None)["handled"] is False


def test_the_ecs_source_routes_to_the_deployment_handler(clients):
    result = h.handler(
        {"source": "aws.ecs", "detail": {"eventName": "SERVICE_DEPLOYMENT_IN_PROGRESS"}},
        None,
    )

    # IN_PROGRESS arrives on every deployment because the rule deliberately
    # does not filter event names (D4). It must cost nothing but a log line.
    assert result["handled"] is False
    assert clients["cloudwatch"].puts == []
```

- [ ] **Step 3: Run the tests and confirm they fail for the right reason**

Run: `make test-lambdas`
Expected: FAIL, collection error — `ModuleNotFoundError: No module named 'release_metrics'`.

- [ ] **Step 4: Write the module docstring, the constants and the seam**

Create `lambdas/release_metrics/handler.py`:

```python
"""Release metrics collector.

One handler, two event sources. EventBridge delivers CodePipeline execution
state changes and production ECS deployment state changes; this writes the
ReleaseMetrics series behind the dashboard and publishes the failures worth an
email.

See docs/phases/phase9/2026-08-30-phase-09-implementation-plan.md D3 through D9.

THE RETURN CONTRACT IS THE OPPOSITE OF lifecycle_hook's, deliberately. That
handler raises when in doubt, because its failure mode is promoting a bad build.
This one returns, because it is invoked asynchronously: an exception is retried
and then fires the errors alarm, so raising on an event shape it merely does not
recognise would make the alarm that says "the collector is broken" fire
continuously while the collector worked perfectly. It raises only when an AWS
call it needs actually fails, which is what that alarm is for. Plan D9.

boto3 only, from the Lambda managed runtime — nothing vendored, so the
deployment package is still one file and terraform test still really builds it.
Plan D10 and F2.
"""

import json
import logging
import os
from datetime import UTC, datetime

import boto3

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

DEFAULT_NAMESPACE = "ReleaseMetrics"
DEFAULT_ENVIRONMENT = "prod"
DEFAULT_MTTR_LOOKBACK_DAYS = 30

METRIC_DEPLOYMENT_SUCCEEDED = "DeploymentSucceeded"
METRIC_DEPLOYMENT_FAILED = "DeploymentFailed"
METRIC_DEPLOYMENT_ROLLED_BACK = "DeploymentRolledBack"
METRIC_LEAD_TIME = "LeadTimeSeconds"
METRIC_RECOVERY_TIME = "RecoveryTimeSeconds"
METRIC_PIPELINE_FAILED = "PipelineFailed"

# The starting vocabulary, not a confirmed one. Which names ECS emits for a
# BLUE_GREEN deployment is a runtime contract with no offline source of truth
# (plan F3), which is exactly why the EventBridge rule does not filter on it and
# why an unrecognised name is logged rather than raised. The runbook's step 7
# reads the real set out of CloudWatch after the first deployment; if these are
# wrong the fix is one line here, with these tests already around it.
SUCCEEDED_EVENTS = frozenset({"SERVICE_DEPLOYMENT_COMPLETED"})
FAILED_EVENTS = frozenset({"SERVICE_DEPLOYMENT_FAILED"})

# One client per service per container, created on first use rather than at
# import. Two reasons: a module-level boto3.client() runs during the cold start
# of every invocation whether or not that call is needed, and — the reason that
# matters here — a dict is a seam a test can write a fake into without patching
# boto3 itself or installing a mocking library. lambdas/ deliberately has no
# such dependency, the same choice app/ made for DynamoDB.
_CLIENTS: dict[str, object] = {}


def _client(service: str):
    if service not in _CLIENTS:
        _CLIENTS[service] = boto3.client(service)
    return _CLIENTS[service]


def _now() -> datetime:
    """The clock, as a function so tests can freeze it.

    Aware and UTC, because every timestamp boto3 returns is aware and comparing
    an aware datetime to a naive one raises TypeError — during an alert.
    """
    return datetime.now(UTC)


def _namespace() -> str:
    return os.environ.get("BGD_METRIC_NAMESPACE", DEFAULT_NAMESPACE)


def _environment() -> str:
    return os.environ.get("BGD_ENVIRONMENT", DEFAULT_ENVIRONMENT)


def handler(event: dict, context: object) -> dict[str, object]:
    """Route one EventBridge event to the handler for its source."""
    LOGGER.info("event=%s", json.dumps(event, default=str))

    source = (event or {}).get("source")

    if source == "aws.ecs":
        return _handle_ecs(event)
    if source == "aws.codepipeline":
        return _handle_codepipeline(event)

    LOGGER.warning("ignoring unrecognised source=%s", source)
    return {"handled": False, "source": source}
```

Then the two stubs the routing needs, and nothing more. Tasks 2 and 3 replace them; do not stub anything this task's tests do not exercise.

```python
def _handle_ecs(event: dict) -> dict[str, object]:
    LOGGER.info("ecs event received; Task 2 implements the outcomes")
    return {"handled": False}


def _handle_codepipeline(event: dict) -> dict[str, object]:
    LOGGER.info("codepipeline event received; Task 3 implements the outcomes")
    return {"handled": False}
```

Both are defined **above** `handler`, because Python resolves the names at call time but a reader resolves them top to bottom, and the rest of this file keeps helpers above their caller.

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `make test-lambdas`
Expected: the three new tests PASS. The coverage gate will fail at this point because the stubs are barely exercised — that is expected until Task 4, and the failure line names coverage rather than a test.

- [ ] **Step 6: Commit**

```bash
git add lambdas/release_metrics/handler.py lambdas/tests/test_release_metrics.py lambdas/pyproject.toml
git commit -m "feat(lambdas): the release metrics collector's routing and client seam"
```

---

### Task 2: Deployment outcomes — succeeded, failed, rolled back, and the alert

**Files:**
- Modify: `lambdas/release_metrics/handler.py`
- Modify: `lambdas/tests/test_release_metrics.py`

**Interfaces:**
- Consumes: `_client`, `_now`, `_namespace`, `_environment`, the metric constants (Task 1).
- Produces: `_put(metric_name: str, value: float, unit: str, dimensions: dict[str, str]) -> None`; `_alert(subject: str, message: str) -> None`; `_handle_ecs(event: dict) -> dict[str, object]`.

- [ ] **Step 1: Write the failing outcome tests**

Append to `lambdas/tests/test_release_metrics.py`:

```python
ECS_EVENT = {
    "source": "aws.ecs",
    "region": "us-east-1",
    "resources": [
        "arn:aws:ecs:us-east-1:590184028094:service/"
        "bgd-us-east-1-prod-cluster/bgd-us-east-1-prod-api"
    ],
    "detail": {"eventName": "SERVICE_DEPLOYMENT_COMPLETED", "deploymentId": "ecs-svc/123"},
}


def _ecs(event_name, reason=None):
    detail = dict(ECS_EVENT["detail"], eventName=event_name)
    if reason is not None:
        detail["reason"] = reason
    return dict(ECS_EVENT, detail=detail)


def _metric_names(fake):
    return [put["MetricData"][0]["MetricName"] for put in fake.puts]


def test_a_completed_deployment_is_counted_and_sends_no_email(clients):
    result = h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    assert result["outcome"] == "succeeded"
    assert h.METRIC_DEPLOYMENT_SUCCEEDED in _metric_names(clients["cloudwatch"])
    # D16: success is not an alert.
    assert clients["sns"].published == []


def test_a_failed_deployment_is_counted_and_emails(clients):
    result = h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED", reason="tasks failed to start"), None)

    assert result["outcome"] == "failed"
    assert _metric_names(clients["cloudwatch"]) == [h.METRIC_DEPLOYMENT_FAILED]

    published = clients["sns"].published[0]
    assert "FAILED" in published["Subject"]
    assert "bgd-us-east-1-prod-api" in published["Message"]
    assert "tasks failed to start" in published["Message"]


def test_a_rollback_is_counted_once_and_never_also_as_a_failure(clients):
    # D8. If ECS emits both a rollback event and a FAILED event for the same
    # deployment — likely, and unconfirmable offline — emitting both here would
    # double the change-failure-rate numerator. Each event yields one outcome.
    h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED", reason="rolling back to revision 4"), None)

    assert _metric_names(clients["cloudwatch"]) == [h.METRIC_DEPLOYMENT_ROLLED_BACK]
    assert h.METRIC_DEPLOYMENT_FAILED not in _metric_names(clients["cloudwatch"])


def test_a_rollback_is_detected_from_the_event_name_too(clients):
    # The reason string is free text and may not mention it; the event name may.
    # Either is enough, because missing a rollback is the failure this phase's
    # whole rollback story rests on.
    h.handler(_ecs("SERVICE_DEPLOYMENT_ROLLBACK_IN_PROGRESS"), None)

    assert _metric_names(clients["cloudwatch"]) == [h.METRIC_DEPLOYMENT_ROLLED_BACK]


def test_the_metric_carries_the_environment_dimension(clients):
    h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED"), None)

    dimensions = clients["cloudwatch"].puts[0]["MetricData"][0]["Dimensions"]
    assert dimensions == [{"Name": "Environment", "Value": "prod"}]


def test_an_alert_without_a_topic_arn_logs_rather_than_raising(clients, monkeypatch, caplog):
    # D9 again: a missing topic is a misconfiguration, but raising would retry
    # and alarm, and the alarm's own delivery path is the topic that is missing.
    monkeypatch.delenv("BGD_ALERT_TOPIC_ARN", raising=False)

    h.handler(_ecs("SERVICE_DEPLOYMENT_FAILED"), None)

    assert clients["sns"].published == []
    assert "BGD_ALERT_TOPIC_ARN" in caplog.text
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd lambdas && ../app/.venv/bin/python -m pytest tests/test_release_metrics.py -v --no-cov`
Expected: FAIL — the completed/failed/rollback tests all report `handled` false and no metrics, because `_handle_ecs` is still the Task 1 stub.

- [ ] **Step 3: Implement `_put`, `_alert` and `_handle_ecs`**

```python
def _put(metric_name: str, value: float, unit: str, dimensions: dict[str, str]) -> None:
    """One datapoint. Raises if CloudWatch refuses — see the module docstring."""
    _client("cloudwatch").put_metric_data(
        Namespace=_namespace(),
        MetricData=[
            {
                "MetricName": metric_name,
                "Value": value,
                "Unit": unit,
                # Sorted so two invocations with the same dimensions produce the
                # same list. CloudWatch treats dimension sets as unordered, but
                # a stable order makes the log line and the test comparable.
                "Dimensions": [
                    {"Name": name, "Value": val} for name, val in sorted(dimensions.items())
                ],
            }
        ],
    )
    LOGGER.info("metric %s=%s %s %s", metric_name, value, unit, dimensions)


def _alert(subject: str, message: str) -> None:
    topic_arn = os.environ.get("BGD_ALERT_TOPIC_ARN")
    if not topic_arn:
        LOGGER.error("BGD_ALERT_TOPIC_ARN is not set; this alert is lost: %s", subject)
        return

    # Subject is capped at 100 characters by SNS and a longer one is rejected
    # outright, which would turn a deployment failure into a collector failure.
    _client("sns").publish(TopicArn=topic_arn, Subject=subject[:100], Message=message)
    LOGGER.info("alert published subject=%s", subject)


def _service_name(event: dict) -> str:
    """The service the event is about, from the resource ARN's last segment."""
    resources = event.get("resources") or []
    return resources[0].rsplit("/", 1)[-1] if resources else "unknown"


def _deployment_console_url(event: dict) -> str:
    region = event.get("region", "us-east-1")
    resources = event.get("resources") or []
    if not resources:
        return ""
    cluster, service = resources[0].split("/")[-2:]
    return (
        f"https://{region}.console.aws.amazon.com/ecs/v2/clusters/{cluster}"
        f"/services/{service}/deployments?region={region}"
    )


def _handle_ecs(event: dict) -> dict[str, object]:
    """One ECS deployment event to at most one outcome metric.

    Checked in this order — rollback, failed, succeeded — because a rollback
    event may also be shaped like a failure and each event must yield exactly
    one outcome. Plan D8.
    """
    detail = event.get("detail") or {}
    event_name = (detail.get("eventName") or "").upper()
    reason = detail.get("reason") or ""
    service = _service_name(event)
    dimensions = {"Environment": _environment()}

    if "ROLLBACK" in event_name or "rollback" in reason.lower():
        _put(METRIC_DEPLOYMENT_ROLLED_BACK, 1, "Count", dimensions)
        _alert(
            f"[bgd] Production deployment ROLLED BACK — {service}",
            f"ECS rolled production back.\n\nevent: {event_name}\nreason: {reason}\n"
            f"deployment: {detail.get('deploymentId', 'unknown')}\n\n"
            f"{_deployment_console_url(event)}\n",
        )
        return {"handled": True, "outcome": "rolled_back"}

    if event_name in FAILED_EVENTS:
        _put(METRIC_DEPLOYMENT_FAILED, 1, "Count", dimensions)
        _alert(
            f"[bgd] Production deployment FAILED — {service}",
            f"A production deployment failed.\n\nevent: {event_name}\nreason: {reason}\n"
            f"deployment: {detail.get('deploymentId', 'unknown')}\n\n"
            f"{_deployment_console_url(event)}\n",
        )
        return {"handled": True, "outcome": "failed"}

    if event_name in SUCCEEDED_EVENTS:
        # Before the success is written, and the order is load-bearing. Plan D7.
        _emit_recovery_time(_now(), dimensions)
        _put(METRIC_DEPLOYMENT_SUCCEEDED, 1, "Count", dimensions)
        return {"handled": True, "outcome": "succeeded"}

    LOGGER.info("ignoring ECS eventName=%s", event_name or "<absent>")
    return {"handled": False, "eventName": event_name}
```

`_handle_ecs` calls `_emit_recovery_time`, which Task 4 implements. Add it as a stub now, so this task's tests do not depend on unwritten code:

```python
def _emit_recovery_time(now: datetime, dimensions: dict[str, str]) -> None:
    # Task 4. Deliberately a no-op rather than absent: _handle_ecs already calls
    # it at the one point in the sequence where it has to run (plan D7), so the
    # ordering is established by the task that can be tested for it.
    return None
```

- [ ] **Step 4: Run and confirm green**

Run: `cd lambdas && ../app/.venv/bin/python -m pytest tests/test_release_metrics.py -v --no-cov`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lambdas/release_metrics/handler.py lambdas/tests/test_release_metrics.py
git commit -m "feat(lambdas): deployment outcomes, with a rollback counted once"
```

---

### Task 3: Pipeline outcomes — the failure alert and lead time

**Files:**
- Modify: `lambdas/release_metrics/handler.py`
- Modify: `lambdas/tests/test_release_metrics.py`

**Interfaces:**
- Consumes: `_put`, `_alert`, `_client`, `_now` (Tasks 1–2).
- Produces: `_handle_codepipeline(event: dict) -> dict[str, object]`; `_release_started_at(pipeline: str, execution_id: str) -> tuple[datetime | None, str]`; `_emit_lead_time(pipeline: str, execution_id: str, now: datetime) -> None`.

- [ ] **Step 1: Write the failing pipeline tests**

Append to `lambdas/tests/test_release_metrics.py`:

```python
class FakeCodePipeline:
    def __init__(self, execution=None, summaries=None):
        self._execution = execution if execution is not None else {}
        self._summaries = summaries or []

    def get_pipeline_execution(self, **kwargs):
        self.get_kwargs = kwargs
        return {"pipelineExecution": self._execution}

    def list_pipeline_executions(self, **kwargs):
        self.list_kwargs = kwargs
        return {"pipelineExecutionSummaries": self._summaries}


def _pipeline_event(state, pipeline="bgd-us-east-1-app-pipeline", execution_id="exec-1"):
    return {
        "source": "aws.codepipeline",
        "region": "us-east-1",
        "detail": {"pipeline": pipeline, "state": state, "execution-id": execution_id},
    }


def test_a_failed_pipeline_is_counted_per_pipeline_and_emails(clients):
    result = h.handler(_pipeline_event("FAILED", pipeline="bgd-us-east-1-infra-pipeline"), None)

    assert result["outcome"] == "failed"
    datum = clients["cloudwatch"].puts[0]["MetricData"][0]
    assert datum["MetricName"] == h.METRIC_PIPELINE_FAILED
    # PipelineName, not Environment: this metric is about the pipeline, and the
    # infra pipeline is not an environment. Plan D5.
    assert datum["Dimensions"] == [
        {"Name": "PipelineName", "Value": "bgd-us-east-1-infra-pipeline"}
    ]
    assert "bgd-us-east-1-infra-pipeline" in clients["sns"].published[0]["Subject"]


def test_lead_time_uses_the_commit_timestamp_when_the_api_supplies_one(clients, monkeypatch):
    committed = datetime(2026, 8, 30, 10, 0, 0, tzinfo=UTC)  # two hours before _now
    monkeypatch.setitem(
        h._CLIENTS,
        "codepipeline",
        FakeCodePipeline(execution={"artifactRevisions": [{"created": committed}]}),
    )

    h.handler(_pipeline_event("SUCCEEDED"), None)

    datum = clients["cloudwatch"].puts[0]["MetricData"][0]
    assert datum["MetricName"] == h.METRIC_LEAD_TIME
    assert datum["Unit"] == "Seconds"
    assert datum["Value"] == 7200.0


def test_lead_time_falls_back_to_the_execution_start_time(clients, monkeypatch, caplog):
    # F4: whether CodeConnections populates artifactRevisions[].created cannot be
    # confirmed offline. Absent it, the number is merge-to-production rather than
    # commit-to-production, and the log says which.
    started = datetime(2026, 8, 30, 11, 30, 0, tzinfo=UTC)
    monkeypatch.setitem(
        h._CLIENTS,
        "codepipeline",
        FakeCodePipeline(
            execution={"artifactRevisions": [{"revisionId": "abc123"}]},
            summaries=[{"pipelineExecutionId": "exec-1", "startTime": started}],
        ),
    )

    h.handler(_pipeline_event("SUCCEEDED"), None)

    assert clients["cloudwatch"].puts[0]["MetricData"][0]["Value"] == 1800.0
    assert "lead_time_basis=merge" in caplog.text


def test_no_lead_time_is_emitted_when_neither_timestamp_exists(clients, monkeypatch):
    monkeypatch.setitem(h._CLIENTS, "codepipeline", FakeCodePipeline())

    h.handler(_pipeline_event("SUCCEEDED"), None)

    assert clients["cloudwatch"].puts == []


def test_the_infra_pipeline_succeeding_produces_no_lead_time(clients, monkeypatch):
    # Lead time is commit-to-PRODUCTION. The infra pipeline deploys layers, not
    # the application, and counting it would measure a different thing under the
    # same name. Plan D6.
    monkeypatch.setitem(h._CLIENTS, "codepipeline", FakeCodePipeline())

    result = h.handler(_pipeline_event("SUCCEEDED", pipeline="bgd-us-east-1-infra-pipeline"), None)

    assert result["handled"] is False
    assert clients["cloudwatch"].puts == []
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd lambdas && ../app/.venv/bin/python -m pytest tests/test_release_metrics.py -k pipeline -v --no-cov`
Expected: FAIL — no metrics written, `_handle_codepipeline` is still the Task 1 stub.

- [ ] **Step 3: Implement the pipeline path**

```python
def _pipeline_console_url(event: dict, pipeline: str, execution_id: str) -> str:
    region = event.get("region", "us-east-1")
    return (
        f"https://{region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/"
        f"{pipeline}/executions/{execution_id}?region={region}"
    )


def _release_started_at(pipeline: str, execution_id: str) -> tuple[datetime | None, str]:
    """When the change that just reached production was made.

    Preferred: the source revision's commit timestamp, which makes the metric
    genuinely commit-to-production. Whether CodePipeline populates it for a
    CodeConnections source cannot be confirmed offline (plan F4), so the fallback
    is the execution's own start time — merge-to-production. The caller logs
    which basis was used; the metric is emitted either way, because a lead-time
    series that silently stops when an API field is absent is worse than one
    whose basis is written beside it.
    """
    client = _client("codepipeline")

    execution = client.get_pipeline_execution(
        pipelineName=pipeline, pipelineExecutionId=execution_id
    ).get("pipelineExecution", {})

    for revision in execution.get("artifactRevisions") or []:
        created = revision.get("created")
        if created is not None:
            return created, "commit"

    summaries = client.list_pipeline_executions(pipelineName=pipeline, maxResults=100)
    for summary in summaries.get("pipelineExecutionSummaries") or []:
        if summary.get("pipelineExecutionId") == execution_id and summary.get("startTime"):
            return summary["startTime"], "merge"

    return None, "unavailable"


def _emit_lead_time(pipeline: str, execution_id: str, now: datetime) -> None:
    started_at, basis = _release_started_at(pipeline, execution_id)

    if started_at is None:
        LOGGER.warning(
            "lead_time_basis=unavailable execution=%s; no lead time emitted", execution_id
        )
        return

    seconds = (now - started_at).total_seconds()
    LOGGER.info("lead_time_basis=%s seconds=%s execution=%s", basis, seconds, execution_id)
    _put(METRIC_LEAD_TIME, seconds, "Seconds", {"Environment": _environment()})


def _handle_codepipeline(event: dict) -> dict[str, object]:
    detail = event.get("detail") or {}
    pipeline = detail.get("pipeline") or "unknown"
    state = detail.get("state")
    execution_id = detail.get("execution-id")

    if state == "FAILED":
        _put(METRIC_PIPELINE_FAILED, 1, "Count", {"PipelineName": pipeline})
        _alert(
            f"[bgd] Pipeline FAILED — {pipeline}",
            f"A pipeline execution failed.\n\nexecution: {execution_id}\n\n"
            f"{_pipeline_console_url(event, pipeline, execution_id)}\n",
        )
        return {"handled": True, "outcome": "failed"}

    if state == "SUCCEEDED" and pipeline == os.environ.get("BGD_APP_PIPELINE"):
        _emit_lead_time(pipeline, execution_id, _now())
        return {"handled": True, "outcome": "succeeded"}

    LOGGER.info("ignoring pipeline=%s state=%s", pipeline, state)
    return {"handled": False, "state": state}
```

- [ ] **Step 4: Run and confirm green**

Run: `cd lambdas && ../app/.venv/bin/python -m pytest tests/test_release_metrics.py -v --no-cov`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lambdas/release_metrics/handler.py lambdas/tests/test_release_metrics.py
git commit -m "feat(lambdas): pipeline failure alerts and commit-to-production lead time"
```

---

### Task 4: MTTR, and the call ordering that makes it stateless

**Files:**
- Modify: `lambdas/release_metrics/handler.py`
- Modify: `lambdas/tests/test_release_metrics.py`

**Interfaces:**
- Consumes: `_client`, `_put`, `_namespace`, `_environment` (Tasks 1–2).
- Produces: `_emit_recovery_time(now: datetime, dimensions: dict[str, str]) -> None`, replacing the Task 2 placeholder.

- [ ] **Step 1: Write the failing MTTR tests**

```python
def _series(metric_id, timestamps):
    return {"Id": metric_id, "Timestamps": list(timestamps), "Values": [1.0] * len(timestamps)}


def test_a_success_after_a_failure_emits_recovery_time(clients, monkeypatch):
    failed_at = datetime(2026, 8, 30, 11, 0, 0, tzinfo=UTC)  # one hour before _now
    monkeypatch.setattr(
        h,
        "_CLIENTS",
        {
            "cloudwatch": FakeCloudWatch(
                {"MetricDataResults": [_series("failed", [failed_at]), _series("succeeded", [])]}
            ),
            "sns": FakeSNS(),
        },
    )

    h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    names = _metric_names(h._CLIENTS["cloudwatch"])
    assert names == [h.METRIC_RECOVERY_TIME, h.METRIC_DEPLOYMENT_SUCCEEDED]
    assert h._CLIENTS["cloudwatch"].puts[0]["MetricData"][0]["Value"] == 3600.0


def test_the_lookback_runs_before_the_success_is_written(clients, monkeypatch):
    # Plan D7, and the single most breakable line in this handler. Written after,
    # the query finds the success just published, concludes it is the newest
    # datapoint, and every recovery measures zero — a flat MTTR line that looks
    # like excellent operations.
    failed_at = datetime(2026, 8, 30, 11, 0, 0, tzinfo=UTC)
    fake = FakeCloudWatch(
        {"MetricDataResults": [_series("failed", [failed_at]), _series("succeeded", [])]}
    )
    monkeypatch.setattr(h, "_CLIENTS", {"cloudwatch": fake, "sns": FakeSNS()})

    h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    assert fake.calls.index("get_metric_data") < fake.calls.index("put_metric_data")


def test_a_success_with_no_prior_failure_emits_no_recovery_time(clients):
    h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    assert _metric_names(clients["cloudwatch"]) == [h.METRIC_DEPLOYMENT_SUCCEEDED]


def test_a_second_success_after_the_recovery_emits_nothing_further(clients, monkeypatch):
    # The failure was already followed by a success, so this one recovers from
    # nothing. Without this branch every deployment after an outage reports an
    # ever-growing MTTR.
    failed_at = datetime(2026, 8, 30, 11, 0, 0, tzinfo=UTC)
    recovered_at = datetime(2026, 8, 30, 11, 30, 0, tzinfo=UTC)
    fake = FakeCloudWatch(
        {
            "MetricDataResults": [
                _series("failed", [failed_at]),
                _series("succeeded", [recovered_at]),
            ]
        }
    )
    monkeypatch.setattr(h, "_CLIENTS", {"cloudwatch": fake, "sns": FakeSNS()})

    h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    assert _metric_names(fake) == [h.METRIC_DEPLOYMENT_SUCCEEDED]


def test_the_lookback_window_is_configurable(clients, monkeypatch):
    monkeypatch.setenv("BGD_MTTR_LOOKBACK_DAYS", "7")
    fake = FakeCloudWatch()
    monkeypatch.setattr(h, "_CLIENTS", {"cloudwatch": fake, "sns": FakeSNS()})

    h.handler(_ecs("SERVICE_DEPLOYMENT_COMPLETED"), None)

    window = fake.get_metric_data_kwargs
    assert (window["EndTime"] - window["StartTime"]).days == 7
    assert window["ScanBy"] == "TimestampDescending"
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd lambdas && ../app/.venv/bin/python -m pytest tests/test_release_metrics.py -k recovery -v --no-cov`
Expected: FAIL — `_emit_recovery_time` is the Task 2 placeholder and writes nothing.

- [ ] **Step 3: Implement the lookback**

Extend the import at the top of the module — `timedelta` was deliberately left
out in Task 1, because ruff's `F401` fails an import nothing uses yet:

```python
from datetime import UTC, datetime, timedelta
```

Then replace the Task 2 stub:

```python
def _emit_recovery_time(now: datetime, dimensions: dict[str, str]) -> None:
    """Emit RecoveryTimeSeconds when this success ends an outage.

    Stateless by construction: the metric store is the state store. One query
    returns both series newest-first; if the most recent failure has no success
    after it, this success is the recovery.

    MUST be called before DeploymentSucceeded is written for this event, or the
    query finds the datapoint it is about to create. Plan D7.
    """
    lookback_days = int(os.environ.get("BGD_MTTR_LOOKBACK_DAYS", DEFAULT_MTTR_LOOKBACK_DAYS))
    metric_dimensions = [
        {"Name": name, "Value": value} for name, value in sorted(dimensions.items())
    ]

    def query(query_id: str, metric_name: str) -> dict:
        return {
            "Id": query_id,
            "MetricStat": {
                "Metric": {
                    "Namespace": _namespace(),
                    "MetricName": metric_name,
                    "Dimensions": metric_dimensions,
                },
                # 60s to match the resolution these are written at; anything
                # coarser rounds a recovery to the nearest bucket.
                "Period": 60,
                "Stat": "Sum",
            },
        }

    response = _client("cloudwatch").get_metric_data(
        StartTime=now - timedelta(days=lookback_days),
        EndTime=now,
        # Newest first, so Timestamps[0] of each series is the latest datapoint
        # and neither series has to be sorted here.
        ScanBy="TimestampDescending",
        MetricDataQueries=[
            query("failed", METRIC_DEPLOYMENT_FAILED),
            query("succeeded", METRIC_DEPLOYMENT_SUCCEEDED),
        ],
    )

    latest = {
        result["Id"]: (result["Timestamps"][0] if result.get("Timestamps") else None)
        for result in response.get("MetricDataResults", [])
    }
    last_failure, last_success = latest.get("failed"), latest.get("succeeded")

    if last_failure is None:
        LOGGER.info("no failure in the last %s days; this success recovers nothing", lookback_days)
        return

    if last_success is not None and last_success >= last_failure:
        LOGGER.info("the last failure was already followed by a success; not a recovery")
        return

    _put(METRIC_RECOVERY_TIME, (now - last_failure).total_seconds(), "Seconds", dimensions)
```

- [ ] **Step 4: Run the whole Lambda suite with the coverage gate**

Run: `make test-lambdas`
Expected: PASS, with both packages at or above 95%. If `release_metrics` is below, the uncovered lines name themselves — add the test, do not lower the gate.

- [ ] **Step 5: Lint both trees**

Run: `make lint`
Expected: clean. `release_metrics/handler.py` must pass the same `E,F,I,N,UP,B,A,C4,SIM,RUF,S,T20` set the hook handler does.

- [ ] **Step 6: Commit**

```bash
git add lambdas/release_metrics/handler.py lambdas/tests/test_release_metrics.py
git commit -m "feat(lambdas): MTTR from the metric store, queried before the success is written"
```

---

### Task 5: Foundation variables, locals and the derived production identifiers

The Terraform half starts here. Nothing in this task creates a resource — it establishes the names every later task interpolates, including the four `foundation` reconstructs rather than reads (D2).

**Files:**
- Modify: `infra/foundation/variables.tf`
- Modify: `infra/foundation/locals.tf`

**Interfaces:**
- Produces: `var.metric_namespace`, `var.mttr_lookback_days`, `var.collector_log_retention_days`; `local.observability` with keys `collector_name`, `prod_cluster_name`, `prod_service_name`, `prod_service_arn`, `prod_alb_name`, `staging_alb_name`, `prod_table_names`, `dashboard_name`.

- [ ] **Step 1: Add the three variables**

Append to `infra/foundation/variables.tf`, under a Phase 9 banner comment matching the Phase 8 one already there:

```hcl
variable "metric_namespace" {
  description = <<-EOT
    CloudWatch namespace the collector writes release metrics under.

    A variable rather than a constant because it is named in three places that
    must agree — the collector's environment, the IAM condition that confines
    PutMetricData to it, and every dashboard widget — and a namespace typo is
    silent: the metrics land somewhere real and the dashboard stays empty.
  EOT
  type        = string
  default     = "ReleaseMetrics"
}

variable "mttr_lookback_days" {
  description = <<-EOT
    How far back the collector looks for an unrecovered failure when a
    deployment succeeds (plan D7).

    Thirty days. Long enough that a failure left over a holiday is still found;
    short enough that GetMetricData stays one cheap call. A recovery older than
    this is not reported, which is the right answer — an MTTR of five weeks
    describes a project that was not being worked on.
  EOT
  type        = number
  default     = 30
}

variable "collector_log_retention_days" {
  description = <<-EOT
    Retention on the collector's log group.

    Longer than the hooks' 14 days, because these lines are the audit trail
    behind every number on the dashboard — which event arrived, which basis the
    lead time used, which event names ECS really emits (plan F3). Matching
    var.pipeline_log_retention_days at 30 keeps the two pipeline-adjacent log
    families on one number.
  EOT
  type        = number
  default     = 30
}
```

- [ ] **Step 2: Add the observability locals**

Append to `infra/foundation/locals.tf`:

```hcl
# ---------------------------------------------------------------------------
# Phase 9 — the observability plane
# ---------------------------------------------------------------------------

locals {
  # Production is addressed BY NAME, never through remote state, and that is
  # forced rather than chosen. infra/environments/prod already reads this
  # layer's state; reading prod's back would make each layer depend on the
  # other — and Terraform would not report it as a cycle, because the two are
  # separate state files read at plan time. The symptom would be this layer's
  # plan failing to read a state file `make teardown` emptied, in the layer
  # whose whole purpose is surviving teardown. Plan §D2 and §F1.
  #
  # Every segment below is this layer's own convention variables. The two names
  # that cross the boundary are pinned as string literals by
  # infra/environments/prod/tests/outputs.tftest.hcl, so a rename over there
  # fails there rather than silently orphaning the rule over here.
  observability = {
    collector_name = "${local.name_prefix}-release-metrics"
    dashboard_name = "${local.name_prefix}-release"

    prod_cluster_name = "${local.name_prefix}-prod-cluster"
    prod_service_name = "${local.name_prefix}-prod-api"

    prod_service_arn = join("", [
      "arn:aws:ecs:${var.region}:${var.account_id}:service/",
      "${local.name_prefix}-prod-cluster/${local.name_prefix}-prod-api",
    ])

    # Load balancer NAMES, not ARNs. The CloudWatch LoadBalancer dimension is
    # app/<name>/<16 hex characters>, and the hex is assigned at creation — the
    # one dimension in this dashboard the convention cannot supply. Widgets
    # search on these instead, which also survives a teardown/rebuild giving
    # the load balancer a new suffix. Plan §D17.
    prod_alb_name    = "${local.name_prefix}-prod-alb"
    staging_alb_name = "${local.name_prefix}-staging-alb"

    prod_table_names = [
      "${local.name_prefix}-prod-accounts",
      "${local.name_prefix}-prod-transactions",
    ]
  }
}
```

- [ ] **Step 3: Confirm the layer still validates**

Run: `./scripts/tf.sh validate foundation`
Expected: `Success! The configuration is valid.` No resource has been added, so nothing else can have changed.

- [ ] **Step 4: Commit**

```bash
git add infra/foundation/variables.tf infra/foundation/locals.tf
git commit -m "feat(infra): observability variables and the derived production identifiers"
```

---

### Task 6: The collector function, its policy, and the module's re-examined skips

**Files:**
- Create: `infra/foundation/observability.tf` (the function and the policy only; the rules arrive in Task 7)
- Create: `infra/foundation/tests/observability.tftest.hcl`
- Modify: `infra/modules/lambda/main.tf` (the `CKV_AWS_116` reason)

**Interfaces:**
- Consumes: `local.observability`, `var.metric_namespace`, `var.mttr_lookback_days`, `var.collector_log_retention_days` (Task 5); `aws_sns_topic.alerts`, `aws_codepipeline.infra`, `aws_codepipeline.app` (Phases 3, 7, 8).
- Produces: `module.release_metrics` with the module's outputs; `aws_iam_role_policy.release_metrics`.

- [ ] **Step 1: Write the failing test file**

Create `infra/foundation/tests/observability.tftest.hcl` with the mocks and the first four runs. The mock block mirrors `pipeline_iam.tftest.hcl`'s, and every mock is present because omitting it produced a hard error rather than because it looked tidy:

```hcl
# The collector, its permissions, the two rules that feed it and the alarm that
# watches it.
#
# `command = apply` throughout, for the reason pipeline_iam.tftest.hcl records:
# every policy here interpolates a computed ARN — the topic's, both pipelines'
# — and a computed attribute is unknown under `command = plan`, which makes the
# whole jsonencode unknown and the condition unevaluable. Against a mocked
# provider apply creates nothing and needs no credentials.
#
# The archive provider is NOT mocked, deliberately. mock_provider "aws" leaves
# it alone, so this really builds the collector's zip from
# lambdas/release_metrics/handler.py — a wrong source_file fails here rather
# than at the first invocation. Phase 6 §F4, reused; plan §F12.
mock_provider "aws" {
  mock_resource "aws_acm_certificate" {
    defaults = {
      domain_validation_options = [
        {
          domain_name           = "api.carloscloudengineer.com"
          resource_record_name  = "_mock.api.carloscloudengineer.com."
          resource_record_type  = "CNAME"
          resource_record_value = "_mock.acm-validations.aws."
        },
        {
          domain_name           = "staging-api.carloscloudengineer.com"
          resource_record_name  = "_mock.staging-api.carloscloudengineer.com."
          resource_record_type  = "CNAME"
          resource_record_value = "_mock.acm-validations.aws."
        },
      ]
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:590184028094:bgd-us-east-1-alerts" }
  }
}

run "the_collector_is_packaged_and_runs_on_the_pinned_runtime" {
  command = apply

  assert {
    condition     = module.release_metrics.function_name == "bgd-us-east-1-release-metrics"
    error_message = "the collector takes no <env> segment: it is a shared resource (convention §2)"
  }

  assert {
    condition     = module.release_metrics.runtime == "python3.14"
    error_message = "the collector must run the same interpreter as the container and the hooks"
  }

  assert {
    condition     = contains(module.release_metrics.architectures, "arm64")
    error_message = "arm64, matching the hooks and the container"
  }

  # The four the handler reads. A missing one is not an apply failure — it is a
  # collector that writes to the default namespace, or one that cannot find the
  # topic and logs the alert away. Plan §D9's own error path.
  assert {
    condition = alltrue([
      module.release_metrics.environment_variables["BGD_METRIC_NAMESPACE"] == "ReleaseMetrics",
      module.release_metrics.environment_variables["BGD_ENVIRONMENT"] == "prod",
      module.release_metrics.environment_variables["BGD_APP_PIPELINE"] == aws_codepipeline.app.name,
      module.release_metrics.environment_variables["BGD_ALERT_TOPIC_ARN"] != "",
    ])
    error_message = "the collector's environment must name the namespace, the environment, the app pipeline and the topic"
  }
}

run "the_collector_may_write_only_its_own_namespace" {
  command = apply

  # The one least-privilege lever PutMetricData offers. Without the condition
  # this role can overwrite any metric in the account, including the AWS/ECS
  # series the bake alarms read. Plan §F5.
  assert {
    condition = jsondecode(aws_iam_role_policy.release_metrics.policy).Statement[0].Condition.StringEquals["cloudwatch:namespace"] == var.metric_namespace
    error_message = "PutMetricData must be confined to the release metrics namespace by condition"
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.release_metrics.policy).Statement :
      !contains(statement.Action, "cloudwatch:PutMetricData") || contains(keys(statement), "Condition")
    ])
    error_message = "no unconditioned PutMetricData statement may exist"
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.release_metrics.policy).Statement :
      !contains(statement.Action, "sns:Publish") || statement.Resource == [aws_sns_topic.alerts.arn]
    ])
    error_message = "sns:Publish must name the alert topic and nothing else"
  }

  # The collector reads two pipelines' executions to compute lead time. It has
  # no business starting, stopping or approving one.
  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.release_metrics.policy).Statement :
      alltrue([
        for action in statement.Action :
        !startswith(action, "codepipeline:") || contains([
          "codepipeline:GetPipelineExecution",
          "codepipeline:ListPipelineExecutions",
        ], action)
      ])
    ])
    error_message = "the collector reads pipeline executions; it must not be able to act on one"
  }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `./scripts/tf.sh test foundation`
Expected: FAIL — `A managed resource "aws_iam_role_policy" "release_metrics" has not been declared`, and a reference to an undeclared module.

- [ ] **Step 3: Create the function and its policy**

Create `infra/foundation/observability.tf`, beginning with the file's own orientation comment and these two resources:

```hcl
# The observability plane: one collector, two rules, one alarm.
#
# It lives in this layer and not in prod, and that is forced rather than
# preferred — see plan §D2 and §F1. The short version: prod already reads this
# layer's remote state, so the mirror would be a cycle Terraform does not detect;
# and the metric history is the deliverable, so it must outlive `make teardown`.
#
# What prod owns is four lines: alarm_actions on the bake alarms, which can only
# be set where the alarm is.

module "release_metrics" {
  source = "../modules/lambda"

  function_name      = local.observability.collector_name
  source_file        = "${path.module}/../../lambdas/release_metrics/handler.py"
  log_retention_days = var.collector_log_retention_days

  # 256, against the hooks' 128. Not because the work is heavy — it is four API
  # calls — but because importing boto3 on a cold start is the whole of this
  # function's runtime, and memory scales CPU. The difference is fractions of a
  # cent a month at this invocation rate and a second off every cold start.
  memory_size_mb = 256

  # 30, against the hooks' 60. Nothing here waits on a five-minute bake: the
  # slowest path is get_metric_data plus put_metric_data. A collector still
  # running after thirty seconds is stuck, and a stuck async invocation retries
  # and then fires the errors alarm, which is the behaviour wanted.
  timeout_seconds = 30

  # Everything the handler reads. It has defaults for the first three, so a
  # missing one is silent rather than fatal — which is why they are asserted in
  # tests/observability.tftest.hcl rather than trusted.
  environment = {
    BGD_METRIC_NAMESPACE   = var.metric_namespace
    BGD_ENVIRONMENT        = "prod"
    BGD_MTTR_LOOKBACK_DAYS = tostring(var.mttr_lookback_days)
    BGD_ALERT_TOPIC_ARN    = aws_sns_topic.alerts.arn
    BGD_APP_PIPELINE       = aws_codepipeline.app.name
  }
}

# Attached to the role the module created, rather than a role of its own. The
# module's role already carries the one policy every function here needs — write
# to its own log group and nothing else — and a second role would mean the
# function had two, one of which could not be the execution role.
#
# This is where iam-app-pipeline.tf's prediction that "Phase 9 adds a third set"
# turns out to be wrong: it is one policy, not a set, and separating it from the
# function it belongs to would cost a file and gain nothing.
resource "aws_iam_role_policy" "release_metrics" {
  name = "${local.observability.collector_name}-collect-policy"
  role = module.release_metrics.role_name

  # jsonencode rather than aws_iam_policy_document, the rule every IAM file in
  # this project follows: mock_provider mocks the policy-document data source
  # too, so a policy built through it is a random string under test and every
  # assertion on it is vacuous. Phase 5 §F1.
  #
  # Action and Resource are LISTS even at one element, so the test file can use
  # contains() and == without a type check first.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # checkov:skip=CKV_AWS_355:PutMetricData takes no resource ARN — CloudWatch metrics are not resources — so "*" is the only Resource this action accepts. The Condition below is the actual control and it is tighter than a resource scope would be: this role can write the ReleaseMetrics namespace and no other, so a compromised collector cannot overwrite the AWS/ApplicationELB series the bake alarms read.
        Sid       = "PublishReleaseMetricsOnly"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = ["*"]
        Condition = { StringEquals = { "cloudwatch:namespace" = var.metric_namespace } }
      },
      {
        # checkov:skip=CKV_AWS_355:GetMetricData takes no resource ARN either, and unlike PutMetricData it supports no namespace condition key — the read is account-wide or it does not happen. What it buys is MTTR with no state store (plan D7): the metric store is the state store, so there is no DynamoDB table, no S3 marker and no second thing to keep in step. The exposure is read access to metric values in an account that holds one project.
        Sid      = "ReadBackTheFailureAndSuccessSeries"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = ["*"]
      },
      {
        Sid      = "AlertOnFailuresAndRollbacks"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.alerts.arn]
      },
      {
        # Read, never act. Lead time needs to know when the change was made;
        # nothing here needs to start, retry, stop or approve an execution, and
        # a collector that could would be a strange thing to have subscribed to
        # pipeline events.
        Sid    = "ReadTheTwoPipelinesExecutions"
        Effect = "Allow"
        Action = ["codepipeline:GetPipelineExecution", "codepipeline:ListPipelineExecutions"]
        Resource = [
          aws_codepipeline.infra.arn,
          aws_codepipeline.app.arn,
        ]
      },
    ]
  })
}
```

- [ ] **Step 4: Rewrite the module's `CKV_AWS_116` reason**

In `infra/modules/lambda/main.tf`, replace the `CKV_AWS_116` skip line. The old reason — *"these are invoked SYNCHRONOUSLY by the ECS deployment controller … There is no dropped event for a DLQ to catch"* — is false for the collector, and leaving it would mean a suppression whose stated reason does not apply to one of the functions it suppresses.

New text:

```
# checkov:skip=CKV_AWS_116:a dead letter queue captures asynchronous invocations that failed after retries, and this module now packages both shapes. The three lifecycle hooks are invoked SYNCHRONOUSLY by the ECS deployment controller, which is itself the consumer of the result — there is no dropped event for a queue to catch. Phase 9's collector IS invoked asynchronously, by EventBridge, so dropped invocations are real; it still takes no queue, because nothing in this project polls one. A DLQ here would accumulate events no process ever reads while suggesting to the next reader that they are handled. What handles them is the collector's own Errors alarm, which publishes to the alert topic within a minute, plus retry_policy on both EventBridge targets bounding delivery to three attempts over five minutes rather than the 185-attempt, 24-hour default. Phase 9 plan §D11.
```

Update the block comment above `aws_lambda_function` too: the sentence beginning "PHASE 9 MUST RE-EXAMINE THEM" becomes a record that it did, naming which one changed and why the other five did not.

- [ ] **Step 5: Run the test file and confirm green**

Run: `./scripts/tf.sh test foundation`
Expected: PASS, including the runs from the other six suites in the directory.

- [ ] **Step 6: Commit**

```bash
git add infra/foundation/observability.tf infra/foundation/tests/observability.tftest.hcl infra/modules/lambda/main.tf
git commit -m "feat(infra): the release metrics collector and its narrowed policy"
```

---

### Task 7: Two EventBridge rules, their targets, permissions and retry policy

**Files:**
- Modify: `infra/foundation/observability.tf`
- Modify: `infra/foundation/tests/observability.tftest.hcl`

**Interfaces:**
- Consumes: `module.release_metrics`, `local.observability`, `aws_codepipeline.infra`, `aws_codepipeline.app`.
- Produces: `aws_cloudwatch_event_rule.pipeline_executions`, `aws_cloudwatch_event_rule.prod_deployments`, their targets and `aws_lambda_permission` resources.

- [ ] **Step 1: Write the failing rule tests**

Append to `infra/foundation/tests/observability.tftest.hcl`:

```hcl
run "the_pipeline_rule_watches_both_pipelines_and_only_the_terminal_states" {
  command = apply

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.pipeline_executions.event_pattern)["detail-type"] == ["CodePipeline Pipeline Execution State Change"]
    error_message = "the pipeline rule must match execution state changes, not stage or action ones"
  }

  assert {
    condition = toset(jsondecode(aws_cloudwatch_event_rule.pipeline_executions.event_pattern).detail.pipeline) == toset([
      aws_codepipeline.infra.name,
      aws_codepipeline.app.name,
    ])
    error_message = "both pipelines, named rather than wildcarded"
  }

  # SUCCEEDED for lead time and MTTR, FAILED for the alert. STARTED and
  # SUPERSEDED would invoke the collector for nothing — and unlike the ECS
  # rule there is no unknown vocabulary here to leave room for, because
  # CodePipeline's execution states are a documented closed set.
  assert {
    condition = toset(jsondecode(aws_cloudwatch_event_rule.pipeline_executions.event_pattern).detail.state) == toset(["SUCCEEDED", "FAILED"])
    error_message = "the pipeline rule matches SUCCEEDED and FAILED only"
  }
}

run "the_deployment_rule_names_the_production_service_and_does_not_filter_event_names" {
  command = apply

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.prod_deployments.event_pattern).resources == [
      "arn:aws:ecs:us-east-1:590184028094:service/bgd-us-east-1-prod-cluster/bgd-us-east-1-prod-api"
    ]
    error_message = "the deployment rule must name the production service exactly; staging deployments are not release metrics (plan D15)"
  }

  # Plan §D4, and the single assertion most worth having in this file. Which
  # eventName a blue/green rollback produces is a runtime contract with no
  # offline source of truth (§F3). A filter here that guesses wrong makes the
  # rollback this project exists to demonstrate produce no metric and no email,
  # with the rule still looking correct in the console.
  # Asserted against the raw pattern string rather than the decoded object,
  # deliberately. The correct pattern has no `detail` key at all, so
  # jsondecode(...).detail is an error rather than a null — an assertion written
  # that way fails on the configuration it is meant to pass.
  assert {
    condition     = !strcontains(aws_cloudwatch_event_rule.prod_deployments.event_pattern, "eventName")
    error_message = "the deployment rule must not filter on eventName — an unrecognised name has to reach the handler and be logged (plan D4)"
  }
}

run "both_targets_bound_delivery_and_both_permissions_name_their_own_rule" {
  command = apply

  # Plan §F11. Unset, EventBridge retries for 24 hours across 185 attempts: a
  # "deployment failed" email arriving tomorrow, and a broken collector invoked
  # all day.
  assert {
    condition = alltrue([
      for target in [
        aws_cloudwatch_event_target.pipeline_executions,
        aws_cloudwatch_event_target.prod_deployments,
      ] : one(target.retry_policy).maximum_retry_attempts == 2 && one(target.retry_policy).maximum_event_age_in_seconds == 300
    ])
    error_message = "both targets must bound retries to three attempts over five minutes"
  }

  # Crossed source_arns is the failure this catches: both permissions would
  # still apply, both rules would still fire, and nothing would ever report it —
  # until someone removed one rule and the other stopped working.
  assert {
    condition = (
      aws_lambda_permission.pipeline_executions.source_arn == aws_cloudwatch_event_rule.pipeline_executions.arn &&
      aws_lambda_permission.prod_deployments.source_arn == aws_cloudwatch_event_rule.prod_deployments.arn
    )
    error_message = "each permission must be scoped to the rule it exists for"
  }

  assert {
    condition = alltrue([
      for permission in [
        aws_lambda_permission.pipeline_executions,
        aws_lambda_permission.prod_deployments,
      ] : permission.principal == "events.amazonaws.com" && permission.function_name == module.release_metrics.function_name
    ])
    error_message = "both permissions must let EventBridge, and only EventBridge, invoke the collector"
  }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `./scripts/tf.sh test foundation`
Expected: FAIL — four undeclared resources.

- [ ] **Step 3: Add the rules, targets and permissions**

Append to `infra/foundation/observability.tf`:

```hcl
# --- what reaches the collector ----------------------------------------------

resource "aws_cloudwatch_event_rule" "pipeline_executions" {
  name = "${local.name_prefix}-pipeline-executions"
  description = join(" ", [
    "Both pipelines' terminal execution states, for the failure alert and for",
    "lead time. SUCCEEDED and FAILED only: CodePipeline's execution states are",
    "a documented closed set, so unlike the ECS rule there is no unknown",
    "vocabulary to leave room for.",
  ])

  event_pattern = jsonencode({
    source        = ["aws.codepipeline"]
    "detail-type" = ["CodePipeline Pipeline Execution State Change"]
    detail = {
      # Named rather than wildcarded. This account holds one project today; a
      # pattern that matched every pipeline would silently start counting
      # someone else's the day it does not.
      pipeline = [aws_codepipeline.infra.name, aws_codepipeline.app.name]
      state    = ["SUCCEEDED", "FAILED"]
    }
  })
}

resource "aws_cloudwatch_event_rule" "prod_deployments" {
  name = "${local.name_prefix}-prod-deployments"
  description = join(" ", [
    "Every ECS deployment state change on the production service. Deliberately",
    "unfiltered by eventName — which names a blue/green rollback emits is a",
    "runtime contract with no offline source of truth, and a wrong guess would",
    "make rollbacks invisible. Plan D4 and F3.",
  ])

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change"]

    # The service ARN, composed from this layer's own convention variables
    # rather than read from prod's remote state — plan §D2. Staging's service is
    # deliberately absent: staging is built to fail fast, and counting its
    # deployments would inflate frequency and deflate change failure rate at the
    # same time (plan §D15).
    resources = [local.observability.prod_service_arn]
  })
}

resource "aws_cloudwatch_event_target" "pipeline_executions" {
  rule      = aws_cloudwatch_event_rule.pipeline_executions.name
  target_id = "release-metrics"
  arn       = module.release_metrics.function_arn

  # Plan §F11: unset, this is 185 attempts across 24 hours. Three attempts
  # inside five minutes is what an alert is worth, and after that the collector's
  # Errors alarm has already said so.
  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 300
  }
}

resource "aws_cloudwatch_event_target" "prod_deployments" {
  rule      = aws_cloudwatch_event_rule.prod_deployments.name
  target_id = "release-metrics"
  arn       = module.release_metrics.function_arn

  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 300
  }
}

# One permission per rule rather than one covering both. source_arn takes a
# single ARN, and a permission scoped to one rule is what makes "this rule may
# invoke the collector" a statement rather than "EventBridge may".
resource "aws_lambda_permission" "pipeline_executions" {
  statement_id  = "AllowInvocationFromPipelineExecutionsRule"
  action        = "lambda:InvokeFunction"
  function_name = module.release_metrics.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_executions.arn
}

resource "aws_lambda_permission" "prod_deployments" {
  statement_id  = "AllowInvocationFromProdDeploymentsRule"
  action        = "lambda:InvokeFunction"
  function_name = module.release_metrics.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.prod_deployments.arn
}
```

- [ ] **Step 4: Run and confirm green**

Run: `./scripts/tf.sh test foundation`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add infra/foundation/observability.tf infra/foundation/tests/observability.tftest.hcl
git commit -m "feat(infra): two event rules, bounded retries and per-rule invoke permissions"
```

---

### Task 8: The watchdog alarm, and prod's four alarms gaining actions

The one task that touches two layers. It also fails the offline gate on purpose before it passes it (F9).

**Files:**
- Modify: `infra/foundation/observability.tf`
- Modify: `infra/foundation/tests/observability.tftest.hcl`
- Modify: `infra/environments/prod/alarms.tf`
- Modify: `infra/environments/prod/tests/bluegreen.tftest.hcl`

**Interfaces:**
- Consumes: `module.release_metrics`, `aws_sns_topic.alerts`; in `prod`, `local.foundation.alerts_topic_arn`.
- Produces: `aws_cloudwatch_metric_alarm.release_metrics_errors`.

- [ ] **Step 1: Write the failing watchdog test**

Append to `infra/foundation/tests/observability.tftest.hcl`:

```hcl
run "the_collector_is_watched_by_something_that_is_not_the_collector" {
  command = apply

  # Plan §D13. Every other alert in this phase travels through the Lambda, so
  # this is the one that has to work when the Lambda does not.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.release_metrics_errors.namespace == "AWS/Lambda" &&
      aws_cloudwatch_metric_alarm.release_metrics_errors.metric_name == "Errors" &&
      aws_cloudwatch_metric_alarm.release_metrics_errors.dimensions["FunctionName"] == module.release_metrics.function_name
    )
    error_message = "the watchdog must alarm on the collector's own Errors metric"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.release_metrics_errors.alarm_actions == toset([aws_sns_topic.alerts.arn])
    error_message = "the watchdog publishes straight to the topic — its whole point is bypassing the collector"
  }

  # Load-bearing, not cosmetic, and the same reason prod's unhealthy alarms
  # give: the collector is invoked a handful of times a week, so the metric is
  # absent almost always and the default would park this in INSUFFICIENT_DATA
  # permanently — an alarm that never fires and never says why.
  assert {
    condition     = aws_cloudwatch_metric_alarm.release_metrics_errors.treat_missing_data == "notBreaching"
    error_message = "an absent Errors metric is not a breach"
  }
}
```

- [ ] **Step 2: Add the alarm**

Append to `infra/foundation/observability.tf`:

```hcl
# --- who watches the watcher -------------------------------------------------
#
# Every alert this phase produces is published BY the collector, which makes a
# broken collector silent. This is the exception: CloudWatch alarms on the
# function's own Errors metric and publishes to the topic directly, so the one
# failure the design cannot route through the Lambda does not have to be.
#
# One error in one minute is enough. This function runs a few times a week and
# every invocation matters; there is no volume here for a threshold to smooth.

resource "aws_cloudwatch_metric_alarm" "release_metrics_errors" {
  alarm_name = "${local.observability.collector_name}-errors"
  alarm_description = join(" ", [
    "The release metrics collector raised. Something it needed from CloudWatch,",
    "SNS or CodePipeline failed — which means metrics and alerts are being",
    "lost. This alarm does not travel through the collector (plan D13).",
  ])

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  statistic   = "Sum"

  dimensions = {
    FunctionName = module.release_metrics.function_name
  }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 1

  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]

  # No ok_actions, matching D16: the collector recovering is not news, and this
  # topic has one subscriber whose attention is the scarce resource.
}
```

- [ ] **Step 3: Run the foundation suite**

Run: `./scripts/tf.sh test foundation`
Expected: PASS.

- [ ] **Step 4: Extend the foundation override in all six prod test files**

F14, and it comes first because without it Task 8's next step fails in five files that have nothing to do with alarms, with an error that names neither the alarms nor the assertion.

In **each** of `mocks.tftest.hcl`, `bluegreen.tftest.hcl`, `compute.tftest.hcl`, `data_and_iam.tftest.hcl`, `edge.tftest.hcl` and `outputs.tftest.hcl`, add one line to the `override_data` block for `data.terraform_remote_state.foundation`:

```hcl
      alerts_topic_arn   = "arn:aws:sns:us-east-1:590184028094:bgd-us-east-1-alerts"
```

Six identical edits, and the duplication is the framework's rather than a choice — `mocks.tftest.hcl`'s own header records that there is no shared-setup construct and that it is the reference copy a reviewer diffs the others against. Keep the value byte-identical across all six so that diff stays useful.

Run: `./scripts/tf.sh test prod`
Expected: still PASS. Nothing consumes the new output yet; this step only makes the next one able to fail for the right reason.

- [ ] **Step 5: Add `alarm_actions` to prod's four alarms and watch the gate fail**

In `infra/environments/prod/alarms.tf`, add to each of `five_xx`, `p95_latency` and `unhealthy`:

```hcl
  # Phase 9 D12. Read from foundation's output rather than written out, so a
  # topic that is ever recreated cannot leave four alarms pointing at an ARN
  # that no longer resolves — which does not fail an apply and does not fail a
  # plan; it just stops sending mail.
  alarm_actions = [local.foundation.alerts_topic_arn]
```

Also update each alarm's `alarm_description`: the phrase "carries no actions by design (plan D9)" is now false in all four. Replace it with "notifies the alert topic (Phase 9 D12)".

Run: `./scripts/tf.sh test prod`
Expected: **FAIL**, on `bluegreen.tftest.hcl`'s `no alarm carries actions; Phase 9 owns notification…`. This is F9 arriving exactly where it was predicted. Confirm the failure names that assertion before changing it — a different failure means something else is wrong.

- [ ] **Step 6: Invert the assertion rather than deleting the run**

In `infra/environments/prod/tests/bluegreen.tftest.hcl`, replace the assertion body and rewrite the comment above it to record what changed and when:

```hcl
  # Plan §D9 created these with no actions, so that Phase 9 could attach to the
  # same alarms rather than create parallel ones. Phase 9 (D12) did. The
  # assertion is inverted rather than deleted, because the property worth
  # protecting is still there — it just moved from "nobody is notified" to
  # "notification goes to the one topic this project owns, read from
  # foundation's output rather than written out by hand".
  #
  # ok_actions stays empty: an alarm returning to OK during a bake is the normal
  # end of every successful deployment, and mailing that would train the
  # recipient to filter the topic. Phase 9 §D16.
  assert {
    condition = alltrue([
      for alarm in [
        aws_cloudwatch_metric_alarm.five_xx,
        aws_cloudwatch_metric_alarm.p95_latency,
        aws_cloudwatch_metric_alarm.unhealthy["blue"],
        aws_cloudwatch_metric_alarm.unhealthy["green"],
      ] : alarm.alarm_actions == toset([local.foundation.alerts_topic_arn]) && coalesce(try(length(alarm.ok_actions), 0), 0) == 0
    ])
    error_message = "every bake alarm notifies the alert topic and none carries ok_actions (Phase 9 §D12, §D16)"
  }
```

- [ ] **Step 7: Run both layers' suites**

Run: `./scripts/tf.sh test prod && ./scripts/tf.sh test foundation`
Expected: both PASS.

- [ ] **Step 8: Commit**

```bash
git add infra/foundation/observability.tf infra/foundation/tests/observability.tftest.hcl \
        infra/environments/prod/alarms.tf infra/environments/prod/tests/
git commit -m "feat(infra): the collector's watchdog alarm, and bake alarms that notify"
```

---

### Task 9: The dashboard

**Files:**
- Create: `infra/foundation/dashboard.tf`
- Create: `infra/foundation/tests/dashboard.tftest.hcl`

**Interfaces:**
- Consumes: `local.observability`, `var.metric_namespace`, `var.region`.
- Produces: `aws_cloudwatch_dashboard.release`, `local.dashboard_widgets`.

- [ ] **Step 1: Write the failing dashboard tests**

Create `infra/foundation/tests/dashboard.tftest.hcl`. The assertions are about what F8 says the apply cannot catch — a widget describing something that does not exist:

```hcl
# What a PutDashboard call will not tell you.
#
# Plan §F8: the API validates a widget's STRUCTURE and the provider surfaces
# that as an apply error, so a malformed widget fails loudly. A widget that is
# structurally perfect and names a metric nothing publishes renders empty and
# fails nothing, forever. These runs are the only place that can be caught
# offline.

mock_provider "aws" {
  mock_resource "aws_acm_certificate" {
    defaults = {
      domain_validation_options = [
        {
          domain_name           = "api.carloscloudengineer.com"
          resource_record_name  = "_mock.api.carloscloudengineer.com."
          resource_record_type  = "CNAME"
          resource_record_value = "_mock.acm-validations.aws."
        },
        {
          domain_name           = "staging-api.carloscloudengineer.com"
          resource_record_name  = "_mock.staging-api.carloscloudengineer.com."
          resource_record_type  = "CNAME"
          resource_record_value = "_mock.acm-validations.aws."
        },
      ]
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:590184028094:bgd-us-east-1-alerts" }
  }
}

run "the_body_is_valid_json_with_widgets" {
  command = apply

  assert {
    condition     = length(jsondecode(aws_cloudwatch_dashboard.release.dashboard_body).widgets) >= 8
    error_message = "the dashboard must carry the release, pipeline, production and staging widgets"
  }

  assert {
    condition = alltrue([
      for widget in jsondecode(aws_cloudwatch_dashboard.release.dashboard_body).widgets :
      contains(["metric", "text"], widget.type)
    ])
    error_message = "only metric and text widgets — a log widget would name a prod log group that make teardown deletes (plan D17)"
  }
}

run "every_release_metric_this_phase_writes_appears_on_the_dashboard" {
  command = apply

  # The failure this catches is a metric that is emitted, billed, and never
  # looked at — or worse, one renamed in handler.py and left stale here.
  assert {
    condition = alltrue([
      for metric_name in [
        "DeploymentSucceeded",
        "DeploymentFailed",
        "DeploymentRolledBack",
        "LeadTimeSeconds",
        "RecoveryTimeSeconds",
        "PipelineFailed",
      ] : strcontains(aws_cloudwatch_dashboard.release.dashboard_body, metric_name)
    ])
    error_message = "every metric the collector writes must be shown somewhere on the dashboard"
  }

  assert {
    condition     = strcontains(aws_cloudwatch_dashboard.release.dashboard_body, var.metric_namespace)
    error_message = "the widgets must read the namespace the collector writes to"
  }
}

run "the_alb_widgets_search_by_name_and_the_rest_name_dimensions_literally" {
  command = apply

  # Plan §D17. If a LoadBalancer dimension value ever appears literally here,
  # someone has hard-coded an arn_suffix that a teardown/rebuild will change,
  # and the widget will go quietly empty on the next rebuild.
  assert {
    condition     = strcontains(aws_cloudwatch_dashboard.release.dashboard_body, "SEARCH(")
    error_message = "ALB widgets must search by load balancer name, not by a suffix this layer cannot know"
  }

  assert {
    condition = alltrue([
      for name in [
        local.observability.prod_alb_name,
        local.observability.staging_alb_name,
        local.observability.prod_cluster_name,
        local.observability.prod_service_name,
      ] : strcontains(aws_cloudwatch_dashboard.release.dashboard_body, name)
    ])
    error_message = "both environments' load balancers and the production service must be on the dashboard (plan D15)"
  }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `./scripts/tf.sh test foundation`
Expected: FAIL — `aws_cloudwatch_dashboard.release` is not declared.

- [ ] **Step 3: Build the dashboard**

Create `infra/foundation/dashboard.tf`. Build the widget list in a `local` and `jsonencode` it once, so the resource stays one line and the widgets are readable HCL rather than a JSON blob:

```hcl
# One dashboard, four bands: release metrics, pipeline health, production
# health, staging health. Plan §D15 — the metrics are production's, the health
# is both environments', because "staging is sick" is the answer to "why did the
# pipeline stop" and that should not need a second console tab.
#
# Widgets are built as HCL and jsonencoded once at the bottom. The alternative,
# a heredoc of JSON, cannot interpolate a name without quoting rules nobody
# remembers and cannot be read in a diff.
#
# NO LOG WIDGETS, deliberately, and this is the one shape decision the layer
# split forces on the presentation. A log widget names a log group; the ones
# worth showing — the hook groups, the production container's — belong to a
# layer `make teardown` destroys, and a widget pointed at a missing group
# renders an error rather than an empty chart. Metric widgets degrade to empty
# and recover on rebuild, which is the behaviour this dashboard needs.

locals {
  # Every ALB and target-group series, matched by NAME. The LoadBalancer
  # dimension value is app/<name>/<16 hex characters> and the hex is assigned at
  # creation, so it is the one dimension this layer cannot compose — see plan
  # §D17. Searching survives the rebuild that changes it.
  alb_search = {
    prod_5xx = "SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"HTTPCode_Target_5XX_Count\" ${local.observability.prod_alb_name}', 'Sum', 60)"
    prod_requests = "SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"RequestCount\" ${local.observability.prod_alb_name}', 'Sum', 60)"
    prod_latency = "SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"TargetResponseTime\" ${local.observability.prod_alb_name}', 'p95', 60)"
    prod_unhealthy = "SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} MetricName=\"UnHealthyHostCount\" ${local.observability.prod_alb_name}', 'Maximum', 60)"
    staging_5xx = "SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"HTTPCode_Target_5XX_Count\" ${local.observability.staging_alb_name}', 'Sum', 60)"
    staging_latency = "SEARCH('{AWS/ApplicationELB,LoadBalancer} MetricName=\"TargetResponseTime\" ${local.observability.staging_alb_name}', 'p95', 60)"
  }

  release_dimensions = ["Environment", "prod"]
}
```

Then the widget list. Build these, in this order, at `width = 24` per row of six-wide widgets:

1. **text**, full width — the header: what this dashboard is, which basis the lead time uses (D6), links to both pipelines and both API hostnames, and the sentence that the four bake alarm thresholds are chosen rather than measured.
2. **metric**, `view = "bar"`, `stat = "Sum"`, `period = 86400` — `DeploymentSucceeded` and `DeploymentFailed`, `Environment=prod`. Title: *Deployment frequency (per day)*.
3. **metric**, `view = "singleValue"` — a metric-math expression over the same two:
   ```hcl
   [{ expression = "100 * FILL(failed, 0) / (FILL(failed, 0) + FILL(succeeded, 0))", label = "Change failure rate %", id = "cfr" }]
   ```
   with both source metrics `visible = false`. `FILL(…, 0)` matters: without it, a period in which one series has no datapoint makes the whole expression empty rather than zero, and the tile reads blank on exactly the quiet weeks it should read `0`.
4. **metric**, `view = "timeSeries"`, `stat = "Average"` — `LeadTimeSeconds`. Title: *Lead time, commit to production (s)*.
5. **metric**, `view = "singleValue"`, `stat = "Average"` — `RecoveryTimeSeconds`. Title: *MTTR (s)*.
6. **metric**, `view = "bar"`, `stat = "Sum"` — `PipelineFailed` for both `PipelineName` values, and `DeploymentRolledBack`. Title: *Pipeline failures and rollbacks*.
7. **metric** — `local.alb_search.prod_requests` and `local.alb_search.prod_5xx`. Title: *Production requests and 5xx*.
8. **metric** — `local.alb_search.prod_latency` and `local.alb_search.prod_unhealthy`. Title: *Production p95 and unhealthy targets*.
9. **metric**, literal dimensions — `AWS/ECS` `CPUUtilization`, `MemoryUtilization` and `RunningTaskCount` for `ClusterName = local.observability.prod_cluster_name`, `ServiceName = local.observability.prod_service_name`. Title: *Production service*.
10. **metric**, literal dimensions — `AWS/DynamoDB` `ConsumedReadCapacityUnits`, `ConsumedWriteCapacityUnits` and `ThrottledRequests` for each name in `local.observability.prod_table_names`.
11. **metric** — `local.alb_search.staging_5xx` and `local.alb_search.staging_latency`. Title: *Staging health*.
12. **metric**, literal dimensions — `AWS/Lambda` `Invocations`, `Errors` and `Duration` for `FunctionName = local.observability.collector_name`. Title: *The collector itself* — because a dashboard whose data source is broken should say so on its own face.

Then:

```hcl
resource "aws_cloudwatch_dashboard" "release" {
  dashboard_name = local.observability.dashboard_name
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
```

- [ ] **Step 4: Run and confirm green**

Run: `./scripts/tf.sh test foundation`
Expected: PASS, all three dashboard runs included.

- [ ] **Step 5: Commit**

```bash
git add infra/foundation/dashboard.tf infra/foundation/tests/dashboard.tftest.hcl
git commit -m "feat(infra): one dashboard, searching ALBs by name so a rebuild cannot blank it"
```

---

### Task 10: The trigger gap, the outputs, and a clean static analysis pass

**Files:**
- Modify: `infra/foundation/codepipeline.tf`
- Modify: `infra/foundation/tests/pipeline_shape.tftest.hcl`
- Modify: `infra/foundation/outputs.tf`
- Modify: `infra/foundation/README.md`

- [ ] **Step 1: Update the trigger's shape test first**

In `infra/foundation/tests/pipeline_shape.tftest.hcl`, add `"lambdas/**"` to the expected pattern set and extend the comment: this is Phase 6's gap, not Phase 8's, and the test asserting the set exactly is what makes finding it a one-line fix.

Run: `./scripts/tf.sh test foundation`
Expected: FAIL, the pattern-set assertion — the test now expects seven and the resource has six.

- [ ] **Step 2: Add the pattern**

In `infra/foundation/codepipeline.tf`'s `file_paths.includes`, add `"lambdas/**"` and a comment recording D18:

```hcl
            # lambdas/** joins in Phase 9, and — like scripts/tf.sh in Phase 8 —
            # this is a PRE-EXISTING gap rather than a consequence of the phase
            # that found it. infra/environments/prod/hooks.tf has packaged
            # lambdas/lifecycle_hook/handler.py since Phase 6, and Phase 9's
            # collector is packaged from the same directory. A commit that only
            # fixes a handler changes no watched file, so this pipeline does not
            # run and the fix never reaches the function that gates production.
            # No error, no failed run: nothing happens at all. Phase 9 §D18, §F6.
            #
            # Seven of the eight patterns filePaths.includes accepts (§F7), so
            # this still needs no second push block — unlike the application
            # pipeline's eleven.
            "lambdas/**",
```

Run: `./scripts/tf.sh test foundation`
Expected: PASS.

- [ ] **Step 3: Add the outputs**

Append to `infra/foundation/outputs.tf`, under a Phase 9 banner:

```hcl
output "release_metrics_function_name" {
  description = "The collector. The runbook tails /aws/lambda/<this> to read which ECS event names really arrive (plan F3)."
  value       = module.release_metrics.function_name
}

output "release_metrics_log_group_name" {
  description = "Where the collector's decisions are recorded — including lead_time_basis, which is the only place the lead-time metric's meaning is stated (plan D6)."
  value       = module.release_metrics.log_group_name
}

output "dashboard_name" {
  description = "The single dashboard covering pipeline and application health in both environments."
  value       = aws_cloudwatch_dashboard.release.dashboard_name
}

output "dashboard_url" {
  description = "Console deep link. Published because the runbook's verification step is 'open it and confirm every widget draws' (plan F8), and deriving this URL by hand is how that step ends up pointed at a dashboard that does not exist."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.release.dashboard_name}"
}

output "metric_namespace" {
  description = "Namespace the collector writes to and every widget reads from. Published so the runbook's aws cloudwatch list-metrics call cannot be typed with a different spelling than the one deployed."
  value       = var.metric_namespace
}
```

Add matching assertions to `observability.tftest.hcl` pinning each output name, in the shape `prod/tests/outputs.tftest.hcl` uses — a rename then fails in this layer rather than in the runbook.

- [ ] **Step 4: Run the full offline gate**

Run: `make tf-check`
Expected: `all infra checks passed`.

If tflint or checkov objects, fix or skip with a written reason naming the trade-off. Expect at least the two `CKV_AWS_355` findings Task 6 pre-empted; record any others in §1's "Findings discovered during implementation" with the real check ID rather than a guess.

- [ ] **Step 5: Run everything**

Run: `make tf-check && make test-lambdas && make lint`
Expected: all three green.

- [ ] **Step 6: Update the layer README and commit**

`infra/foundation/README.md` gains the observability plane: what the collector does, the two rules, the dashboard, and the sentence that this layer owns them because prod cannot be read from here.

```bash
git add infra/foundation/codepipeline.tf infra/foundation/tests/pipeline_shape.tftest.hcl \
        infra/foundation/outputs.tf infra/foundation/README.md
git commit -m "feat(infra): the pipeline watches lambdas/, and the observability outputs"
```

---

### Task 11: The runbook

**Files:**
- Create: `docs/runbooks/phase-09-observability.md`
- Modify: `docs/runbooks/README.md`

The runbook is what actually meets §5's exit criteria (D1). It follows the shape Phases 3–8 established: numbered steps, exact commands, expected output, and what to do when the output differs.

- [ ] **Step 1: Write the steps**

1. **Preconditions** — an AWS session, the Phase 8 runbook completed, the SNS email subscription confirmed. The last one has an explicit verification command, because an unconfirmed subscription makes every step below appear to work while no email arrives: `aws sns list-subscriptions-by-topic --topic-arn <arn> --query 'Subscriptions[].SubscriptionArn'`, which reads `PendingConfirmation` if it was never clicked.
2. **Apply `foundation`** — `make apply-foundation`. Note that this is the layer containing the pipeline, so it can also be applied through the pipeline; local is simpler here because the pipeline's own event rule is part of what is being created.
3. **Apply `prod`** — `make apply-prod`, for the `alarm_actions`. Expect exactly four alarm changes and nothing else in the plan; anything more means an unrelated drift to understand first.
4. **Confirm the wiring** — `aws events list-targets-by-rule` for both rules, `aws lambda get-policy` for the two statements.
5. **Provoke a pipeline failure deliberately** — the cheapest real test: run the app pipeline with `APP_SCOPE` set to something invalid, which D3 of Phase 8 makes fail loudly at the scope gate. Expect an email within two minutes and one `PipelineFailed` datapoint.
6. **Deploy something for real** — merge a trivial `app/` change, or re-run with `APP_SCOPE=all`. This is the step that produces the first `DeploymentSucceeded` and the first `LeadTimeSeconds`.
7. **Read the collector's log and record the truth** (F3, F4, D4, D6, D8). The step that retires three findings:
   ```bash
   aws logs tail /aws/lambda/bgd-us-east-1-release-metrics --since 30m --format short
   ```
   Record: every distinct `eventName` that arrived, whether a rollback produced its own event, and whether the log says `lead_time_basis=commit` or `=merge`. Write the answers into the local verification record and, if the event names differ from `SUCCEEDED_EVENTS`/`FAILED_EVENTS`, into `handler.py`.
8. **Confirm the metrics exist** — `aws cloudwatch list-metrics --namespace ReleaseMetrics`, expecting the streams that the run so far should have produced and *not* the ones it should not.
9. **Open the dashboard and confirm every widget draws** (F8). Use the `dashboard_url` output. A widget that is empty because nothing has happened yet is fine and named as such; a widget that is empty because its `SEARCH` matches nothing is the failure this step exists to find, and the tell is that a sibling widget on the same load balancer has data.
10. **Confirm the bake alarms notify** — set one threshold deliberately low with a temporary `-var`, wait for the breach email, put it back. Do not leave it.
11. **Record the real thresholds** — the Phase 6 runbook's step 10 repeated, because D12 gave the four thresholds a second consumer and a wrong one is now an email at 3am rather than only a mis-gated bake.
12. **Confirm the watchdog** — `aws lambda invoke` the collector with a payload that makes it raise (the simplest is one that passes routing but fails a downstream call), then confirm the alarm and the email. Reset by waiting for the alarm to return to OK, which sends nothing (D16).

- [ ] **Step 2: Update the runbooks index and commit**

```bash
git add docs/runbooks/phase-09-observability.md docs/runbooks/README.md
git commit -m "docs: the Phase 9 runbook"
```

---

### Task 12: Amendments and the local verification record

**Files:**
- Modify: `docs/2026-08-04-implementation-phase-roadmap.md`
- Modify: `docs/2026-08-04-blue-green-deployment-platform-design-research.md`
- Modify: `docs/naming-and-tagging-convention.md`
- Modify: `lambdas/README.md`
- Modify: `infra/modules/lambda/README.md`
- Modify: `infra/foundation/iam-app-pipeline.tf` (the corrected prediction)
- Create: `docs/phases/phase9/2026-08-30-local-verification.md`

- [ ] **Step 1: Amend the roadmap**

A Phase 9 amendment in the established shape, covering: the layer placement and the cycle that forces it (D2); the collector deciding what is alert-worthy rather than an `input_transformer` (D3); the deliberately unfiltered ECS rule (D4); seven metric streams with the ratios computed on the dashboard rather than stored (D5); MTTR without a state store (D7); the three deferred decisions this phase settles — Container Insights (D14), the bake alarms' actions (D12) and the module variant that turned out unnecessary (D10); and **a second note on Phase 7's trigger**, recorded in that phase's section as well as this one, in exactly the way Phase 8 recorded the first.

State plainly that **neither exit criterion is met by the branch alone**, and name the runbook steps that meet each.

Add the row confirming §2's branch table needs no amendment: row 9 reads `feat/Phase9_Observability`, which is the branch used — recorded explicitly, as Phases 3, 5, 6, 7 and 8 did.

- [ ] **Step 2: Amend design §8**

§8 names four metrics and a namespace. Amend it with what was built: the six metric names and why change failure rate and deployment frequency are deliberately *not* among them; the two rules and why one filters narrowly and the other barely at all; the lead-time basis and its fallback; and the fact that the collector is the alerting decision point.

§8.1's role count does not change — the collector's execution role comes from the module, and its extra policy attaches to that same role — and saying so explicitly is worth a sentence, because every phase since Phase 6 has added to that count and a phase that does not is the surprising case.

- [ ] **Step 3: Amend the convention**

§7's worked example lists the production plane. Add the observability plane beside it — the collector, its exec role, its log group, the two rules, the watchdog alarm and the dashboard — with `environment = shared` on all of them, and a note that `prod` in `bgd-us-east-1-prod-deployments` names *what the rule watches*, which is Phase 8's §2 amendment applied a second time.

- [ ] **Step 4: Amend the two READMEs and the corrected prediction**

`lambdas/README.md`: the table's second row is no longer "the metrics collector, Phase 9" as a plan — it is built. Document its environment variables, its return contract, and above all **why its contract is the opposite of the hook's** (D9), because a reader who has just read the hook's asymmetric-raise section and then sees a handler that swallows everything will otherwise conclude one of them is wrong.

`infra/modules/lambda/README.md`: retire the prediction that Phase 9 needs a variant (D10, F2), record that the six skips were re-examined and which one changed (D11), and keep the single-file property stated as the module's design rather than a limitation — it survived contact with the case that was supposed to break it.

`infra/foundation/iam-app-pipeline.tf`: the comment predicting "Phase 9 adds a third set" is wrong in a way worth correcting rather than leaving, since a future reader looking for `iam-observability.tf` will not find it.

- [ ] **Step 5: Write the local verification record**

`docs/phases/phase9/2026-08-30-local-verification.md`, in the shape of Phases 3–8: every command run, its real output, every finding discovered during implementation with its ID, and an explicit statement of what is **not** verified — which for this phase is everything the runbook covers, plus the three findings (F3, F4, F8) that only a real deployment can retire.

- [ ] **Step 6: Final gate**

Run: `make tf-check && make test-lambdas && make lint`
Expected: all green. Then `git status` clean but for the intended files.

- [ ] **Step 7: Commit**

```bash
git add docs lambdas/README.md infra/modules/lambda/README.md infra/foundation/iam-app-pipeline.tf
git commit -m "docs: Phase 9 amendments and the local verification record"
```

---

## 5. Exit criteria

From the roadmap:

> **Exit criteria:** a real deployment produces metrics on the dashboard; a deliberately failed deployment produces an email.

| # | Criterion | Met by | Verified in |
|---|---|---|---|
| 1 | A real deployment produces metrics on the dashboard | a production deployment through the Phase 8 pipeline | runbook steps 6, 8 and 9 |
| 2 | A deliberately failed deployment produces an email | the scope-gate failure of step 5, and the alarm breach of step 10 | runbook steps 5 and 10 |

**Neither is met by the branch alone.** Both need a pipeline execution and a running production service, and this session creates no AWS resource (D1).

The branch's own gate, which **is** met by the branch:

- `make tf-check` passes — `terraform validate`, `tflint`, `checkov` and the Terraform test suites for all five layers, against mocked providers, with no AWS session.
- `make test-lambdas` passes with both packages at or above 95% coverage.
- `make lint` passes on `app/` and `lambdas/`.
- `terraform test` really builds the collector's deployment package from `lambdas/release_metrics/handler.py` (F12), so the packaging is proved rather than mocked.

---

## 6. Risks this phase adds

| Risk | Handling |
|---|---|
| The ECS blue/green event vocabulary differs from the guessed set (F3) | The rule does not filter on it, so every event reaches the handler and is logged. Runbook step 7 records the real names; the fix is one `frozenset`. |
| A rollback emits both a rollback event and a FAILED event, so change failure rate under-counts (D8) | Chosen over the double-count. `DeploymentRolledBack` is its own widget beside the rate, so the gap is visible rather than hidden. Runbook step 7 confirms which case is real. |
| `artifactRevisions[].created` is not populated, so lead time silently means merge-to-production (F4) | The handler logs `lead_time_basis` on every emission and the dashboard's header widget states which basis is in use. Never silent. |
| A `SEARCH()` expression matches nothing and a widget is permanently empty (F8) | Runbook step 9 opens the dashboard and checks each widget, using a sibling widget on the same load balancer as the control. |
| The bake alarms now email on any breach, not only during a deployment (D12) | Accepted — a production 5xx storm outside a deployment is worth an email. The thresholds are recorded as *chosen, not measured* and runbook step 11 records the real ones. |
| Phase 11's demonstrations will send real email | Intended. A demonstration rollback that mails you is the demonstration working; Phase 6's reason for deferring the actions was the eight phases in which the topic carried nothing. |
| The collector is a single point of failure for alerting (D3) | The watchdog alarm (D13) does not travel through it. A second EventBridge→SNS path was rejected: two paths mean two emails per failure, and duplicates train the recipient to filter the topic faster than a gap does. |
| boto3's bundled version changes under the collector (F2) | Four API calls whose signatures are a decade old. Recorded in the module README; the escalation, if it ever happens, is a Lambda layer. |
| Seven custom metric streams cost about $2.10/month while active (F10) | Accepted and stated. Nothing is billed in a month with no deployment, which is most months under the destroy-when-idle policy. |
