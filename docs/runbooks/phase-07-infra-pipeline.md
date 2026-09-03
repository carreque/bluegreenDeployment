# Runbook — Phase 7: the infrastructure pipeline, and the handover

**Date:** 2026-08-29
**Layer:** `infra/foundation`
**Estimated time:** 60–90 minutes. The apply itself is 2–3 minutes; the two
exit-criteria runs are mostly waiting on approvals you give yourself
**Cost while it exists:** close to nothing. CodePipeline V2 bills per action
execution, CodeBuild bills per build-minute on `BUILD_GENERAL1_SMALL`, and a
full four-layer run is roughly twenty build-minutes. The three log groups and
two SSM parameters are free at this volume

The Terraform, both new scripts and the three buildspecs were written and
verified in Phase 7 with no AWS session — 35 Terraform test runs across five
files, all green, plus the scope-gate matrix executed — and **neither of the
phase's two exit criteria is met by that branch.** Both need a pipeline that
exists and a run that happened. They are met here, at steps 6 and 7.

> **Step 4 is the handover.** `make apply-foundation` creates the pipeline, and
> from the next merge onward the pipeline applies itself. It is the last apply
> of this layer that has to be local — except in the repair case, which is
> step 9, and which is why that step exists at all.

**From this phase on, merging to `main` is what fires a deployment**
(roadmap §2.1). The merge button becomes the release control, and the four
manual approvals are what stand between a merge and production. Read that
sentence again before step 6, because it is true from the moment step 4
finishes.

---

## 1. Preconditions

Three, and the first two are the ones that fail loudly at the wrong moment.

**`foundation` is applied and its CodeConnections link is `AVAILABLE`.**
Terraform creates the link `PENDING` and a human finishes it with one click in
the console (Phase 3 runbook, manual step 1). The pipeline's Source stage fails
on a `PENDING` connection with an error that does not mention the console.

```bash
aws codeconnections get-connection \
  --connection-arn "$(terraform -chdir=infra/foundation output -raw github_connection_arn)" \
  --query 'Connection.ConnectionStatus' --output text
# AVAILABLE
```

If it says `PENDING`: Developer Tools → Settings → Connections → the connection
→ **Update pending connection**, and authorise the GitHub app against
`carreque/bluegreenDeployment`.

**Both image-tag parameters hold a real tag.** The two environment layers
declare `image_tag` with no default and read it from `terraform.tfvars`, which
`.gitignore` excludes — so a CodeBuild workspace has no value at all and
`terraform plan -input=false` fails with `No value for required variable`
before it authenticates to anything (plan §F7). `scripts/seed-ecr.sh` writes
both parameters now, on the push path **and** on the already-seeded path.

```bash
make seed-ecr
aws ssm get-parameter --name /bgd/prod/image_tag --query Parameter.Value --output text
aws ssm get-parameter --name /bgd/staging/image_tag --query Parameter.Value --output text
```

Expected: a real tag such as `0.1.0-a1b2c3d`, not `unset` and not `None`.

The parameters do not exist until this phase's apply has run, so on a first
pass this check belongs **after** step 4. `make seed-ecr` is idempotent and
running it twice costs nothing; run it again after the apply if the parameters
were not there before.

If a plan later reports `is 'unset' — run 'make seed-ecr'`, this is the step
that was skipped.

**The branch is merged, or is about to be.** The pipeline sources from `main`
through the connection above. A run cannot be started against a branch.

---

## 2. AWS session

```bash
aws sso login --profile bootcamp-administrator-access
make verify-aws
```

---

## 3. Re-run the offline gate against the real toolchain

The same command the branch was gated on, now on a machine that has
credentials. It should not behave differently, and that is the point: nothing
about the gate depended on being offline.

```bash
make tf-check
```

Expected: `all infra checks passed`. 35 Terraform test runs, tflint clean on
five layers, checkov `Failed checks: 0`.

---

## 4. The last local apply — **the handover**

```bash
make plan-foundation
```

Read it. Fourteen resources are created and one is changed:

