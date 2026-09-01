# Phase 6 — the PRE_SCALE_UP hook made the first deployment impossible

**Date:** 2026-08-31
**Status:** **Closed 2026-09-01.** The escape was fixed on the night; what
2026-09-01 added was §7 — the escape had been *concealing* a real production
outage on three of its four invocations, because it logged at `INFO`. It now
logs at `WARNING`, and a rebuild plus two deployments confirmed it fires on the
create alone.
**Found:** on the first real production deployment, driven by the application pipeline
**Execution:** `bgd-us-east-1-app-deploy-prod-build:52db97ff-78b7-4b4d-aa31-d761abb690c7`
**Files:** `lambdas/lifecycle_hook/handler.py`,
`infra/environments/prod/hooks.tf`,
`infra/environments/prod/tests/bluegreen.tftest.hcl`,
`lambdas/tests/test_handler.py`

The production ECS service could not be created. Not "failed this time" — could
not be created at all, by this configuration, ever.

---

## 1. What the pipeline reported

```
Error: waiting for ECS Service (…/bgd-us-east-1-prod-api) create:
No rollback candidate was found to run the rollback.
```

That message is a consequence twice over, and neither layer of it names the
cause. Reading it backwards:

1. The blue/green deployment failed, so ECS tried to roll back.
2. This was a **create**, so there was no previous service revision to roll back
   *to* — hence "no rollback candidate".
3. Terraform surfaced step 2, because that is the error the create returned.

The actual reason is only in the service's event stream:

```
deployment failed: Service deployment rolled back because PRE_SCALE_UP
lifecycle hook(s) failed. ECS was unable to parse the response from
…:function:bgd-us-east-1-prod-pre-scale-hook due to: HookStatus must not be null.
```

And the reason for *that* is only in the Lambda's own log:

```
[INFO]  hook invoked stage=PRE_SCALE_UP probe_url=https://api.carloscloudengineer.com
[ERROR] HookRejected: /health was unreachable after 10s:
        <urlopen error [Errno 111] Connection refused>
```

**Three hops, and each one describes a different event.** Worth noting for the
operational runbook: an ECS blue/green failure is not diagnosable from the
Terraform error. `describe-services --query 'services[0].events'` and then the
hook's log group are both required, in that order.

## 2. Root cause

`PRE_SCALE_UP` fires **before green is scaled up**. On a deployment that
*creates* the service there are no tasks, no healthy targets and nothing behind
the `:443` listener — so the hook's probe of `https://api.carloscloudengineer.com/health`
cannot succeed. The handler raises `HookRejected`, ECS aborts, and the service
is never created.

The gate that protects production deployments made the first production
deployment impossible.

## 3. Why this is not a first-day problem

**`make teardown` destroys `prod`; `make rebuild` applies it from nothing.** The
create path is not something the project passes through once — it is the path
taken on **every rebuild cycle**, which Phase 10 establishes as the normal
operating rhythm of this account.

So without a fix, production could be created zero times, and the platform's
central promise — destroy when idle, rebuild on demand — was broken for the
environment the whole project exists to demonstrate. Phase 10's exit criterion
(*both environments serve traffic again with no manual step other than waiting*)
was unreachable, and its runbook would have failed at the same point.

That elevates this from "a bug found during execution" to "the IaC was not
complete", which is exactly what roadmap §4 predicts teardown-and-rebuild cycles
are for — found one phase earlier than expected, by a pipeline rather than by a
cycle.

## 4. The fix

`BGD_ALLOW_UNSERVED`, set on the pre-scale hook **and on no other**. When set,
a probe that cannot reach a serving endpoint is logged and the stage returns
`SUCCEEDED` instead of rejecting.

The asymmetry is the entire design, and both halves are asserted:

| Stage | Flag | Because |
|---|---|---|
| `PRE_SCALE_UP` | **set** | runs before green exists; an unserved endpoint is a precondition, not a finding |
| `POST_TEST_TRAFFIC_SHIFT` | **never** | the dark canary — green exists, so unreachable means the new revision does not serve, which is the one thing this project is built to catch |
| `POST_PRODUCTION_TRAFFIC_SHIFT` | **never** | runs after traffic moved; unreachable means the shift broke production |

Setting the flag on the post-test hook would turn the dark canary into a log
line that approves every broken build, silently. `bluegreen.tftest.hcl`'s
`only_the_pre_scale_hook_tolerates_an_unserved_endpoint` asserts its presence on
one and its **absence** on the other two, from opposite ends, in the pattern that
file already uses for `BGD_PROBE_URL`.

Two deliberate limits on the blast radius:

- **The flag covers probe failures only.** If the endpoint answers, every check
  past the probe still applies — including `BGD_EXPECT_DIGEST`, so exit
  criterion 3's mechanism is not disabled on this stage.
- **Only the literal string `true` enables it.** A flag that arms on any
  non-empty value is one typo from disarming a hook it should never touch;
  parametrised tests pin `false`, `False`, `1`, `yes`, `""` and `" "` as
  *not* enabling.

### What the fix deliberately accepts

With the flag set, a `500` from the *current* production also does not block the
deployment. This is intended rather than tolerated: `PRE_SCALE_UP` describes what
production looked like before the release, and refusing to deploy because
production is unhealthy is backwards — **the release may be the fix.** The stages
that gate on health are the two that run after green exists. A test states this
explicitly so it reads as a decision rather than an oversight.

