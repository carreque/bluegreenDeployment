# Phase 6 — the PRE_SCALE_UP hook made the first deployment impossible

**Date:** 2026-08-31
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
