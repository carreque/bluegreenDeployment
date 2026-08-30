# Runbook — Phase 10: teardown, the idle check, and the rebuild

**Date:** 2026-08-30
**Layers:** destroys `prod`, `staging` and `network`; touches `foundation` only
to move one SSM parameter. `bootstrap` is never reached.
**Estimated time:** 15–25 minutes for a full cycle, most of it waiting on the
NAT Gateway and on production's `wait_for_steady_state`. §7 has the breakdown.
**Cost:** this runbook is the one that *saves* money. A platform left up is
roughly **$99/month**; the same account after `make teardown` is roughly
**$1/month** — the hosted zone, a little S3 and a handful of log groups.

Three commands, in this order, and nothing else:

```bash
make teardown       # stop paying
make verify-idle    # prove it stopped
make rebuild        # start again, and prove it serves traffic
```

**This runbook meets the phase's exit criterion.** The branch does not: it
creates no AWS resource, and the roadmap asks for *a full teardown and rebuild
cycle executed and verified, not merely written*. Steps 3 through 6 are that
cycle. `make rebuild` exiting 0 is the criterion — by design it returns 0 only
after both environments were smoke-tested and served the digest Terraform
deployed.

---

## 1. What survives and what does not

Read this before running anything. It is the question people actually have.

| Survives `make teardown` | Destroyed |
|---|---|
| hosted zone, ACM certificate, both ECR repositories and every image | both ALBs and their listeners and target groups |
| the state bucket and every layer's state | both ECS clusters, services and task definitions |
| the artifact bucket, every SBOM and every test report | all four DynamoDB tables **and their contents** |
| the SNS topic and its confirmed subscription | the three lifecycle hook Lambdas |
| the CodeConnections authorisation | the four production bake alarms |
| both pipelines and all eight CodeBuild projects | the VPC, both NAT-facing subnets, the NAT Gateway and its Elastic IP |
| the collector Lambda, its log group and the dashboard | the application log groups and everything in them |
| all three SSM parameters | the two Route 53 records (recreated on rebuild, same names) |

**The DynamoDB tables are destroyed and rebuilt empty.** That is the one
irreversible thing a teardown does, and it belongs here rather than in a
footnote. Nothing in this project treats it as data loss —
`deletion_protection_enabled = false` is set explicitly on all four and the
Phase 5 plan's D6 argues why — but if you have put something in a table that
you want back tomorrow, export it first.

Everything in the left column lives in `foundation` or `bootstrap`, and **no
`SCOPE` value and no flag in any of these three scripts can reach either
layer.** That is the whole reason the platform is split into five layers rather
than four (roadmap §1). See §10 for what tearing down `foundation` would cost,
and why it is a paragraph here rather than a flag on a script.

---

## 2. Preconditions

**An AWS session.**

```bash
make verify-aws
```

Expected: account `590184028094`, region `us-east-1`.

That is the only precondition for a teardown. `make rebuild` has six more, all
read-only, and step 6 runs them for you before it spends anything.

---

## 3. Teardown

```bash
make teardown
```

The script prints the whole plan before it does anything:

```
==> teardown scope: network

  will destroy, in order:
    prod
    staging
    network

  will survive: foundation and bootstrap are never destroyed
  will record:  /bgd/platform/deployed_scope = foundation

  type "destroy" to continue:
```

Type the word `destroy`. Not `y`, not `yes` — the word. One typed confirmation
replaced the three consecutive Terraform prompts the first-cut script relied
on, because three identical prompts in a row is how the third one gets answered
by reflex.

Anything else aborts, and aborts **before** the marker is written, so declining
the prompt leaves the account exactly as it was.

`BGD_ASSUME_YES=1 make teardown` skips the prompt. Use it for a re-run after a
partial failure, not for the first run.

### What happens, in order

1. **The marker is lowered first.** `/bgd/platform/deployed_scope` becomes
   `foundation` before a single resource is destroyed. This is deliberate and it
   is the most important line in the script: writing it afterwards would leave a
   window, the whole length of the destroy, in which a merge to `main` lands,
   reads `all`, and starts applying into an account being dismantled underneath
   it — and a teardown that died half-way would never write it at all, leaving
   both pipelines believing production is up when `prod` is exactly what was
   destroyed first.
2. **Each layer is destroyed in order:** `prod`, then `staging`, then `network`.
   Destroying the network first would strand the ALBs and ECS services that
   depend on its subnets and fail part-way with a dependency violation, leaving
   the expensive half running.
3. **A layer whose state is empty is skipped and says so.** On a re-run after a
   partial failure this is the common case, and it saves a full `terraform
   destroy` cycle per already-destroyed layer.
