# Phase 6 — the dark canary rolled back a good deployment on a TLS handshake

**Date:** 2026-08-31
**Found:** chasing an unexplained `ROLLBACK_SUCCESSFUL` in the deployment history
**Status:** diagnosed, fix proposed, **not applied** — see §6
**File:** `lambdas/lifecycle_hook/handler.py`

A production deployment rolled itself back. The application was fine, the image
was fine, and the hook that stopped it never got as far as asking a question.

---

## 1. The three hops, again

```
ECS deployment:  ROLLBACK_SUCCESSFUL
statusReason:    rolled back because POST_TEST_TRAFFIC_SHIFT lifecycle hook(s)
                 failed. ECS was unable to parse the response … due to:
                 HookStatus must not be null
Lambda log:      HookRejected: /health was unreachable after 10s:
                 <urlopen error _ssl.c:1064: The handshake operation timed out>
```

The operator-facing message is a **parse error**. The actual event is a TLS
handshake that did not complete inside ten seconds. Nothing in the chain says
"the network was slow", and a reader working from the ECS message alone would go
looking at the application or at the hook's return contract — neither of which
had anything to do with it.

## 2. Why this hook and not the others

All three hooks run the same handler. Tonight:

| Hook | Probes | Invocations | Rejected |
|---|---|---|---|
| `PRE_SCALE_UP` | `:443` | 4 | 0 |
| `POST_TEST_TRAFFIC_SHIFT` | **`:8443`** | 4 | **1** |
| `POST_PRODUCTION_TRAFFIC_SHIFT` | `:443` | 3 | 0 |

Only the hook probing the **test listener** failed, and that is not a
coincidence. `:443` carries production traffic continuously, so its path is warm
whenever a hook probes it. **`:8443` carries no traffic at all except during a
deployment** — by design; that is what makes it a test listener — so every probe
of it is a cold first connection, paying DNS, TCP and a full TLS handshake.

The hook Lambda is not VPC-attached (`VpcConfig: null`), so that connection goes
from the Lambda service network out to the public ALB.

## 3. The timeout policy is inverted

```python
PROBE_PATHS = ("/health", "/ready", "/version")

def _timeout_for(path, base):
    return max(base, READY_MINIMUM_TIMEOUT_SECONDS) if path == "/ready" else base
```

`/ready` gets a 30-second floor; `/health` and `/version` get the 10-second base.
The reasoning is recorded in the handler and is sound as far as it goes: Phase 5
§F5 measured `/ready` taking 25.6 seconds to *fail* when DynamoDB is unreachable,
because botocore retries with backoff, and a 10-second cap there would hide the
503 that names the real cause.

What nobody accounted for is that **`/health` is probed first**, so it is the
request that pays for establishing the connection — and it holds the smallest
budget of the three. The cheapest request by server-side work is the most
expensive by wall-clock, exactly once per invocation, and it is the one that was
given the least room.

## 4. What it costs

One deployment in four was rolled back for a reason that had nothing to do with
the change being deployed. That is not a safe-by-default gate; it is a gate that
fires at random, and its cost is the same as any other flaky gate: the next
person to see a rollback assumes it is spurious.

It is worse than a flaky test, because a rollback is not a red light on a
dashboard — it is a production deployment reversed, with the traffic movement
and task churn that implies.

## 5. It is independent of the isolation defect

While [the colours are not separated](./2026-08-31-blue-green-does-not-isolate.md)
this hook's verdict is meaningless anyway, since it probes a mixed pool. But the
two defects are unrelated and this one **survives** the isolation fix: a cold
test listener would still be cold, the first probe would still pay the handshake,
and the budget would still be ten seconds.

## 6. The fix, and why it is not applied here

**Distinguish transport failures from application failures, and retry only the
former.** They are categorically different verdicts wearing one exception type:

- *the service answered badly* — a 500, a 503, a body that is not JSON. **Never
  retry.** This is the finding the hook exists to produce.
- *no conversation happened* — DNS, TCP, TLS handshake, connect timeout. **Retry,
  briefly.** Nothing has been learned about the deployment yet.

`_probe` currently collapses both into `HookRejected`, so the gate cannot tell
"green is broken" from "the network was slow", and it treats the second as the
first. A first probe that establishes the connection should also carry the
connection budget rather than the smallest one.

**Not applied in this session, deliberately.** This is the one mechanism standing
between a bad build and production, its current behaviour errs toward refusing
deployments rather than accepting them, and a change that makes it retry is a
change that makes it *more willing to pass*. That deserves its own branch and its
own review rather than a fix appended to a night of incident work — particularly
while §5's defect means the hook is not yet judging the right thing.

The order to do these in is: fix the isolation defect first, so the hook probes
green alone; then fix this, with a test that a 503 is never retried and a
handshake timeout is.
