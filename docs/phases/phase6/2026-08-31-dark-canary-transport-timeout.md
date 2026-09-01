# Phase 6 — the dark canary rolled back a good deployment on a TLS handshake

**Date:** 2026-08-31
**Found:** chasing an unexplained `ROLLBACK_SUCCESSFUL` in the deployment history
**Status:** **Closed 2026-09-01 — fix applied and exercised in production
(three clean invocations); the retry branch itself has not met a real transport
failure.** See
[§7](#7-resolution-2026-09-01). The core diagnosis in §6 held; §2 and §3's
explanations of *why* did not, and §7 says what refuted them.
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

---

## 7. Resolution (2026-09-01)

§6's fix was right and is applied. The reasoning in §2 and §3 that led to it was
partly wrong, and both errors were caught by numbers that were available on the
night and were not read: the CloudWatch `REPORT` lines.

### §2's "cold `:8443`" story is refuted

Every `POST_TEST_TRAFFIC_SHIFT` invocation, each performing **three** HTTPS
requests against the same cold test listener:

| Invocation | Duration | Init |
|---|---|---|
| 2026-08-31 19:49:16 | **392 ms** | 81 ms |
| 2026-08-31 20:48:08 | **10 429 ms** ← the rejection | 223 ms |
| 2026-08-31 20:56:26 | **442 ms** | 91 ms |
| 2026-08-31 21:13:11 | **1 005 ms** | 172 ms |
| 2026-09-01 06:21:13 | **563 ms** | 170 ms |

Four cold probes of `:8443` completed three full requests in 0.4 to 1.0 seconds.
A cold test listener costs about 130 ms per request, not seconds. The failure is
an outlier — 10 429 ms is the ten-second cap plus overhead — and not the price of
a cold path.

§2's table is also **n=1**. One rejection across eleven invocations; a single
random failure landing on the post-test hook has probability 4/11 ≈ 36%. "Why
this hook and no other" was a pattern read into one sample. It should not be
repeated in a runbook as causal.

### A second explanation, considered and also refuted

That the 128 MB hooks were starving the TLS handshake of CPU — 128 MB buys
roughly a twelfth of a vCPU, and a handshake is asymmetric crypto. The same
durations kill it: three complete handshakes in 392 ms at 128 MB is not CPU
starvation, and `Max Memory Used: 56 MB` shows no pressure either. **The hooks
stay at 128 MB.** Recorded because it was nearly changed.

### What actually happened, with nothing added

One TLS handshake hung for the full ten seconds, once. The hook had no tolerance
for a single transient network event and reversed a production deployment over
it. That is the whole finding, and it needs no supporting theory — which is the
uncomfortable part, because both theories above felt explanatory and neither was
load-bearing.

### One thing §6 got wrong in the same direction

> *"A first probe that establishes the connection should also carry the
> connection budget rather than the smallest one."*

`urllib.request.urlopen` builds a new `HTTPSConnection` per call and sends
`Connection: close`. There is no pooling, so `/ready` and `/version` each paid
their own handshake too. Budgeting only the first probe would have left
`/version` with exactly the exposure that killed `/health`.

### The fix, as applied

`urllib` replaced with `http.client`, so the distinction §6 asks for is
**structural rather than a guess about exception text**. `urlopen` takes one
`timeout` covering connect, handshake and read; `HTTPSConnection` allows
`connect()` to be called explicitly with its own budget and the socket re-armed
before the request:

| Fails during | Verdict | Retried |
|---|---|---|
| `connect()` — DNS, TCP, TLS handshake | no conversation happened | **yes** — 3 attempts, 1 s then 3 s backoff |
| after the request is on the wire — read timeout, non-200, non-JSON | the service answered, or failed to | **never** |

A read timeout is deliberately **not** retried: `/ready` hanging for thirty
seconds is DynamoDB being unreachable, which is the finding this hook exists to
produce. The one exception is an idle keep-alive connection reaped between
probes, which arrives as `ConnectionResetError` and earns exactly one reconnect.

One connection now serves all three probes, which removes the pooling problem
rather than budgeting around it.

Retries are bounded by the Lambda's own remaining time, from
`context.get_remaining_time_in_millis()` less a five-second reserve. A killed
function is an invocation error and plan D3 turns that into a rollback — the
same outcome the retry exists to prevent, reached by a worse route.

`hook_timeout_seconds` moves 60 → 90. New arithmetic: 30 s of connect attempts +
4 s backoff + 5 + 30 + 5 of reads = 74 s, plus the 5 s reserve. ECS imposes no
competing limit — `describe-services` reports each hook's
`timeoutConfiguration` as `timeoutInMinutes: 1440, action: ROLLBACK`, confirmed
against the real service — so this costs nothing but the wall-clock of a
deployment that is already failing.

### What holds it in place

`lambdas/tests/test_handler.py`, 68 tests, handler at 100% coverage. The load-
bearing ones:

| Test | Holds |
|---|---|
| `test_a_503_is_never_retried` | one connection, one request, one verdict |
| `test_a_read_timeout_is_never_retried` | a hung `/ready` is a finding, not a hiccup |
| `test_a_body_that_is_not_json_is_never_retried` | — |
| `test_a_handshake_failure_is_retried_then_succeeds` | this incident, ending correctly |
| `test_retries_are_bounded_and_then_reject` | retrying has not become "never rejects" |
| `test_the_retry_budget_never_exceeds_the_remaining_time` | the deadline, with 12 s left |
| `test_one_connection_serves_all_three_probes` | the pooling point |
| `test_a_reaped_keepalive_reconnects_once` | the one post-request transport case |

### §5 still holds

The two defects were independent, and this one did survive the isolation fix —
just not for the reason §5 gave. A cold `:8443` is not expensive; an intermittent
transport failure is possible on any listener, and the hook now absorbs it
wherever it happens.

### Exercised in production (2026-09-01)

Three invocations of the rewritten hook against a cold `:8443` — the create and
two deployments — all passed, and both deployment invocations named the
**incoming** revision:

```
14:23:13  stage=POST_TEST_TRAFFIC_SHIFT probed=…:8443 git_sha=6f24d09   (the create)
14:38:49  stage=POST_TEST_TRAFFIC_SHIFT probed=…:8443 git_sha=25153bc
14:49:00  stage=POST_TEST_TRAFFIC_SHIFT probed=…:8443 git_sha=caa0d21
```

Durations 586 ms, 769 ms and 182 ms, for a connection plus three requests each.
That is a fifth, sixth and seventh cold probe of `:8443` completing in well under
a second, which further buries the cold-listener story: the sample is now eight
fast probes and one ten-second outlier.

No transport retry fired, so **the retry path itself has not been exercised
against a real network failure** — only against the eight tests that model one.
That is the expected outcome of a fix for something that happened once in eleven
invocations, and it is not a gap that can be closed by waiting.

### What remains

§6's caution stands and is not retired by three green runs: this change makes the
gate **more willing to pass**, and the direction that needs care is a transport
failure that is really a broken deployment. The test suite holds the line in both
directions, but Phase 11 — which rejects a build deliberately — is where a real
rejection can be observed end to end. Read this section again there.
