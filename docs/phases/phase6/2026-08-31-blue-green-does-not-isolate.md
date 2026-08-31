# Phase 6 — blue/green does not isolate the colours

**Date:** 2026-08-31
**Status:** **Open.** Reproduced four times, cause not established.
**Severity:** This defeats the property the project exists to demonstrate.
**Evidence:** CloudTrail target registrations, ECS service events, a 10-second
sampling log of both listeners, three lifecycle hook log groups.

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