4. **A timing table is printed.** §7 is filled in from it.

Expected tail:

```
  layer        outcome                      time
  -----        -------                      ----
  prod         destroyed                    4m12s
  staging      destroyed                    2m48s
  network      destroyed                    2m20s
  total                                     9m20s

  ✓ teardown complete — /bgd/platform/deployed_scope records foundation
==> run `make verify-idle` to confirm nothing billable survived
```

### If it fails part-way

The message says what is true:

```
  ✗ destroy failed for staging; later layers were not touched. The marker
    already reads foundation, so both pipelines will skip this layer — re-run
    once the cause is fixed.
```

Nothing is in an unknown state. The marker is already down, so both pipelines
are already skipping every layer above `foundation` — a merge landing while you
debug creates nothing. Fix the cause and re-run; the layers that already
destroyed cleanly are skipped on their empty state in seconds.

The usual cause is an ENI still attached to a subnet because an ECS task has not
finished draining. Wait two minutes and re-run.

---

## 4. Confirm it is idle

```bash
make verify-idle
```

A clean `terraform destroy` on three layers is not the same claim as "this
account is no longer billing", and the three cases where they differ are exactly
why this command exists: a resource created by hand and never in state, a state
file that drifted, and a destroy that failed part-way and left the expensive half
running. **So `verify-idle.sh` opens no state file.** Every check goes to AWS
directly, because state is precisely what is wrong in the cases it is for.

Expected:

```
==> verify-idle — scope network, prefix bgd-us-east-1-

  ecs services (prod)                ✓
  ecs services (staging)             ✓
  load balancers (prod)              ✓
  load balancers (staging)           ✓
  dynamodb tables (prod)             ✓
  dynamodb tables (staging)          ✓
  nat gateways                       ✓
  elastic ips                        ✓
  tagged sweep (ec2/elb/ecs/ddb)     ✓

  ✓ nothing billable survives in scope network
```

Exit 0 means nothing billable survived in scope.

### The two non-fatal results

**`nat gateways   ! 1 still deleting — re-run in a few minutes`.** NAT Gateway
deletion is asynchronous and the gateway lingers in state `deleting` for some
minutes. Billing has already stopped, so this is not a failure — but it is not a
clean pass either, and it matters if the next thing you do is a rebuild. Wait and
re-run.

**`tagged sweep   ! 3 resource(s) still indexed`.** The
`resourcegroupstaggingapi` is an index, not the resource, and it can list a
resource for some minutes after deletion — which is the exact moment this
command runs. It is reported as a warning and never as a verdict; the direct
`describe` calls above it carry the pass/fail. If the same ARNs are still listed
an hour later, look at them.

### A partial teardown has a partial answer

```bash
make teardown SCOPE=prod && make verify-idle SCOPE=prod
```

`SCOPE` is passed through, so `verify-idle` checks only what was destroyed: the
`prod` shapes always, `staging` only when staging was in scope, and the NAT
Gateway and Elastic IP only on a full teardown. Running the default
`make verify-idle` after `make teardown SCOPE=prod` would correctly fail on a
network that is supposed to still be there.

### What this deliberately does not check

**The bill.** Cost Explorer's data lags roughly a day, so run after a teardown it
reports yesterday — the day the platform was up — and reports it as though it
were the answer. A check whose green means nothing and whose red means nothing is
worse than no check, because somebody will trust it. Look at Cost Explorer the
next morning instead, filtered on `projectName=bgd`; `verify-idle` answers the
question that can be answered now.

---

## 5. What the pipelines do now

**Nothing needs disabling.** This replaces Phase 8's runbook §11, which told you
to disable both triggers in the console and re-enable them as the first step of
the rebuild. That instruction is obsolete.

Both pipelines stay armed, and since this phase that is safe. Each driver reads
`/bgd/platform/deployed_scope` and takes the smaller of its own scope and the
marker, so a merge to `main` while the platform is torn down:

- **still** runs Validate, applies `foundation`, and builds, tests and pushes an
  image — your work keeps flowing, and the image is waiting when you come back
- **creates** no network, no ALB and no Fargate task
- finishes **green**, so Phase 9's change-failure-rate correctly does not count
  it, and no alert email is sent

In the console the skipped stages read:

```
==> staging is torn down (/bgd/platform/deployed_scope = foundation) — nothing to do
==> run `make rebuild` to bring it back
```

That message is deliberately different from the scope message. `"staging is
outside DEPLOY_SCOPE=all"` would be a lie, and an operator reading it would spend
an hour looking for a bug in scope handling.

