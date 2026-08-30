# Runbook — Phase 8: the application pipeline, and the loop closing

**Date:** 2026-08-30
**Layer:** `infra/foundation`
**Estimated time:** 90–120 minutes. The apply is 2–3 minutes; the exit-criteria
run is a full build, a staging deployment, a smoke, an approval you give
yourself, and a production blue/green deployment that bakes for five minutes
**Cost while it exists:** small and per-run. CodePipeline V2 bills per action
execution; CodeBuild bills per build-minute, and a full run is roughly fifteen
to twenty-five build-minutes across five projects — the ARM image build is the
long pole. The five log groups are free at this volume, and the SBOMs and test
reports are tens of kilobytes each

The Terraform, three new scripts, one refactored script and five buildspecs
were written and verified in Phase 8 with no AWS session — 65 Terraform test
runs across seven files, all green, plus both scope-gate matrices executed and
the build script run end-to-end locally. **The phase's exit criterion is not
met by that branch.** It needs a pipeline that exists, a merge that happened
and a deployment that ran. It is met here, at step 6.

> **Step 5 is the moment the loop closes.** From the next `app/**` merge
> onward, a commit becomes a production blue/green deployment behind **one**
> approval — not the four the infra pipeline asks for. That is intended, it is
> the whole point of the phase, and the compensating controls are Phase 6's:
> the dark canary hook, the bake alarms, and `wait_for_steady_state` making a
> rollback fail the build. Read that sentence again before step 6.

---

## 1. Preconditions

Five, and the first three fail loudly at the wrong moment.

**Phases 3 through 7's runbooks have been executed.** This phase deploys to
staging and production, so both environment layers must exist, and it sources
through the same CodeConnections link the infra pipeline uses.

**The CodeConnections link is `AVAILABLE`.** Terraform creates it `PENDING` and
a human finishes it with one click (Phase 3 runbook, manual step 1). This
matters more here than it did in Phase 7: with `CODEBUILD_CLONE_REF` the
**build** performs the clone, so a bad connection fails inside a CodeBuild
build with an access-denied message naming the connection rather than at the
Source stage.

```bash
aws codeconnections get-connection \
  --connection-arn "$(terraform -chdir=infra/foundation output -raw github_connection_arn)" \
  --query 'Connection.ConnectionStatus' --output text
# AVAILABLE
```

**An image is already seeded and both parameters hold a real tag.** This
pipeline writes them itself from now on, but the *first* production plan still
has to resolve a tag that exists, and the environment layers cannot be applied
at all without one.

```bash
make seed-ecr
aws ssm get-parameter --name /bgd/staging/image_tag --query Parameter.Value --output text
aws ssm get-parameter --name /bgd/prod/image_tag    --query Parameter.Value --output text
```

Expected: a real tag such as `0.1.0-a1b2c3d`, not `unset` and not `None`.

**Both environments are up.** The staging smoke action is a real HTTP probe
against `staging-api.carloscloudengineer.com`, and the production apply drives
a blue/green deployment of a running service.

```bash
make smoke-staging
make smoke-prod
```

**Nothing else is mid-apply.** This phase's applies and the infra pipeline's
contend on the same state locks. Check the infra pipeline is idle:

```bash
aws codepipeline list-pipeline-executions --pipeline-name bgd-us-east-1-infra-pipeline \
  --max-items 1 --query 'pipelineExecutionSummaries[0].status' --output text
# Succeeded
```

---

## 2. AWS session

```bash
make verify-aws
```

Expected: account `590184028094`, region `us-east-1`.

---

## 3. Re-run the offline gate against the real toolchain

The branch's gate ran on a machine with no session. Run it again here, because
the point of the gate is that a green pipeline and a green laptop mean the same
thing.

```bash
make tf-check
```

Expected: `all infra checks passed`. 65 test runs in the foundation layer,
tflint clean on all five layers, checkov `Failed checks: 0`.

---

## 4. Read the plan before applying it

```bash
make plan-foundation
```

Expected, and count them — a surprise here is a surprise about what the branch
contains, and this is the last cheap moment to notice:

