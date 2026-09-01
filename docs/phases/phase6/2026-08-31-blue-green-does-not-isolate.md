# Phase 6 — blue/green does not isolate the colours

**Date:** 2026-08-31
**Status:** **Closed 2026-09-01 — cause found, fix applied, verified end to
end against a real account.**
See [§7](#7-resolution-2026-09-01). Sections 1–6 are the contemporaneous
account and are left as written; §5's three candidate directions were all
wrong, and §5 says so where it stands.
**Severity:** This defeats the property the project exists to demonstrate.
**Evidence:** CloudTrail target registrations, ECS service events, a 10-second
sampling log of both listeners, three lifecycle hook log groups. On 2026-09-01,
CloudTrail `ModifyRule` and `UpdateService`, a `terraform plan` against live
prod, and one controlled deployment.

Production deploys, serves, bakes and rolls back. It does **not** separate the
two colours. Both revisions are registered in one target group for the whole
deployment, so the test listener cannot reach the new revision in isolation, the
dark canary validates whichever task it happens to hit, and users are served a
mix of old and new until the bake ends.

---

## 1. What was expected

ECS native blue/green, as designed in Phase 6 and as the `:8443` test listener
exists for:

1. New revision starts in the **alternate** target group.
2. The **test** listener rule points at the alternate. `POST_TEST_TRAFFIC_SHIFT`
   probes it — green is fully real and reachable, and **no user can reach it**.
3. Only if that hook passes does the **production** rule shift to the alternate.
4. The old revision stays registered, serving nothing, until the bake ends —
   which is what makes rollback instant.

The whole value is in step 2: a bad build dies against real infrastructure
before any user sees it.

## 2. What actually happens

```
21:48:38  RegisterTargets    prod-api-green   10.0.35.75, 10.0.22.73    ← the create
22:47:24  RegisterTargets    prod-api-green   10.0.29.182, 10.0.36.202  ← deployment 1
22:49:27  DeregisterTargets  prod-api-green   10.0.36.202, 10.0.29.182
22:55:29  RegisterTargets    prod-api-green   10.0.16.67, 10.0.47.57    ← deployment 2
23:02:09  DeregisterTargets  prod-api-green   10.0.35.75, 10.0.22.73
23:12:08  RegisterTargets    prod-api-green   10.0.35.3, 10.0.17.70     ← deployment 3
23:19:00  DeregisterTargets  prod-api-green   10.0.47.57, 10.0.16.67
```

**`bgd-us-east-1-prod-api-blue` has never held a single target.** Not on the
create, not on any deployment, not once across the entire life of two separate
services.

ECS's own events describe a rolling replacement rather than a shift:

```
23:12:08  registered 2 targets in … prod-api-green
23:18:50  has stopped 2 running tasks
23:19:00  deregistered 2 targets in … prod-api-green
23:19:53  deployment completed / has reached a steady state
```

Sampling both listeners every ten seconds through deployment 1 caught the
consequence directly — `greenTG` holding **four** targets, `blueTG` **zero**, and
the test listener answering with a different revision from one sample to the
next:

```
TIME      :443             :8443            blueTG  greenTG
22:47:28  unreachable      0.1.5-25153bc    0       4
22:47:41  unreachable      0.1.6-6f24d09    0       4     ← new
22:47:54  unreachable      0.1.5-25153bc    0       4     ← old
22:48:20  unreachable      0.1.6-6f24d09    0       4     ← new
```

And the hook that this project's safety argument rests on reported the outgoing
revision on **three consecutive deployments**:

```
stage=POST_TEST_TRAFFIC_SHIFT probed=…:8443 git_sha=1812039   (shipping caa0d21)
stage=POST_TEST_TRAFFIC_SHIFT probed=…:8443 git_sha=caa0d21   (shipping 25153bc)
stage=POST_TEST_TRAFFIC_SHIFT probed=…:8443 git_sha=25153bc   (shipping 6f24d09)
```

It has never once seen the revision it was invoked to judge.

## 3. What this costs

- **The dark canary is a coin flip.** With two old and two new tasks behind one
  group, a broken new revision has roughly even odds of being approved by a
  healthy old one. Design §4's "a bad build dies before any user sees it" is not
  currently true.
- **Users are served both revisions at once**, for the length of the bake — five
  minutes by configuration, about seven observed. A deployment is therefore a
  window in which the API answers inconsistently, which for a ledger is worse
  than it sounds.
- **There is a brief error window.** An earlier deployment produced eight
  `HTTPCode_ELB_5XX_Count` over roughly 100 seconds. Those were almost certainly
  this document's own probes rather than real users — worth stating plainly —
  but they prove the endpoint really returned errors in that window.
- **Nothing reports any of it.** Every deployment finished `SUCCESSFUL`, every
  alarm stayed `OK`, and both pipelines were green.

## 4. What has been ruled out

| Suspect | Verdict |
|---|---|
| Legacy of the aborted create | **Refuted.** `make teardown SCOPE=prod` + `make rebuild SCOPE=prod` produced a brand-new ALB, target groups and service. Identical behaviour on all four deployments since. |
| The Terraform configuration | Correct. `load_balancer.target_group_arn = blue`, `advanced_configuration.alternate_target_group_arn = green`, both listener rule ARNs, the dedicated role. Verified on the resource **and** on two `describe-service-revisions` outputs. |
| The listener rules | Terraform creates them on opposite colours — production→blue, test→green — which is what `edge.tftest.hcl` asserts. ECS then rewrites both to `green=100, blue=0`. |
| The wrong deployment strategy | `describe-services` reports `"strategy": "BLUE_GREEN"`, `bakeTimeInMinutes: 5`, four alarms with `rollback: true`, all three lifecycle hooks registered. |

So ECS is running blue/green, has been told which group is the alternate, and
places the replacement revision in the current group regardless.

## 5. What is not yet known

> **Superseded by [§7](#7-resolution-2026-09-01).** All three directions below
> were wrong, and the proposed experiment would have confirmed itself for the
> wrong reason — inverting the assignment moves the defect to the other colour
> without curing it. The cause was not in ECS at all. Kept as written, because
> what an investigation ruled *in* is part of its record.

Why. Candidate directions, none tested:

- Whether the two target groups differ in some attribute ECS requires them to
  share before it will alternate.
- Whether an alternate group must not be referenced by a listener rule at
  creation time — Terraform points `:8443` at green from the start, and green is
  the group ECS uses.
- Whether the provider sends `alternateTargetGroupArn` in a shape the service
  records but does not act on. It is present in `describe-services`, which
  argues against this but does not settle it.

**The cheapest next experiment** is to point the test listener rule at **blue**
instead of green — inverting Terraform's initial assignment — and deploy once.
If the alternation then engages, the initial rule assignment is the cause and
the fix is one line. If nothing changes, the next step is an AWS support case
with this document attached, because everything reproducible from outside has
been reproduced.

## 6. What this means for the project's claims

**Phase 6's exit criterion 2 is not met, and cannot be met by this
configuration.** *"/version returns different SHAs on :443 and :8443
mid-deployment"* requires the two listeners to reach different revisions. They
reach the same pool. The criterion is not merely unverified — it is currently
unachievable, and that is a stronger statement than any previous phase has had
to make about its own exit criteria.

**Phase 11's first demonstration is blocked.** *"Hook rejection — the bad build
never receives production traffic"* cannot be demonstrated honestly: the bad
build **would** receive production traffic, because it is in the pool the
production listener serves from before any hook runs.

**Design §1.5's argument for ECS-native over CodeDeploy is untouched.** Nothing
here suggests CodeDeploy would behave differently, and the reasoning that chose
ECS-native was about the API and the ownership model, not about this. But the
ADR Phase 11 owes on that choice should record this defect as an open cost of it
rather than presenting the decision as free.

Until this is resolved, the honest description of the production environment is:
**a rolling deployment with a bake period, alarm-triggered rollback and three
Lambda hooks — none of which observes the new revision in isolation.**

---

## 7. Resolution (2026-09-01)

**Terraform was reverting the colour assignment at the start of every
deployment.** The defect was in this repository, not in ECS or in the AWS
provider.

### How ECS actually chooses

ECS decides which target group is live by **reading the production listener
rule**. It does not read `alternateTargetGroupArn`, and it never swaps that
field — the pair `targetGroupArn` / `alternateTargetGroupArn` declares *which
two groups*, not *which role each holds*. The role lives on the rule.

That is why §4 ruled the Terraform configuration "correct" and was right to:
every field named there was set correctly. The defect was not in what was
declared but in the fact that it was **re-declared**, on every apply, over the
top of ECS's own decision.

### The loop

`aws_lb_listener_rule.production` and `.test` in `alb.tf` carried no
`lifecycle { ignore_changes = [action] }`. ECS rewrites both during the shift;
Terraform read that as drift; every apply reverted it seconds before the
deployment that apply had just started:

```
apply      → production rule ← blue (which holds nothing)
ECS        → reads the production rule: "blue is live"
             → deploys the incoming revision into the other one … green,
               where the outgoing revision already is
ECS        → shifts both rules to green=100, blue=0
next apply → reverts them, and the fixed point holds
```

The drift is **structural**, not a colour mismatch — the config declares a
single `target_group_arn` where ECS leaves a two-entry weighted forward — so the
revert fires on every apply from any starting state. That makes green an
attractor: from blue, ECS deploys into green and stays; from green, ECS deploys
into green and stays. The create enters it immediately, because the rules are
born pointing at an empty blue. That is all seven registrations in §2, and it is
why no deployment ever worked.

### The evidence

1. **CloudTrail `ModifyRule`.** Two calls from `app-deploy-prod-role` or
   `infra-apply-role` — one per rule — 5 to 21 seconds before the
   `prod-bluegreen-role` calls, on every cycle. `infra-apply-role` appears too:
   an `infra/**` merge reverted the colours with no application change involved.
2. **`terraform plan` against live prod.** `Plan: 0 to add, 2 to change, 0 to
   destroy` — exactly the two listener rules, and **no change to
   `aws_ecs_service.api`**.
3. **CloudTrail `UpdateService`.** No call from any caller carries a
   `loadBalancers` parameter, so the service's record is ECS's own and has never
   been written by Terraform. Both service revisions inspected carry an
   identical, unswapped `targetGroupArn = blue / alternate = green`.
4. **A controlled deployment.** With the rules left in ECS's own state
   (`green=100`, green holding both tasks, blue empty) and no `terraform apply`
   in front of it, `--force-new-deployment` produced:

   ```
   06:20:34Z  registered 2 targets in (target-group …/prod-api-blue/…)
   06:21:11Z  production rule → …-api-green   (outgoing, 2 tasks)
   06:21:11Z  test rule       → …-api-blue    (incoming, 2 tasks)
   06:21:13Z  hook invoked stage=POST_TEST_TRAFFIC_SHIFT probe_url=…:8443
   ```

   Blue held targets for the first time in the platform's life, the two colours
   separated, and the dark canary probed the incoming revision — with **no
   change to this repository**, only the absence of an apply.

### What else it was causing

`PRE_SCALE_UP` recorded "4 invocations, 0 rejected", which was never evidence
that `:443` was healthy. Three of those four were ordinary deployments where the
production rule had just been reverted to an empty blue, `:443` genuinely
returned 503, and `BGD_ALLOW_UNSERVED` logged it at `INFO` and proceeded. So
every deployment carried a real production outage window that nothing reported —
and the eight `HTTPCode_ELB_5XX_Count` in §3 were probably not only our own
probes. The control is in the same log group: the 2026-09-01 deployment, with no
apply in front of it, logged nothing. See
[the pre-scale record](./2026-08-31-pre-scale-hook-cold-start.md).

### The fix

`lifecycle { ignore_changes = [action] }` on both rules in
`infra/environments/prod/alb.tf`. Two blocks. Only the forward target is
ignored — `condition` stays managed, so path patterns remain Terraform's.

Deliberately **not** done: the same on `aws_ecs_service.api`'s `load_balancer`.
Terraform never writes that field, the plan confirms no change on it, and it is
a **set** in the provider schema — so `ignore_changes` could only take the whole
block, losing management of both rule ARNs and the `bluegreen` role ARN. Real
cost, no benefit.

`terraform test` cannot assert `lifecycle` meta-arguments, so nothing in the
layer's suite can pin this. A textual guard in `scripts/lint-infra.sh` fails if
either rule loses its block. It is a weak guard and is described as one where it
sits.

### What §6 now says

- **Exit criterion 2 is achievable.** The mechanism is demonstrated. What is not
  yet demonstrated is the criterion as written — *different SHAs on `:443` and
  `:8443`* — because `--force-new-deployment` redeploys the same image, so both
  listeners necessarily reported the same digest. That needs two deployments of
  genuinely different builds through the pipeline.
- **Phase 11's first demonstration is unblocked**, subject to the same
  verification.
- **Design §1.5's argument for ECS-native is now more than untouched.** The
  feature behaved correctly throughout. The ADR Phase 11 owes should record this
  as a cost of the *ownership model* — Terraform and a deployment controller both
  holding an opinion about the same mutable field — rather than a cost of the
  choice between ECS-native and CodeDeploy. CodeDeploy would have had the same
  problem in the same place.

### Verified end to end (2026-09-01, 14:18–14:55Z)

`make rebuild SCOPE=prod` from a destroyed account, then two deployments of
genuinely different builds. **All five observations hold, and the colours
alternate.**

**The free check first.** After the create, `terraform plan` against a live
production whose rules ECS had already moved:

```
config declares:  production → blue,  test → green
live:             production → green, test → green

No changes. Your infrastructure matches the configuration.
```

That exact divergence produced `Plan: 0 to add, 2 to change, 0 to destroy` before
the fix. Zero now, and it cost nothing to establish.

**The alternation.** Three deployments, three different builds:

| Deployment | Incoming build | Registered in |
|---|---|---|
| create | `0.1.6-6f24d09` | **green** — expected; the rules are born pointing at an empty blue |
| deploy-1 | `0.1.5-25153bc` | **blue** |
| deploy-2 | `0.1.3-caa0d21` | **green** |

One alternation could be luck. Two in opposite directions cannot.

**Exit criterion 2, twice** — from
[`docs/evidence/phase-06-exit-criterion-2.txt`](../../evidence/phase-06-exit-criterion-2.txt):

```
TIME       blueTG greenTG :443           :8443          prodRule→  testRule→
14:38:34   2      2       0.1.6-6f24d09  0.1.5-25153bc  green      blue
14:38:48   2      2       0.1.6-6f24d09  0.1.5-25153bc  green      blue
14:39:02   2      2       0.1.5-25153bc  0.1.5-25153bc  blue       blue    ← production shift
...
14:48:48   2      2       0.1.5-25153bc  0.1.3-caa0d21  blue       green
14:49:02   2      2       0.1.5-25153bc  0.1.3-caa0d21  green      green   ← production shift
```

Two target groups, one revision each, the production listener on the outgoing
build and the test listener on the incoming one. `:443` never served the incoming
revision before the production shift, which is the half that proves the canary
was genuinely dark.

**The dark canary saw the right revision, both times:**

```
14:38:49  stage=POST_TEST_TRAFFIC_SHIFT probed=…:8443 git_sha=25153bc
14:49:00  stage=POST_TEST_TRAFFIC_SHIFT probed=…:8443 git_sha=caa0d21
```

Against three consecutive deployments before the fix, where it reported the
**outgoing** revision every time.

**And the signature of the defect is gone.** Nine `ModifyRule` calls across the
create and both deployments, **all from `bgd-us-east-1-prod-bluegreen-role`**.
None from `app-deploy-prod-role` or `infra-apply-role`.

**Rollback capability intact.** The outgoing revision was deregistered seven
minutes after the incoming one registered, on both deployments — after the bake,
not during the shift.

The honest description of production is now: **blue/green, isolating the
colours, verified end to end.**

### What remains

**One thing, and it is narrow.** Both deployments were driven by
`scripts/tf.sh apply prod -var image_tag=…`, which is the same call
`scripts/pipeline-deploy.sh` makes — but the *pipeline* path has not been re-run
since the fix. Phase 8's stages are unchanged by it and the applied plan is
identical, so this is a re-confirmation rather than an open question. Worth doing
on the next pipeline run rather than spending a deployment on it now.
