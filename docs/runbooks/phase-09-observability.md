# Runbook — Phase 9: the observability plane, and what a real deployment proves

**Date:** 2026-08-30
**Layer:** `infra/foundation` (the collector, its two rules, the dashboard, its own
errors alarm) plus four one-line `alarm_actions` changes in
`infra/ (enable_prod = true)`
**Estimated time:** 60–90 minutes, not counting a fresh production bake if
step 7 needs one from scratch — Phase 8's runbook already covers that wait
**Cost while it exists:** small. Plan §F10 puts the seven metric streams at
about $2.10 a month while they receive data; the collector runs a handful of
times a week at 256 MB for well under a second each; the dashboard is free
(the first three per account are); 30 days of collector logs is the same
family as the pipeline log groups already carry

Tasks 1 through 10 wrote and unit-tested the collector, both EventBridge
rules, the dashboard and the four `alarm_actions` lines with no AWS session —
148 Terraform test runs across five layers, all green, plus 37 handler tests
at 97.29% coverage. **Nothing in that branch has been created in AWS, and
three things about it could not be checked without a real deployment:**
which ECS event names a blue/green deployment actually emits, whether
`CodePipeline` populates a commit timestamp for a CodeConnections source, and
whether a `SEARCH()` widget's expression actually matches anything. This
runbook creates the plane, then uses a real deployment and a real failure to
settle all three and to meet the phase's two exit criteria:

1. **a real deployment produces metrics on the dashboard** — met at step 10
2. **a deliberately failed deployment produces an email** — met at step 5

> **Steps 8, 10 and 12 are not checkboxes.** They exist because the offline
> gate could not answer three questions, and each is written to record an
> answer, not just confirm a green light. Read them slowly.

---

## 1. Preconditions

Three, and the third has no error message when it is silently wrong.

**An AWS session.**

```bash
make verify-aws
```

Expected: account `590184028094`, region `us-east-1`.

**The Phase 8 runbook is complete.** This phase's dashboard names the
application pipeline by output and its ECS rule targets the production
service directly; both need to already exist.

```bash
terraform -chdir=infra/foundation output -raw app_pipeline_name
```

**The SNS email subscription is confirmed.** This is the one precondition
that fails silently. Terraform creates the subscription `PendingConfirmation`
and a human finishes it with one click on the email AWS sends — `plan` stays
clean either way, and every step below can report success while no mail ever
arrives if the link was never clicked.

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$(terraform -chdir=infra/foundation output -raw alerts_topic_arn)" \
  --query 'Subscriptions[].{Endpoint:Endpoint,Status:SubscriptionArn}' --output table