| What | Count |
|---|---|
| `aws_iam_role` — pipeline, validate, plan, apply | 4 |
| `aws_iam_role_policy` — pipeline, validate, plan supplement | 3 |
| `aws_iam_role_policy_attachment` — `ReadOnlyAccess`, `AdministratorAccess` | 2 |
| `aws_codebuild_project` — validate, plan, apply | 3 |
| `aws_cloudwatch_log_group` — one per project | 3 |
| `aws_ssm_parameter.image_tag` — staging, prod | 2 |
| `aws_codepipeline.infra` | 1 |
| `aws_s3_bucket_lifecycle_configuration.artifacts` — **changed**, a second rule | 1 |

Nothing else in the layer should appear. A diff on the zone, the certificate,
the registry or the connection means something drifted and is not this phase's
business — stop and find out why before applying.

```bash
make apply-foundation
```

**This is the last apply of this layer that has to be local.** From here the
pipeline applies `foundation` itself, including changes to its own definition.
The exception is step 9.

---

## 5. Confirm the pipeline exists and is idle

```bash
aws codepipeline get-pipeline-state --name bgd-us-east-1-infra-pipeline \
  --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table
```

Expected: six stages — `Source`, `Validate`, `Foundation`, `Network`,
`Staging`, `Prod` — with no execution status yet. Confirm the order; it is
dependency order, and `Prod` is last.

Also confirm the variable and the trigger came through as V2 features, because
a V1 pipeline rejects them at apply rather than at plan:

```bash
aws codepipeline get-pipeline --name bgd-us-east-1-infra-pipeline \
  --query 'pipeline.{type:pipelineType,mode:executionMode,vars:variables,trigger:triggers}'
```

Expected: `pipelineType: V2`, `executionMode: QUEUED`, one variable
`DEPLOY_SCOPE` defaulting to `all`, and one trigger whose `filePaths.includes`
holds the four patterns from §D12.

---

## 6. Exit criterion 1 — a change to an environment layer flows through and applies

**Capture the baseline first.** You will want it in step 7 as well.

```bash
aws ecs describe-services --cluster bgd-us-east-1-prod \
  --services bgd-us-east-1-prod-api \
  --query 'services[0].taskDefinition' --output text | tee /tmp/prod-taskdef-before.txt
```

Make a genuinely trivial, honest change under `infra/` — a
comment, or `log_retention_days` from 14 to 15. Not a behaviour change, and not
something that only *looks* like a change: the point is to watch a real plan
reach a real approval.

Merge it to `main`. The trigger fires because the path matches `infra/**`.

```bash
aws codepipeline list-pipeline-executions --pipeline-name bgd-us-east-1-infra-pipeline \
  --max-items 1 --query 'pipelineExecutionSummaries[0].{id:pipelineExecutionId,status:status,trigger:trigger.triggerType}'
```

`triggerType` should be `Webhook` — the V2 trigger — and `DEPLOY_SCOPE` takes
its `all` default, because a git-triggered run cannot supply execution
variables (plan §F4).

Then follow it. Four approvals, in order:

| Stage | Expected approval message |
|---|---|
| Foundation | `No changes. foundation is up to date.` |
| Network | `No changes. network is up to date.` |
| Staging | a real `Plan: 0 to add, 1 to change, 0 to destroy.` and the resource address |
| Prod | `No changes. prod is up to date.` |

**Record the Staging approval message verbatim.** It is the evidence that the
plan reached the approval, which is the roadmap's stated requirement for this
criterion — not that the pipeline ran, but that a human approved a plan they
could read.

Approve each in turn:

```bash
aws codepipeline get-pipeline-state --name bgd-us-east-1-infra-pipeline \
  --query 'stageStates[?stageName==`Staging`].actionStates[?actionName==`Approve`].latestExecution.token' --output text
```

```bash
aws codepipeline put-approval-result \
  --pipeline-name bgd-us-east-1-infra-pipeline \
  --stage-name Staging --action-name Approve \
  --result summary="reviewed the plan",status=Approved \
  --token "<token from above>"
```

The console is easier and shows the message; the CLI is here so the runbook
does not depend on a browser.

**The criterion is met when the Staging `Apply` action succeeds** and a fresh
`make plan-staging` is empty — the change is in the account, applied by the
pipeline, from a plan a human read.

---

## 7. Exit criterion 2 — `DEPLOY_SCOPE=network` leaves production untouched

A git-triggered run always takes the default, so this one is started by hand.