| Resource | Count |
|---|---|
| `aws_iam_role` | 6 |
| `aws_iam_role_policy` | 6 |
| `aws_iam_role_policy_attachment` | 3 |
| `aws_codebuild_project` | 5 |
| `aws_cloudwatch_log_group` | 5 |
| `aws_codepipeline` | 1 added, 1 **changed** |

**The changed one is the point of this check.** `aws_codepipeline.infra` is
modified, not replaced, and the only difference should be its trigger's
`file_paths.includes` — `pipelines/**` narrowing to `pipelines/infra-*.yml`,
`scripts/pipeline-*.sh` narrowing to `scripts/pipeline-terraform.sh`, and
`scripts/tf.sh` and `scripts/lib/common.sh` joining the list. If the plan shows
that pipeline being replaced, or shows any of its stages changing, stop and
read the diff.

Also verify the artifact bucket gains **one** lifecycle rule and that its
prefix is `bgd-us-east-1-app-pipeline/`. A rule with no prefix, or one matching
`app-builds/`, would delete the SBOM history design §4.2 asked for — thirty
days after each deployment, silently. The offline suite asserts against both,
and this is the same check with real values.

---

## 5. Apply

```bash
make apply-foundation
```

Two to three minutes. Nothing in this apply touches a running service.

Then confirm the shape:

```bash
aws codepipeline get-pipeline --name bgd-us-east-1-app-pipeline \
  --query 'pipeline.stages[].{stage:name,actions:actions[].name}' --output table
```

Expected: `Source`, `Build`, `DeployStaging` (`Deploy`, `Smoke`), `Prod`
(`Plan`, `Approve`, `Apply`).

**And confirm the infra pipeline's trigger narrowed as intended** — the change
this apply made to a pipeline that already existed:

```bash
aws codepipeline get-pipeline --name bgd-us-east-1-infra-pipeline \
  --query 'pipeline.triggers[0].gitConfiguration.push[0].filePaths.includes' --output json
```

Expected exactly:

```json
["infra/**", "pipelines/infra-*.yml", "scripts/pipeline-terraform.sh",
 "scripts/install-terraform.sh", "scripts/tf.sh", "scripts/lib/common.sh"]
```

If `pipelines/**` is still there, the apply did not include the amendment and
the next application-buildspec edit will fire a four-approval infrastructure
deployment alongside the application one (plan §F4).

The application pipeline's own filter is split across **two** push blocks,
because the service caps `filePaths.includes` at eight patterns and the list has
eleven (plan §F11). Both must carry the branch filter:

```bash
aws codepipeline get-pipeline --name bgd-us-east-1-app-pipeline \
  --query 'pipeline.triggers[0].gitConfiguration.push[].{branches:branches.includes,paths:filePaths.includes}' \
  --output json
```

Expected: two entries, each with `branches: ["main"]`, and eleven paths between
them. A push block without a branch filter matches **every** branch — that
would deploy a feature branch's commit to production.

---

## 6. The exit criterion — a commit under `app/` reaches production

> **From here on, merging to `main` deploys the application.** One approval
> stands between the merge and production.

**Capture the baseline first.**

```bash
curl -s https://api.carloscloudengineer.com/version | tee /tmp/prod-version-before.json
aws ssm get-parameter --name /bgd/prod/image_tag --query Parameter.Value --output text \
  | tee /tmp/prod-tag-before.txt
```

Make a genuinely real change under `app/` — something `/version` or a test can
see. A version bump in `app/VERSION`, or a new field on an existing response, is
better than a comment: the point is to watch a real image reach production and
report itself.

Merge it to `main`. The trigger fires because the path matches `app/**`.

```bash
aws codepipeline list-pipeline-executions --pipeline-name bgd-us-east-1-app-pipeline \
  --max-items 1 \
  --query 'pipelineExecutionSummaries[0].{id:pipelineExecutionId,status:status,trigger:trigger.triggerType}'
```

`triggerType` should be `Webhook` — the V2 trigger — and `APP_SCOPE` takes its
`all` default, because a git-triggered run cannot supply execution variables.

### 6a. Build

Watch `/aws/codebuild` or the build's own group:

```bash
aws logs tail /bgd/us-east-1/shared/app-image --follow
```

What to look for, in order:

- the two containers start, then `135 passed` and a coverage line **at or above
  90%**. This is the same suite `make test` runs, on the same interpreter,
  reached differently (plan §D10)
- `built bgd-us-east-1-api:<tag>` where the tag is `<VERSION>.<build number>-<7
  char sha>` — the build number makes it monotonic across the project's life,
  and there is **no** `-dirty` suffix, because a clone of a commit is never
  dirty
- `SBOM written — N packages`
- `pushed …` and a digest
- the four `s3 cp` lines under `app-builds/<tag>/`

Then confirm the durable record exists:

```bash
aws s3 ls "s3://$(terraform -chdir=infra/foundation output -raw artifact_bucket_name)/app-builds/" --recursive | tail
```

Expected: `sbom.spdx.json`, `coverage.xml`, `junit.xml`, `build-metadata.json`
under the new tag.

**A failure here means the image was not built or not pushed, and nothing was
deployed.** That is the correct order.

### 6b. DeployStaging

Two actions. `Deploy` applies the staging layer with the new tag and then
records `/bgd/staging/image_tag`; `Smoke` runs `scripts/smoke.sh staging`
against the URL and digest the deploy handed it.

```bash
aws logs tail /bgd/us-east-1/shared/app-smoke --follow
```

Expected: four ticks — `/health`, `/ready`, `/version`, and `digest`. **The
fourth is the one that matters**: it asserts `/version`'s `image_digest` equals
the digest Terraform deployed, which is what makes this a deployment check
rather than a liveness check. It is also the assertion the standard ECS deploy
action would have failed on every single deploy (plan §F1).

A red `Smoke` with a green `Deploy` means the deployment succeeded and the
service is wrong — the two failures the separate action exists to
distinguish.

### 6c. Prod — plan, approve, apply

Read the approval message. It is a real plan, and it should name the task
definition and the service:

```bash
aws codepipeline get-pipeline-state --name bgd-us-east-1-app-pipeline \
  --query 'stageStates[?stageName==`Prod`].actionStates[?actionName==`Approve`].latestExecution' \
  --output json
```

**Record the approval message verbatim.** It is the evidence that a human
approved a specific change — this digest, this revision — rather than a
description of one.

```bash
aws codepipeline get-pipeline-state --name bgd-us-east-1-app-pipeline \
  --query 'stageStates[?stageName==`Prod`].actionStates[?actionName==`Approve`].latestExecution.token' \
  --output text

aws codepipeline put-approval-result \
  --pipeline-name bgd-us-east-1-app-pipeline \
  --stage-name Prod --action-name Approve \
  --result summary="reviewed the plan",status=Approved \
  --token "<token from above>"
```

### 6d. What to watch while the bake runs

The apply blocks for six to ten minutes and **this is the phase's whole
demonstration**. The build looks hung; it is not. Four things to watch, in
three terminals:

```bash
# 1. The two ports. :443 serves the current colour; :8443 is the test listener,
#    which points at GREEN as soon as it is provisioned — before any user
#    traffic shifts. The digests differ during the bake, and that difference IS
#    the blue/green deployment.
watch -n5 'curl -s https://api.carloscloudengineer.com/version | jq -c .; \
           curl -sk https://api.carloscloudengineer.com:8443/version | jq -c .'

# 2. The three hook log groups. The dark canary hook is the one that runs
#    against green before any traffic moves.
aws logs tail /aws/lambda/bgd-us-east-1-prod-pre-scale-up --follow
aws logs tail /aws/lambda/bgd-us-east-1-prod-post-test-traffic-shift --follow
aws logs tail /aws/lambda/bgd-us-east-1-prod-post-production-traffic-shift --follow

# 3. The deployment itself.
watch -n10 'aws ecs describe-services --cluster bgd-us-east-1-prod \
  --services bgd-us-east-1-prod-api \
  --query "services[0].deployments[].{status:status,rollout:rolloutState,desired:desiredCount,running:runningCount}" \
  --output table'
```

### 6e. The criterion is met when

1. the `Prod`/`Apply` action succeeds
2. `curl https://api.carloscloudengineer.com/version` reports the **new**
   digest, and it differs from `/tmp/prod-version-before.json`