```

Expected: `Status` holds a real subscription ARN
(`arn:aws:sns:us-east-1:...:...`). If it instead reads the literal string
`PendingConfirmation`, stop here, find the confirmation email and click it —
nothing past this point can be trusted until it does.

---

## 2. Apply `foundation`

This layer contains the observability plane *and* both pipelines, so it can
in principle be applied through the infra pipeline. Local is simpler here:
the infra pipeline's own trigger is one of the things this apply changes
(D18 — `lambdas/**` joins its watched paths, closing F6), so applying through
the pipeline would mean the pipeline updating the rule that decides when it
next runs.

```bash
make plan-foundation
```

Expect, and count them:

| Resource | Count |
|---|---|
| `aws_lambda_function` | 1 — the collector |
| `aws_iam_role` | 1 |
| `aws_iam_role_policy` | 2 — the module's own log-write policy, plus the collector's `PutMetricData`/`GetMetricData`/`sns:Publish`/`codepipeline:Get*` policy |
| `aws_cloudwatch_log_group` | 1 |
| `aws_cloudwatch_event_rule` | 2 |
| `aws_cloudwatch_event_target` | 2 |
| `aws_lambda_permission` | 2 |
| `aws_cloudwatch_metric_alarm` | 1 — the collector's own errors alarm (§13) |
| `aws_cloudwatch_dashboard` | 1 |
| `aws_codepipeline.infra` | **1 changed**, not replaced |

**The changed one is the point of this check**, exactly as it was in Phase
8's step 4: the only difference should be `lambdas/**` joining the infra
pipeline's `file_paths.includes`, now seven patterns. If the plan shows this
pipeline being replaced, or shows any stage changing, stop and read the diff
before applying.

```bash
make apply-foundation
```

Two to three minutes. Nothing here touches a running service.

---

## 3. Apply `prod`

The one place `alarm_actions` can be set is where the alarm is, so the four
bake alarms from Phase 6 gain it here, not in `foundation`.

```bash
make plan-prod
```

**Expect exactly four changes and nothing else**: `bgd-us-east-1-prod-target-5xx`,
`bgd-us-east-1-prod-p95-latency`, `bgd-us-east-1-prod-unhealthy-blue` and
`bgd-us-east-1-prod-unhealthy-green`, each gaining
`alarm_actions = [<alerts topic arn>]` and an updated `alarm_description`.
Anything more in this plan is unrelated drift — understand it before applying.

```bash
make apply-prod
```

Seconds, not minutes: an alarm's `alarm_actions` is metadata on the alarm
resource, not on the ECS service, so this does not touch the running
deployment.

---

## 4. Confirm the wiring

```bash
PREFIX="$(terraform -chdir=infra/foundation output -raw name_prefix)"
COLLECTOR="$(terraform -chdir=infra/foundation output -raw release_metrics_function_name)"

aws events list-targets-by-rule --rule "${PREFIX}-pipeline-executions" --output table
aws events list-targets-by-rule --rule "${PREFIX}-prod-deployments" --output table

aws lambda get-policy --function-name "$COLLECTOR" --query Policy --output text | jq .
```

Expected: each rule has exactly one target, the collector's function ARN,
with `RetryPolicy` reading `MaximumRetryAttempts: 2` and
`MaximumEventAgeInSeconds: 300` (plan §D11, §F11 — EventBridge's own default
is 185 attempts over 24 hours, which is not what an alert should do). The
policy has two statements, `AllowInvocationFromPipelineExecutionsRule` and
`AllowInvocationFromProdDeploymentsRule`, each naming `events.amazonaws.com`
as principal and one of the two rule ARNs as `SourceArn`.

---

## 5. Decline the production approval — the alert path, end to end

The guaranteed way to produce a real `Failed` pipeline execution is not a
scope value — it is the one point in the pipeline a human is already asked
to make a decision. Start a full run and reject it there:

```bash
APP_PIPELINE="$(terraform -chdir=infra/foundation output -raw app_pipeline_name)"

aws codepipeline start-pipeline-execution \
  --name "$APP_PIPELINE" --variables name=APP_SCOPE,value=all
```

Wait for Build and DeployStaging to finish and `Prod`/`Approve` to go
pending (Phase 8 runbook §6c), then reject it:

```bash
TOKEN="$(aws codepipeline get-pipeline-state --name "$APP_PIPELINE" \
  --query 'stageStates[?stageName==`Prod`].actionStates[?actionName==`Approve`].latestExecution.token' \
  --output text)"

aws codepipeline put-approval-result \
  --pipeline-name "$APP_PIPELINE" --stage-name Prod --action-name Approve \
  --result summary="deliberate rejection — Phase 9 runbook step 5, testing the alert path",status=Rejected \
  --token "$TOKEN"
```

```bash
aws codepipeline list-pipeline-executions --pipeline-name "$APP_PIPELINE" \
  --max-items 1 --query 'pipelineExecutionSummaries[0].status' --output text
```

**Expected:** `Failed`. Within about two minutes: an email subject
`[bgd] Pipeline FAILED — bgd-us-east-1-app-pipeline`, and one
`PipelineFailed` datapoint:

```bash
aws cloudwatch get-metric-statistics \
  --namespace "$(terraform -chdir=infra/foundation output -raw metric_namespace)" \
  --metric-name PipelineFailed \
  --dimensions Name=PipelineName,Value="$APP_PIPELINE" \
  --start-time "$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --statistics Sum --output table
```

**This does not distort change failure rate.** The dashboard's ratio is
computed from `DeploymentFailed`/`DeploymentSucceeded`
(`infra/foundation/dashboard.tf`'s "Change failure rate (%)" widget) —
`PipelineFailed` is a different metric with a different dimension
(`PipelineName`, not `Environment`) and never feeds it. A deliberate
rejection here is visible on the "Pipeline failures and rollbacks" widget and
nowhere else; it does not poison the headline number the phase exists to
produce.

---

## 6. The `APP_SCOPE` finding — record what actually happens

**This step tests nothing and must not be treated as though it does.**
Phase 8's plan (§D3) claims an unrecognised `APP_SCOPE` "runs nothing past
Build, loudly." Tracing the mechanism against
`infra/foundation/codepipeline-app.tf` and `scripts/pipeline-deploy.sh`
suggests the two gates might disagree: `DeployStaging`'s `before_entry`
condition uses `VariableCheck` with `MATCHES "^(staging|all)$"`, `Prod`'s
uses `EQ "all"`, and both key on exactly the same three-value vocabulary
(`build`/`staging`/`all`) the script's own `scope_rank()` refuses on. If the
stage condition works as documented, an unrecognised value never reaches the
script at all — the stage **skips**, cleanly, before `pipeline-deploy.sh`'s
`die "APP_SCOPE is '$scope'; expected one of build, staging, all"` on line
160 ever runs. Phase 8's runbook §7 already exercised `MATCHES` with a real
in-vocabulary value and closed Phase 7's F2 for both pipelines — a precondition
of this runbook — so what is genuinely still open here is narrower: whether
the same `VariableCheck` mechanism skips cleanly on a value **outside** the
three-value vocabulary altogether, which nothing before this step has tried.

```bash
aws codepipeline start-pipeline-execution \
  --name "$APP_PIPELINE" --variables name=APP_SCOPE,value=bogus
```

```bash
aws codepipeline get-pipeline-state --name "$APP_PIPELINE" \
  --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table

aws codepipeline list-pipeline-executions --pipeline-name "$APP_PIPELINE" \
  --max-items 1 --query 'pipelineExecutionSummaries[0].status' --output text
```

**Two possible outcomes, and both are worth writing down:**

- **`DeployStaging` and `Prod` both report `Skipped`, and the overall status
  is `Succeeded`.** The stage-level `VariableCheck` condition rejected
  `bogus` before the script ever ran. Record this plainly: it means D3's
  "loudly" describes `scripts/pipeline-deploy.sh`'s own refusal — a refusal
  this run never actually exercises — and not the pipeline's outward
  behaviour, which in this case is quiet and green. A future reader relying
  on an unrecognised scope to fail loudly would be relying on something this
  account does not do.
- **The execution instead reports `Failed`.** The `VariableCheck` condition
  did not behave as documented, or did not evaluate the way this reading of
  the Terraform predicts. Record the stage and reason it failed at — this is
  also a real answer to Phase 7's F2, just the other one.

Whichever happens, step 5 already proved the alert path works; this step's
only job is recording which of the two behaviours the scope gate actually
has, for whoever next relies on it being one or the other.

---
## 7. Deploy something for real

This is the run step 8 reads. Either merge a trivial `app/` change and let
the trigger fire, or start the pipeline directly with `APP_SCOPE=all` — the
build number in the image tag is monotonic per Phase 8, so even a rerun with
no source change produces a new tag, a new task definition revision and a
real ECS deployment:

```bash
aws codepipeline start-pipeline-execution \
  --name "$APP_PIPELINE" --variables name=APP_SCOPE,value=all
```

Follow Phase 8's runbook §6 for what to watch and approve. Do not move on
until `Prod`/`Apply` has succeeded and `curl .../version` reports the new
digest — this is the deployment that produces the first `DeploymentSucceeded`
and the first `LeadTimeSeconds` datapoint.

---

## 8. Read the collector's log and record the truth

**The most valuable content in this runbook.** Three things about the
collector could not be confirmed with no AWS session — which ECS event names
a blue/green deployment really emits (F3), whether a rollback produces its
own event or only looks like a failure (D8), and whether `CodePipeline`
populates a commit timestamp for this account's CodeConnections source (F4,
D6). This step closes the first and third from the deployment step 7 just
produced. The rollback half of D8 needs an actual rollback, which nothing in
this runbook produces — item 2 below says so plainly and names where it
closes instead.

```bash
aws logs tail "$(terraform -chdir=infra/foundation output -raw release_metrics_log_group_name)" \
  --since 30m --format short
```

Record three answers, in the local verification record and here in the
project's memory of this phase:

1. **Every distinct `eventName` the ECS rule actually delivered.**
   `lambdas/release_metrics/handler.py` guesses `SUCCEEDED_EVENTS =
   {"SERVICE_DEPLOYMENT_COMPLETED"}` and `FAILED_EVENTS =
   {"SERVICE_DEPLOYMENT_FAILED"}` — a starting vocabulary, not a confirmed
   one, which is exactly why the rule in `observability.tf` does not filter
   on `eventName` at all. Every name that arrived is in this log, logged
   either as a handled outcome or as `ignoring ECS eventName=...`. If the
   real names differ from the guessed sets, the fix is the one-line
   `frozenset` change the module docstring already points at.
2. **Whether a rollback produced its own event, or only a failure — stays
   open until Phase 11, not this runbook.** The handler counts a rollback
   exactly once — `DeploymentRolledBack`, never also `DeploymentFailed` —
   checked in that order specifically because ECS may emit an event shaped
   like both for the same deployment (D8). Nothing here produces a rollback
   to observe: step 7's deployment reaches steady state and stays there, and
   step 11 only edits an alarm's threshold — no ECS deployment, no bake
   window, nothing for that threshold to gate. **Do not go looking for a
   rollback in this log and conclude something is broken when you do not
   find one** — there is genuinely nothing here yet. Phase 11 owns the first
   real one: its alarm-triggered rollback demonstration deliberately
   breaches the 5xx rate during a bake so ECS reverts automatically, and
   that demonstration's own log read is what finally answers this question.
   Record here only that it is still open, and revisit it there. If ECS
   turns out to emit *only* a rollback-shaped event with no separate
   failure, the change-failure-rate numerator is fine as built. If it emits
   both and the ordering in `_handle_ecs` were ever reversed, every rollback
   would be double-counted — it is not reversed, and that later log is what
   would show it if it were.
3. **Whether the log says `lead_time_basis=commit` or `=merge`.** This line,
   emitted by `_emit_lead_time`, is the **only** place the lead-time metric's
   meaning is recorded anywhere in the system — not in the dashboard, not in
   a comment a plan review would catch. `commit` means
   `artifactRevisions[].created` was populated for this CodeConnections
   source and the metric is genuinely commit-to-production; `merge` means it
   fell back to the execution's own start time. Whichever it is, it applies
   to every `LeadTimeSeconds` datapoint this account will ever produce, and
   the dashboard's header widget already states both possibilities — this is
   the read that turns one of them into fact.

**Also confirm no `Publish` error appears in this log.** SNS rejects a
non-ASCII or over-length `Subject` outright, and `_alert` is the one call in
this handler with no fallback of its own — a rejected `Publish` raises,
which for the FAILED path happens after the metric is already written, so a
retried invocation would inflate the metric it just wrote while the email
that should have explained why never arrives. A clean sweep of this log for
`Publish` errors is what catches that class of failure even if a future edit
to a subject line reintroduces it.

---

## 9. Confirm the metrics exist

```bash
aws cloudwatch list-metrics \
  --namespace "$(terraform -chdir=infra/foundation output -raw metric_namespace)" \
  --output table
```

**Expected to exist**, after steps 5 and 7: `PipelineFailed`
(dimension `PipelineName`), `DeploymentSucceeded` and `LeadTimeSeconds`
(dimension `Environment=prod`).

**Expected to be absent**: `DeploymentFailed`, `DeploymentRolledBack` and
`RecoveryTimeSeconds`. Nothing in this run has failed or rolled back an ECS
deployment, and `RecoveryTimeSeconds` is only ever emitted alongside a
success that follows a prior `DeploymentFailed` (§D7) — there is none yet to
recover from. Seeing any of the three here means something failed silently
upstream of this check; go back and read step 8's log for it.

---

## 10. Open the dashboard and confirm every widget draws

**The check an apply cannot do for you.** `PutDashboard` validates a widget's
*structure* — a malformed widget fails the apply loudly, before you ever see
it. It validates nothing about whether a `SEARCH()` expression matches
anything (F8): a search that matches zero metrics is structurally perfect
JSON, and it renders as a permanently empty tile that fails nothing, ever.

```bash
terraform -chdir=infra/foundation output -raw dashboard_url
```

Open it. Twelve widgets in four bands. Two kinds of empty exist here and
telling them apart is the entire point of this step:

- **Empty because nothing has happened yet — fine, and expected right now.**
  "MTTR" is empty because nothing has failed and then recovered.
  "Pipeline failures and rollbacks" shows `PipelineFailed` from step 5 but no
  `DeploymentRolledBack` bar, because nothing has rolled back yet. "Change
  failure rate" reads 0%, correctly, because `DeploymentFailed` is zero.
- **Empty while a sibling widget on the same load balancer has data — the
  failure this step exists to find.** "Production requests and 5xx",
  "Production p95 and unhealthy targets" and "Staging health" all resolve
  their `SEARCH()` string against the production and staging ALB names by
  string match (D17) — a name that drifted from what Terraform actually
  created renders exactly like a quiet minute. **The tell**: "Production
  service" (literal `ClusterName`/`ServiceName` dimensions, which cannot
  break this way) will show real CPU, memory and task-count data from the
  same deployment. If that widget has data and any ALB-search widget on the
  same load balancer does not, the search string is wrong — check
  `local.alb_search` in `infra/foundation/dashboard.tf` against the real ALB
  name from `aws elbv2 describe-load-balancers`.

**Confirm "Production tables" specifically.** `AWS/DynamoDB`'s
`ThrottledRequests` is primarily `Operation`-dimensioned, not table-level —
unlike `ConsumedReadCapacityUnits`/`ConsumedWriteCapacityUnits` beside it on
the same tile, which this dashboard has not confirmed actually populate with
just `TableName`. If that series stays empty while the consumed-capacity
series show real data, check whether `ReadThrottleEvents`/`WriteThrottleEvents`
— the table-level throttle metrics an operator would normally chart — are the
better fit, before assuming the tile is merely quiet.

---

## 11. Confirm the bake alarms notify

Phase 6 wired the four bake alarms with no actions, by design, so this phase
could attach to them without duplicating them (Phase 6 §D9; Phase 9 §D12).
This step proves the attachment actually sends mail, using the one bake
alarm exposed as a variable.

```bash
./scripts/tf.sh apply prod -var="alarm_p95_seconds=0.001"
```

Seconds — this changes only the alarm's threshold, not the ECS service, so
no deployment or bake follows. Generate two minutes of real traffic (the
alarm needs two consecutive breaching minutes — `evaluation_periods = 2`):

```bash
API="$(terraform -chdir=infra/ (enable_prod = true) output -raw api_url)"
for i in $(seq 1 60); do curl -s "$API/version" >/dev/null; sleep 2; done
```

```bash
P95_ALARM="$(terraform -chdir=infra/ (enable_prod = true) output -json bake_alarm_names | jq -r '.[] | select(contains("p95"))')"

aws cloudwatch describe-alarms --alarm-names "$P95_ALARM" \
  --query 'MetricAlarms[0].{State:StateValue,Reason:StateReason}' --output table
```

Expected: `ALARM` within two to three minutes, and an email — this one in
CloudWatch's own default alarm format (`ALARM: "bgd-us-east-1-prod-p95-latency"
in US East (N. Virginia)`), not the collector's `[bgd] ...` subject, because
this alarm's `alarm_actions` points straight at the SNS topic and never
passes through the Lambda.

**Put the threshold back — do not leave it.**

```bash
./scripts/tf.sh apply prod
```

Confirm the revert actually took:

```bash
./scripts/tf.sh plan prod
```

Expected: `No changes.` If it is not empty, `alarm_p95_seconds` is still set
somewhere — check `terraform.tfvars` for a stray line before walking away. A
threshold this tight left in place will roll back the next real deployment
on ordinary latency.

---

## 12. Record the real thresholds

The Phase 6 runbook's step 10 already has the exercise: read the four bake
alarms' states under real traffic and record the measured p95, the observed
5xx count and the unhealthy-host behaviour, replacing "chosen, not measured"
with real numbers. Repeat it here rather than duplicating it —
`infra/alarms.tf` and the Phase 6 runbook both say the
thresholds were chosen, not measured, and nothing in this phase changes that
fact by itself.

**What changes is the stakes.** Before this phase, a wrong threshold only
mis-gated a bake — too tight rolled back a good deployment, too loose let a
bad one through, and either way the only witness was whoever was watching
the terminal. From this phase on, every one of these four alarms also has
`alarm_actions` (§3, D12): a threshold that is wrong is now an email at 3am,
to the one person subscribed to this topic, for every ordinary traffic spike
that happens to graze it. Record the real numbers here, and if step 11 or
this step's own reading of them suggests the chosen values are wrong, that is
now worth fixing promptly rather than eventually.

---

## 13. Confirm the watchdog

Every alert this phase produces is published *by* the collector — which
means a broken collector is a silent one. The exception is its own errors
alarm (`aws_cloudwatch_metric_alarm.release_metrics_errors`, plan §D13),
which watches the collector's `AWS/Lambda` `Errors` metric directly and
notifies the topic without going through the function at all. This step
proves that path specifically.

Invoke the collector with a payload that passes routing cleanly but fails a
real downstream call — the simplest one is a `CodePipeline` "succeeded"
event for the app pipeline naming an execution id that does not exist, which
reaches `_emit_lead_time`'s `get_pipeline_execution` call and fails there:

```bash
APP_PIPELINE="$(terraform -chdir=infra/foundation output -raw app_pipeline_name)"
COLLECTOR="$(terraform -chdir=infra/foundation output -raw release_metrics_function_name)"

cat > /tmp/watchdog-payload.json <<EOF
{
  "source": "aws.codepipeline",
  "detail-type": "CodePipeline Pipeline Execution State Change",
  "region": "us-east-1",
  "detail": {
    "pipeline": "$APP_PIPELINE",
    "state": "SUCCEEDED",
    "execution-id": "00000000-0000-0000-0000-000000000000"
  }
}
EOF

aws lambda invoke \
  --function-name "$COLLECTOR" \
  --payload file:///tmp/watchdog-payload.json \
  --cli-binary-format raw-in-base64-out \
  /tmp/watchdog-response.json

cat /tmp/watchdog-response.json
```

Expected: the `invoke` command's own output shows `"FunctionError":
"Unhandled"`, and `/tmp/watchdog-response.json` holds a
`PipelineExecutionNotFoundException` — the collector routed the event
correctly and raised only when the AWS call it needed actually failed (§D9).

```bash
aws cloudwatch describe-alarms --alarm-names "${COLLECTOR}-errors" \
  --query 'MetricAlarms[0].{State:StateValue,Reason:StateReason}' --output table
```

Expected: `ALARM` within about a minute, and an email — again in
CloudWatch's own default format, naming the `Errors` metric and this
function.

**Nothing to undo.** No configuration changed; the alarm clears itself. With
`treat_missing_data = "notBreaching"` and no further errors, the next
evaluation period finds nothing to breach and the alarm returns to `OK` on
its own, sending nothing at all — `ok_actions` is deliberately empty (§D16):
the collector recovering is not news, and this topic's one subscriber is a
scarce resource. Confirm it cleared before moving on:

```bash
aws cloudwatch describe-alarms --alarm-names "${COLLECTOR}-errors" \
  --query 'MetricAlarms[0].StateValue' --output text
# OK, no email
```

---

## 14. What goes wrong

| Symptom | Cause |
|---|---|
| No email at any step, everything else green | The SNS subscription is still `PendingConfirmation` (step 1). Nothing past that point can be trusted until the link is clicked. |
| `make plan-foundation` shows more than the table in step 2 | Unrelated drift. Read the full diff before applying; do not assume it is this phase's change. |
| `make plan-prod` shows more than four alarm changes | Same caution as above — this phase touches exactly four `alarm_actions` lines and nothing else in this layer. |
| Step 6's execution reports `Succeeded` with `DeployStaging` and `Prod` both `Skipped` | Correct, documented behaviour, not a bug — the `VariableCheck` condition rejected the unrecognised scope before the script ran. Record it as step 6 asks; it settles Phase 7's F2 rather than needing a fix. |
| A dashboard widget stays empty long after traffic exists | Compare it against "Production service" (literal dimensions, cannot break this way). If that one has data and the empty one is `SEARCH()`-based on the same load balancer, the search string is wrong (step 10, F8). |
| An alarm sits in `INSUFFICIENT_DATA` forever | Expected for the idle colour's `UnHealthyHostCount` (Phase 6 §F3) — not expected for the p95 or 5xx alarms once traffic exists. |
| The collector's errors alarm fires on its own, unprompted | Something it needed from CloudWatch, SNS or CodePipeline genuinely failed. Read `/aws/lambda/<release_metrics_function_name>` for the exception — this is the collector actually being broken, which is what the alarm is for. |
| `alarm_p95_seconds` is still `0.001` after step 11 | The revert apply did not happen or did not take. Re-run `./scripts/tf.sh apply prod` with no `-var` and confirm `plan prod` is empty before leaving. |

---

## 15. Teardown

No change to the teardown story. `make teardown` destroys `prod`, `staging`
and `network`; `foundation` survives, so the collector, both EventBridge
rules, the dashboard and the errors alarm **all survive a teardown** —
consistent with the metric history being the deliverable (plan §D2) and with
both pipelines already surviving it (Phase 8 runbook §11).

**What does not survive:** the four bake alarms and their `alarm_actions`,
along with the rest of `prod`. A rebuild's first `terraform apply` in that
layer recreates all four with no actions, exactly as Phase 6 first created
them, and step 3 of this runbook re-attaches them.

One consequence worth knowing: with `prod` destroyed, the ECS rule
(`bgd-us-east-1-prod-deployments`) still exists and is still armed, filtered
on a service ARN that no longer resolves to a running service. This
generates no traffic and costs nothing — it simply has nothing to match
until `prod` is rebuilt.