```bash
aws codepipeline start-pipeline-execution \
  --name bgd-us-east-1-infra-pipeline \
  --variables name=DEPLOY_SCOPE,value=network
```

Approve `Foundation` and `Network` when they ask. Then prove it three ways
rather than one:

**a. The two later stages report `Skipped`.**

```bash
aws codepipeline get-pipeline-state --name bgd-us-east-1-infra-pipeline \
  --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table
```

Expected: `Staging` and `Prod` both `Skipped`.

**b. The execution's overall status is `Succeeded`, not `Failed`.**

```bash
aws codepipeline list-pipeline-executions --pipeline-name bgd-us-east-1-infra-pipeline \
  --max-items 1 --query 'pipelineExecutionSummaries[0].status' --output text
# Succeeded
```

This is the roadmap's requirement and it is what keeps Phase 9's
change-failure-rate honest: a deliberately narrow run is not a failure, which
is why the condition's result is `SKIP` and not `FAIL`.

**c. Production's task definition revision is unchanged.**

```bash
aws ecs describe-services --cluster bgd-us-east-1-prod \
  --services bgd-us-east-1-prod-api \
  --query 'services[0].taskDefinition' --output text
diff <(cat /tmp/prod-taskdef-before.txt) <(aws ecs describe-services \
  --cluster bgd-us-east-1-prod --services bgd-us-east-1-prod-api \
  --query 'services[0].taskDefinition' --output text) && echo "prod untouched"
```

### This step also retires F2

`rule.configuration` is an untyped `map(string)`: the provider validates
nothing inside it and the service validates it at execution time, so whether
`MATCHES` is an accepted `VariableCheck` operator could not be confirmed
offline (plan §F2).

- **If `Staging` reports `Skipped`** — `MATCHES` works. Record that, and record
  that it worked *for the reason we thought*, which is a different finding from
  "it worked".
- **If `Staging` runs instead of skipping** — `MATCHES` was rejected or
  evaluated false-negative. Production is still safe: the Plan build re-reads
  `DEPLOY_SCOPE` and refuses the layer itself (plan §D4), so the stage passes
  having applied nothing and the cost is two approvals nobody wanted. The fix
  is F2's fallback — change `DEPLOY_SCOPE`'s accepted values to the ordinals
  `1`, `2`, `3`, `4` and every rule to `LTE <n>`. It is a Terraform-only change:
  `scripts/pipeline-terraform.sh` already ranks the scope numerically, so only
  `local.pipeline_layers`' `scope_operator`/`scope_value` and the script's two
  `case` blocks move.

Record which happened either way, in
`docs/phases/phase7/2026-08-29-local-verification.md` §6.

---

## 8. Read the approval message and the plan link

Open any of the four approvals from step 6 in the console.

- **`CustomData`** must show a real summary — `No changes. network is up to
  date.` or a `Plan:` line with resource addresses. If it shows the literal
  `#{PlanStaging.PLAN_SUMMARY}`, the name the buildspec exports and the name the
  approval interpolates disagree. The offline test
  `the_buildspec_still_exports_what_the_approval_interpolates` is what normally
  catches that; a literal here means the interpolation side changed.
- **`ExternalEntityLink`** must open the CodeBuild log for that layer's Plan
  build. It is empty when `CODEBUILD_BUILD_ARN` was unset, which cannot happen
  inside CodeBuild — an empty link means the Plan action did not run.

---

## 8a. When a run cancels itself after Foundation

*Added 2026-08-31.* A run whose actions are all green but whose execution reads
`Cancelled` has almost certainly updated the pipeline's own definition:

```bash
aws codepipeline list-pipeline-executions --pipeline-name bgd-us-east-1-infra-pipeline \
  --max-items 1 --query 'pipelineExecutionSummaries[].[status,statusSummary]' --output text
# Cancelled    Pipeline definition was updated
```

CodePipeline cancels any in-flight execution when the pipeline structure
changes, so Foundation applies the new definition and the run stops there —
Network, Staging and Prod never execute. Nothing is broken and nothing needs
repairing; the fix is to start a second run:

```bash
aws codepipeline start-pipeline-execution --name bgd-us-east-1-infra-pipeline
```