## 5. What was NOT changed, and why

`hookStatus` was suspected and is correct. AWS documents the response as
`{"hookStatus": "SUCCEEDED" | "FAILED" | "IN_PROGRESS"}` — lower-case, with an
optional `callBackDelay` alongside `IN_PROGRESS`. `HookStatus must not be null`
was ECS reporting that the Lambda returned an **exception payload** containing no
status at all, not a complaint about capitalisation.

**Plan §F2 is therefore half retired.** The success contract is confirmed, and
the raise path is confirmed to fail *closed* — a raised exception did abort the
deployment. What remains open is whether to replace the raise with a returned
`{"hookStatus": "FAILED"}`, which would produce a truthful operator-facing
message instead of a parse error. That change was **not** made here: it was found
mid-incident, the current behaviour is proven safe, and a returned `FAILED` that
ECS mis-parses promotes a bad build to production — the exact asymmetry D3 was
written around. Phase 11 rejects a build deliberately and can observe both forms;
it is the right place to decide.

## 6. Verification

- `make test-lambdas` — **55 passed**, `lifecycle_hook/handler.py` at **100%**
  statement and branch coverage
- `terraform test` on `prod` — **36 passed, 0 failed** (35 before this phase's
  new run block)
- `terraform fmt -check` clean

**None of this proves the deployment now succeeds.** It proves the hook returns
`SUCCEEDED` against a refused connection when the flag is set, and rejects
without it. The claim that production can be created is only made when a real
deployment reaches `POST_TEST_TRAFFIC_SHIFT` — recorded when it does, not before.

---

## 7. What the flag was also hiding (2026-09-01)

The escape works. It also concealed a production outage on every deployment for
the rest of that night, and the concealment was a property of the **log level**,
not of the flag.

`PRE_SCALE_UP` finished the night with four invocations and zero rejections. That
was read, here and in the other two records, as evidence that `:443` was healthy
whenever the hook looked. It was not. The log group says:

```
19:47:50  /health returned 503                       ← the genuine create
20:46:46  /version was unreachable after 10s         ← an ordinary deployment
20:54:50  /health returned 503                       ← an ordinary deployment
21:11:33  /health returned 503                       ← an ordinary deployment
```

Three of the four were ordinary deployments against a **running** service, and
each followed a Terraform `ModifyRule` by 13 to 21 seconds. `:443` really was
returning 503, because
[the production listener rule had just been reverted to an empty target
group](./2026-08-31-blue-green-does-not-isolate.md) — and the flag logged it at
`INFO` and proceeded.

The control arrived with the fix for that defect: the 2026-09-01 deployment, run
with no `terraform apply` in front of it, fired `PRE_SCALE_UP` at 06:19:56 and
logged no "not serving yet" line at all.

### What changed here

The line is now `LOGGER.warning`, not `LOGGER.info`. It records a probe that
**failed and was allowed through anyway**, and at `INFO` it was indistinguishable
from routine output. `test_the_unserved_escape_is_logged_loudly_enough_to_notice`
asserts the level, because the level is the finding.

After the `alb.tf` fix this line must not appear on anything but a create or a
rebuild. If it does, something is still pointing the production listener at an
empty group.

**Confirmed 2026-09-01.** A rebuild from a destroyed account followed by two
ordinary deployments produced exactly one occurrence, on the create:

```
14:21:50  [WARNING]  stage=PRE_SCALE_UP proceeding: … is not serving yet
                     (/health returned 503). BGD_ALLOW_UNSERVED is set, so this
                     is a create or a rebuild rather than a rejection.
14:36:57  [INFO]     stage=PRE_SCALE_UP probed=… git_sha=6f24d09
```

The create needs the escape and used it. The ordinary deployment probed `:443`
successfully and reported the outgoing revision — which is the correct answer at
that stage, and the thing that was never once true on 2026-08-31. Three of four
invocations that night were masked 503s; one of three here is a legitimate
create.

### What did not change

**The flag itself.** §3's argument is untouched: `make rebuild` recreates prod
from nothing on every teardown cycle, so `PRE_SCALE_UP` meets an unserved
listener on every one, and the escape is what makes the platform's destroy-and-
rebuild promise work for production.

Narrowing it to a precise "is this a create?" condition was considered and is not
possible from the event. The payload is now fully known —

```json
{"executionDetails": {"testTrafficWeights": {}, "productionTrafficWeights": {},
                      "serviceArn": "...", "targetServiceRevisionArn": "..."},
 "executionId": "...", "lifecycleStage": "PRE_SCALE_UP",
 "resourceArn": ".../service-deployment/..."}
```

— and it carries the **target** revision but no source revision, so a create and
a redeploy are indistinguishable to this handler. The blunt flag remains the only
mechanism available; what it now costs is a warning rather than silence.

### Plan §F2 is now fully retired

§5 left it half open. The payload above is the confirmation that was missing —
observed on every invocation of all three hooks, on two separate days. The
remaining question is unchanged and still Phase 11's: whether to replace the
raise with a returned `{"hookStatus": "FAILED"}`. That decision was not made
here either.