**The corollary, stated plainly: a merge can no longer rebuild a torn-down
layer.** That is the point rather than a side effect — the failure being
prevented is a $99/month surprise from a merge nobody thought of as a
deployment. `make rebuild` is the only thing that raises the marker. §9 has the
one-line escape hatch for the day you want the pipeline to do it instead.

`foundation` is exempt from the read, and must be: it is the layer that *creates*
the parameter, so on a fresh account it does not exist when `foundation` is first
planned. Every other layer treats an unreadable marker as fatal rather than
assuming `all` — a gate that fails open is not a gate.

---

## 6. Rebuild

### First, ask whether you could

```bash
BGD_REBUILD_DRY_RUN=1 make rebuild
```

This runs all six preconditions and stops before the first apply. Six read-only
calls, no resources, and it answers *could I rebuild right now?*

```
==> rebuild scope: prod

  will apply, in order:
    network
    staging
    prod

  will record:  /bgd/platform/deployed_scope = all

==> preconditions
  ✓ account 590184028094
  ✓ state bucket bgd-us-east-1-tfstate-590184028094
  ✓ foundation state present
==> marker currently reads foundation
  ✓ /bgd/staging/image_tag → 0.1.42-a1b2c3d, present in ECR
  ✓ /bgd/prod/image_tag → 0.1.41-9f8e7d6, present in ECR

  ✓ dry run — preconditions pass; nothing was applied and nothing was written
```

The six, in the order they run and by what each costs to get wrong:

1. **The account.** First, because a rebuild into the wrong account is not
   recoverable by re-running it.
2. **The state bucket** answers `head-bucket`.
3. **`foundation`'s state** is readable.
4. **The marker** is readable and holds a known value.
5. **Each environment's `image_tag`** is set and is not `unset` or `None`.
6. **Each of those tags is actually in ECR.** `data.aws_ecr_image` would catch a
   missing tag anyway — but at the *staging* layer, which is after `network`
   applied, which means a NAT Gateway exists and is billing while you work out
   that the tag was wrong. Ten seconds of read-only calls moves that discovery to
   before the first resource.

If a tag is `unset`, run `make seed-ecr` or let the app pipeline push one — the
message says so.

### Then do it

```bash
make rebuild
```

There is no confirmation prompt. A rebuild creates rather than destroys, and the
dry run above is where the deliberation belongs.

Order: `network`, then `staging`, then `prod`. Both environment layers read the
network's outputs through remote state, so applying either against a network that
does not exist is the failure this ordering prevents.

Two things it does that `make apply-network && make apply-staging && make
apply-prod` does not:

- **It takes `image_tag` from SSM**, exactly as the infra pipeline does. Locally
  the value would come from a gitignored `terraform.tfvars`, which is the right
  input when you are *changing* the tag and the wrong one when you are *restoring
  what was deployed before the teardown*. `make apply-staging` and `make
  apply-prod` are deliberately unchanged, so the by-hand override still exists.
- **It raises the marker**, one layer at a time, **after** each apply returns 0.
  A rebuild that dies at prod therefore leaves the marker reading `staging` —
  which is true. The marker may lag reality downward; never upward.

Each environment is smoked as it lands, with the same `scripts/smoke.sh` the
application pipeline runs — including the assertion that `/version`'s
`image_digest` equals the digest Terraform deployed, which is precisely the
question a rebuild raises. **Staging's smoke failing aborts the run before prod
applies.**

Expected tail:

```
  step             outcome      time
  ----             -------      ----
  network          applied      3m10s
  staging          applied      3m54s
  staging smoke    passed       0m08s
  prod             applied      6m31s
  prod smoke       passed       0m09s
  total                        13m52s

  ✓ rebuild complete — /bgd/platform/deployed_scope records all
```

**`make rebuild` exiting 0 is the exit criterion.** It returns 0 only if both
environments served traffic, not merely if three applies returned 0.

### If it fails part-way

The marker still reads what was true before the failing layer, so both pipelines
are already skipping the layers that do not exist. Fix the cause and re-run —
the layers that already applied are no-ops.

The one failure worth naming: prod's apply blocks on `wait_for_steady_state`, so
it does not return until green has been provisioned, tested by three hooks,
promoted and baked for five minutes under the alarms. A rollback during that bake
fails the apply. That is the blue/green controller working, not the rebuild
failing; the Phase 6 runbook covers reading it.

---

## 7. What a cycle costs in time

**These are estimates, not measurements.** Nobody has observed them yet, and a
number nobody has observed should not be printed as though somebody had. Both
scripts print a measured table specifically so the first real run replaces this
one. Fill in the right-hand column from that output.