3. `/bgd/prod/image_tag` holds the new tag — written **after** the apply, not
   before (step 7 checks this directly)
4. `make plan-prod` is empty

```bash
diff <(jq -r .image_digest /tmp/prod-version-before.json) \
     <(curl -s https://api.carloscloudengineer.com/version | jq -r .image_digest) \
  && echo "UNCHANGED — the deployment did not happen" \
  || echo "changed — production is serving the new image"
```

---

## 7. `APP_SCOPE` — the two narrow runs

A git-triggered run always takes the `all` default, so both are started by hand.
Each proves the two gates agree: the stage condition skips, and
`scripts/pipeline-deploy.sh` would have refused anyway (plan §D4).

**`APP_SCOPE=build` — build and push, deploy nothing.** This is the mechanism
Phase 11 uses to put a deliberately broken image in the registry.

```bash
aws codepipeline start-pipeline-execution \
  --name bgd-us-east-1-app-pipeline \
  --variables name=APP_SCOPE,value=build
```

**`APP_SCOPE=staging` — stop after the staging smoke.**

```bash
aws codepipeline start-pipeline-execution \
  --name bgd-us-east-1-app-pipeline \
  --variables name=APP_SCOPE,value=staging
```

For each, prove it three ways rather than one:

**a. The out-of-scope stages report `Skipped`.**

```bash
aws codepipeline get-pipeline-state --name bgd-us-east-1-app-pipeline \
  --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table
```

Expected for `build`: `DeployStaging` and `Prod` both `Skipped`. For `staging`:
`Prod` only.

**b. The execution's overall status is `Succeeded`, not `Failed`.**

```bash
aws codepipeline list-pipeline-executions --pipeline-name bgd-us-east-1-app-pipeline \
  --max-items 1 --query 'pipelineExecutionSummaries[0].status' --output text
# Succeeded
```

This is what keeps Phase 9's change-failure-rate honest: a deliberately narrow
run is not a failure, which is why the condition's result is `SKIP` and not
`FAIL`, and why a declined approval was rejected as the mechanism.

**c. Production is untouched.**

```bash
aws ssm get-parameter --name /bgd/prod/image_tag --query Parameter.Value --output text
curl -s https://api.carloscloudengineer.com/version | jq -r .image_digest
```

Both unchanged from step 6.

### This step also retires Phase 7's F2

`MATCHES` could not be confirmed as a `VariableCheck` operator offline: the
rule's `configuration` is an untyped `map(string)`, so the provider validates
nothing and the service decides at execution time. The `staging` condition uses
it; `prod` uses `EQ`, which is certainly supported.

- If `DeployStaging` **skips** under `APP_SCOPE=build` and **runs** under
  `APP_SCOPE=staging`, `MATCHES` works. Record it here and in the verification
  document, and F2 is closed for both pipelines.
- If the stage runs when it should have skipped, the operator is not supported.
  **Nothing bad happened** — `scripts/pipeline-deploy.sh` refused, the action
  reported the skip and the stage is green. The fix is the fallback both plans
  name: give each environment an ordinal and compare with `LTE`.
- If it fails the execution rather than skipping, the *result* is wrong rather
  than the operator; check `result = "SKIP"`.

---

## 8. Confirm D9 directly — the parameter is written after, not before

The whole of D9 in two commands, and it is worth doing deliberately because
the failure it prevents is silent.

Start a run and, **while the production approval is still pending**, check the
parameter:

```bash
aws ssm get-parameter --name /bgd/prod/image_tag --query Parameter.Value --output text
```

Expected: **the OLD tag.** The build has finished and pushed a new image, and
production does not yet claim to be running it — because nothing has deployed
it. If this shows the new tag while the approval is open, the write has moved
earlier and the hole is open: an `infra/**` merge landing now would plan
production against the new tag and deploy it, bypassing the approval, with
every stage of both runs green.

Then approve, wait for the apply, and check again — it now holds the new tag.

Finally, prove the infra pipeline agrees:

```bash
make plan-prod
```

Expected: `No changes.` The two pipelines now describe the same production.

---

## 9. What goes wrong

**`The security token included in the request is invalid` in a build.** The
build's service role, not your session. Check the project's `service_role` and
that role's trust policy carries `aws:SourceAccount`.