Its Foundation stage plans no changes, and the run continues to the layers the
first one never reached. **Budget two runs for any change that touches the
trigger, the stages, the actions or the execution variables.** Section 9 below
covers the different, louder case where the new definition is broken.

---

## 9. Repairing a broken pipeline definition by local apply

Listed as a planned Phase 7 runbook since Phase 3, and this is it. **Do not
break anything to practise it.**

The situation: a change merged to `main` leaves the pipeline unable to run its
own `Source` or `Validate` stage — a malformed `trigger` block, a buildspec
path that does not exist, a service role the projects cannot assume. The
pipeline manages the layer that contains it (roadmap §1), so it cannot apply
the fix to itself. Every subsequent merge queues behind a pipeline that cannot
start.

The recovery:

```bash
git revert <the offending commit>
git push origin main

aws sso login --profile bootcamp-administrator-access
make plan-foundation      # read it: it should undo exactly what broke
make apply-foundation
```

Then confirm the pipeline can start again:

```bash
aws codepipeline start-pipeline-execution --name bgd-us-east-1-infra-pipeline \
  --variables name=DEPLOY_SCOPE,value=foundation
```

**The state lock.** If an execution is stuck holding `foundation`'s lock, the
local apply fails with a lock error naming a lock ID. Confirm the execution is
really finished — `list-pipeline-executions` — and only then:

```bash
terraform -chdir=infra/foundation force-unlock <ID from the error message>
```

Forcing a lock that a running apply still holds is how two applies corrupt one
state file. The check is not optional.

---

## 10. What goes wrong

**The Source stage fails with an access or connection error.** The
CodeConnections link is `PENDING`. Step 1.

**A Plan build dies with `/bgd/<env>/image_tag is 'unset'`.** `make seed-ecr`
has not run since this phase created the parameters. Step 1. The message names
the command deliberately — the alternative was passing a tag that was never
pushed to `data.aws_ecr_image` and failing one layer deeper, with a message
about a missing image rather than a missing tag.

**A Plan build dies with `No value for required variable "image_tag"`.** The
SSM lookup did not happen at all, which means the build ran something other
than `scripts/pipeline-terraform.sh plan <layer>`, or `LAYER` was not one of
`staging`/`prod`. Check the action's `EnvironmentVariables` override.

**An Apply fails with a stale-plan error.** The layer's state moved between the
Plan and the Apply — almost always a local `make apply-<layer>` racing the
pipeline. **Failing is correct.** The saved plan is bound to the state serial it
was made against, and the alternative — an apply that re-plans — would succeed
and silently do something nobody approved (plan §D9). Recovery: let the
execution fail, then start a new run. The new plan is against current state and
the approval is meaningful again.

**An approval expires.** CodePipeline expires a pending manual approval after
seven days and the execution fails. Start a new run; nothing is half-applied,
because the approval sits before the Apply action.

**`MATCHES` is rejected.** Step 7, and the fallback is there.

**The apply build times out on prod.** The apply project's timeout is 60
minutes and prod's service sets `wait_for_steady_state`, so an apply that starts
a blue/green deployment does not return until green has been provisioned,
tested by three hooks, promoted and baked for five minutes under the alarms —
six to ten minutes when it goes well (Phase 6 §D11). A timeout means the
deployment stalled or rolled back. Look at the ECS deployment and the hook logs
first, per the Phase 6 runbook §16; the build timeout is a symptom, not a cause.

**The Validate stage fails pulling the tflint or checkov image.** Anonymous
pulls from public registries are rate-limited. Re-run the stage. If it becomes
routine, the fix is an ECR pull-through cache — noted in the plan's §6 and
deliberately not built for a problem that has not happened.

**Two merges land in quick succession.** Both run, in order. `execution_mode`
is `QUEUED`, not the `SUPERSEDED` default, precisely so the second does not
cancel a run whose approval someone is part-way through reading (plan §D11).

---

## 11. Teardown

Unchanged, and nothing here is part of it. `make teardown` destroys `prod`,
then `staging`, then `network`. The pipeline, its projects, its roles and both
SSM parameters live in `foundation`, which teardown does not touch — which is
the second reason §D8 put the image tag there: a Phase 10 rebuild plans against
the tag that was deployed before the teardown.