| Step | Estimate | Measured |
|---|---|---|
| teardown, prod | 3–5 min | — |
| teardown, staging | 2–4 min | — |
| teardown, network | 2–3 min (the NAT dominates) | — |
| rebuild, network | 2–4 min | — |
| rebuild, staging + smoke | 4–6 min | — |
| rebuild, prod + smoke | 5–8 min (`wait_for_steady_state`) | — |

Rough total for a full cycle: **15–25 minutes**, most of it waiting.

---

## 8. Partial cycles

`SCOPE` is cumulative on both scripts and names where the run stops.

| `make teardown SCOPE=` | prod | staging | network | marker becomes |
|---|---|---|---|---|
| `prod` | destroy | — | — | `staging` |
| `staging` | destroy | destroy | — | `network` |
| `network` *(default)* | destroy | destroy | destroy | `foundation` |

| `make rebuild SCOPE=` | network | staging | prod | marker becomes |
|---|---|---|---|---|
| `network` | apply | — | — | `network` |
| `staging` | apply | apply | — | `staging` |
| `prod` *(default)* | apply | apply | apply | `all` |

An unrecognised value is refused by name on both, rather than falling back to
the safe end: a `SCOPE=staginng` typo that silently tore down everything would be
a bad surprise, and one that silently tore down nothing while printing success
would be worse.

**The useful partial is an app-only session:**

```bash
make teardown SCOPE=prod      # keep network and staging up
# … work on the application, deploy to staging, iterate …
make rebuild SCOPE=prod       # bring production back
```

That saves production's ALB and tasks — roughly $40/month prorated — while
leaving the NAT Gateway running, which is the larger cost. It is the right trade
when you will be back tomorrow and the wrong one when you will not: for anything
longer than a day, tear the whole thing down.

While the marker reads `staging`, the application pipeline still deploys to
staging on every merge and skips production green. That is usually exactly what
you want.

---

## 9. The escape hatch

`make rebuild` is the only thing that raises the marker. If you want the
*pipeline* to do the rebuild instead — merge to `main` and let it apply — raise
the marker by hand first:

```bash
aws ssm put-parameter \
  --region us-east-1 \
  --name /bgd/platform/deployed_scope \
  --value all \
  --type String \
  --overwrite
```

Read the value back with the output rather than typing the path again:

```bash
terraform -chdir=infra/foundation output -raw deployed_scope_parameter_name
```

**This is a claim about the account, not a change to it.** Writing `all` does not
create a NAT Gateway; it tells both pipelines they may. If you write `all` while
the platform is actually down, the next merge will attempt a full apply —
which is precisely what you asked for, but say it deliberately.

The marker is a **teardown marker, not a deployment registry.** It does not
observe a by-hand `make apply-prod`, so after one it can understate what exists.
That direction costs a stage skipping when it did not need to, visible in the
console and fixed by the command above. The opposite — deploying when it should
not — cannot happen, because the marker only ever restricts.

---

## 10. What this runbook cannot do: tear down `foundation`

There is no `SCOPE` value, no flag, and no undocumented path that reaches
`foundation` or `bootstrap`. That is a decision rather than an omission, and this
is what it would cost to undo:

- **The CodeConnections authorisation** would have to be re-clicked in the
  console. It is one of the project's three irreducibly manual steps.
- **The SNS email subscription** would be re-created `PendingConfirmation` and
  would have to be re-confirmed by email. Until it is, every alarm and every
  pipeline failure notification goes nowhere, silently — `plan` stays clean.
- **The ACM certificate** would have to re-validate through DNS. Minutes to
  hours, and both HTTPS listeners fail until it does.
- **Every SBOM, test report and build artifact** in the artifact bucket would be
  gone — that is the whole of design §4.2's history.
- **The entire metric history** behind the Phase 9 dashboard would be gone, and
  metrics cannot be backfilled.
- **The cost allocation tag activation** would survive, but only because it is an
  account-level setting rather than a resource.

`bootstrap` is further out still: it holds the state for every other layer, so
destroying it strands all of them.

Tearing down `foundation` is a real thing somebody might one day want. It is a
list of consequences to read first, not a flag on a script that also runs
routinely.

---

## 11. Related

- [Phase 4 — network](./phase-04-network.md), for the NAT Gateway's real cost
  and the egress proof.
- [Phase 8 — app pipeline](./phase-08-app-pipeline.md) §11, which now points
  here.
- [Phase 9 — observability](./phase-09-observability.md), for why a green
  skipped run matters to change-failure-rate.
- [Phase 10 implementation plan](../phases/phase10/2026-08-30-phase-10-implementation-plan.md),
  for the sixteen decisions behind all of the above.