**The Build stage fails on `git rev-parse`.** `OutputArtifactFormat` is not
`CODEBUILD_CLONE_REF`. `image_build_identity()` derives the tag,
`SOURCE_DATE_EPOCH` and `BUILT_AT` from git, and a `CODE_ZIP` workspace has no
`.git`. Do **not** fix it with a fallback to `CODEBUILD_RESOLVED_SOURCE_VERSION`
and the wall clock — that compiles and silently ends the reproducibility
Phase 2 measured (plan §F2).

**The Build stage fails cloning, with an access-denied naming the connection.**
The role is missing `codeconnections:UseConnection`. With a clone reference the
*build* does the clone, so the pipeline role having it is not enough (plan §D8).

**The ECS task fails at start with an exec format error.** The image was built
on x86. `app_image` must be `ARM_CONTAINER`; an amd64 manifest pushes cleanly
and fails minutes later, which is why the offline suite asserts on the compute
type.

**`Can't set variables when applying a saved plan`.** A `-var` reached the
production apply. It must not: the plan file already holds the values it was
made with, and that is what makes the approval mean something.

**The production apply fails with a stale-plan error.** The layer's state moved
between the plan and the apply — almost always a local `make apply-prod` racing
the pipeline, or an `infra/**` run applying prod in between. Failing is
correct. Re-run the pipeline execution; do not apply by hand to "unblock" it,
because the plan a human approved no longer describes the account.

**The production apply fails after eight minutes with the service healthy.**
Read it as a *successful rollback*, not a pipeline fault: `wait_for_steady_state`
does not return until green has baked, and a bake that trips an alarm rolls back
and fails the apply. `/bgd/prod/image_tag` is deliberately not written, so it
still names the image actually serving and the next `infra/**` plan is a no-op
rather than a re-attempt of the deployment that just rolled back.

**Both pipelines fire on one merge.** A path matched both triggers. Check step
5's narrowing landed, and remember `install-terraform.sh`, `tf.sh` and
`lib/common.sh` are in **both** filters deliberately — a change to any of the
three genuinely does change what every stage of both pipelines does.

**A build hangs at the two-container test step.** A public registry pull is
rate-limiting. All the pins are digest-pinned, none is rate-limit-proof; the
fix, if it becomes routine rather than occasional, is an ECR pull-through
cache. Noted, not built.

**Repairing a broken pipeline definition.** Identical to the Phase 7 runbook's
step 9 and it applies to this pipeline too: both live in the layer they deploy
from, so a change that breaks either definition cannot be repaired by that
pipeline and needs a local `make apply-foundation`.

---

## 10. What this phase does not cover

- **Notification.** Nothing here notifies anyone of a failed build, a failed
  deployment or a rollback. Phase 9 owns it and attaches to this pipeline's
  execution state changes through EventBridge, exactly as it attaches to Phase
  6's alarms and Phase 7's pipeline. Deliberately not done twice (plan §D17).
- **Rollback evidence.** Phase 11 owns the three demonstrations and needed this
  pipeline to exist first. `APP_SCOPE=build` is the mechanism it uses to push a
  broken image without deploying it.
- **Deployment metrics.** Phase 9 reads `app-builds/` and the pipeline's
  execution history for deployment frequency, lead time and change failure
  rate. This phase is what makes those numbers describe a process that exists.

---

## 11. Teardown

Nothing here changes the teardown story. `make teardown` destroys prod, staging
and network; `foundation` survives, so **both pipelines survive a teardown** —
along with the artifact bucket and every SBOM in it.

One consequence worth knowing before you walk away: the pipelines stay armed —
and since Phase 10 that is safe. `make teardown` lowers
`/bgd/platform/deployed_scope`, and both pipeline drivers clamp their own scope
to it, so a merge to `main` after a teardown validates, applies `foundation`,
builds and pushes an image, and skips every stage whose layer no longer exists.
The run finishes green, creates nothing, and Phase 9's change-failure-rate
correctly does not count it.

There is nothing to disable and nothing to re-enable. `make rebuild` raises the
marker again as its last act on each layer; see [the Phase 10
runbook](./phase-10-teardown-and-rebuild.md).
