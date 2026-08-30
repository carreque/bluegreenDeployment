# lambdas

Python that runs outside the container. Design §9's repository layout puts it
here rather than under `app/`, because `app/` is the service — one image, one
dependency lock, one test suite — and these are neither built into that image
nor deployed with it.

Packaged and deployed by [`infra/modules/lambda`](../infra/modules/lambda), and
instantiated by [`infra/environments/prod/hooks.tf`](../infra/environments/prod/hooks.tf).

| Package | Phase | What it is |
|---|---|---|
| `lifecycle_hook/` | 6 | The three ECS blue/green lifecycle hooks |
| `release_metrics/` | 9 | Deployment frequency, lead time, change failure rate, MTTR |

## `lifecycle_hook`

One handler, deployed three times. All three do the same job — probe an HTTP
endpoint and report pass or fail — and differ only in which listener they probe
and at which stage of the deployment ECS invokes them, both of which come from
the environment. So the code that decides whether a release proceeds exists
once.

| Function | Stage | Probes | What it rules out |
|---|---|---|---|
| `bgd-us-east-1-prod-pre-scale-hook` | `PRE_SCALE_UP` | `:443` | Starting a deployment into an already-broken environment. Without this, a failure mid-deployment is ambiguous — was it the new build, or was production already down? |
| `bgd-us-east-1-prod-post-test-hook` | `POST_TEST_TRAFFIC_SHIFT` | `:8443` | **The dark canary.** A green revision that starts but cannot reach DynamoDB, or serves the wrong image, is rejected before one user request touches it. |
| `bgd-us-east-1-prod-post-prod-hook` | `POST_PRODUCTION_TRAFFIC_SHIFT` | `:443` | Green is now serving real traffic; confirm the promotion worked before the five-minute bake begins. |

`/ready` is in the probe set deliberately, and it is the check that carries the
dark canary's weight. `/health` reports only that the process is alive; `/ready`
performs a real DynamoDB call. A green task that starts but cannot reach its
table passes `/health` and fails `/ready`.

### The return contract, and why it is asymmetric

**On success the handler returns `{"hookStatus": "SUCCEEDED"}`. On failure it
raises `HookRejected` rather than returning a `FAILED` payload.**

That is not an inconsistency to tidy up. The exact payload ECS expects back from
a lifecycle hook is not in the Terraform provider schema and could not be
confirmed without an AWS session, so the handler is built to be correct under
either plausible contract. The two possible mistakes are not symmetric:

- If ECS reads a `hookStatus` field and the handler raises on failure, ECS sees
  an invocation error. No plausible contract reads an invocation error as
  success. **Safe.**
- If ECS treats any successful invocation as a pass and the handler returns
  `{"hookStatus": "FAILED"}`, the bad build is **promoted to production**. That
  is the failure this entire phase exists to prevent.

`tests/test_handler.py::test_unhealthy_raises_rather_than_returning_failed` is
what stops a later simplification from making it symmetric. The runbook's step 9
records what ECS really did with the return value at the first invocation.

### Environment

| Variable | Required | Meaning |
|---|---|---|
| `BGD_PROBE_URL` | yes | Base URL, no trailing path. `https://api.…` or `https://api.…:8443` |
| `BGD_STAGE` | yes | The stage this instance is subscribed to. Log context only — the handler does not branch on it |
| `BGD_TIMEOUT_SECONDS` | no, default 10 | Per-probe timeout. `/ready` is floored at 30 regardless, see below |
| `BGD_EXPECT_DIGEST` | no | When set, additionally asserts `/version`'s `image_digest` equals it |

`BGD_EXPECT_DIGEST` is **never set by Terraform**, deliberately. The third exit
criterion needs a hook to fail on purpose, and a boolean `FORCE_FAIL` toggle
would have satisfied it dishonestly — nothing about the deployment would
actually be wrong. Setting a bogus expected digest by hand makes a *real* check
fail against a wrong expectation instead. It is also how Phase 8's pipeline,
which knows the digest it just pushed, can turn the dark canary into a full
"the thing I built is the thing serving" assertion.

**Leaving `BGD_EXPECT_DIGEST` set breaks every subsequent deployment in a way
that looks like a broken build.** The runbook says to unset it, and Terraform
will not silently fix it for you.

`/ready` is floored at 30 seconds because Phase 5 measured it taking 25.6
seconds to fail when DynamoDB is unreachable — botocore retries with backoff. A
10-second probe would report a timeout and hide the 503 that names the real
cause, on exactly the failure the dark canary exists to catch. Worst case is
therefore 10 + 30 + 10 = 50 seconds of probing, which is why the functions are
given a 60-second timeout and not the more obvious 30.

### Standard library only

No boto3, no HTTP client dependency. That is what keeps the packaging trivial:
the deployment zip is one file, `data.archive_file` builds it during
`terraform test` with no network access, and this test suite needs nothing the
existing `app/.venv` does not already have.

## `release_metrics`

One handler, two EventBridge sources: production ECS deployment state changes
and both pipelines' execution state changes. It writes the `ReleaseMetrics`
series behind the dashboard and publishes the alerts worth an email — see
[infra/foundation/observability.tf](../infra/foundation/observability.tf) for
what creates and wires it, and the [Phase 9
plan](../docs/phases/phase9/2026-08-30-phase-09-implementation-plan.md)'s D3
through D9 for the reasoning behind each choice below.

### Environment

| Variable | Required | Meaning |
|---|---|---|
| `BGD_METRIC_NAMESPACE` | no, default `ReleaseMetrics` | CloudWatch namespace every metric is written under |
| `BGD_ENVIRONMENT` | no, default `prod` | The `Environment` dimension on every deployment-outcome metric |
| `BGD_MTTR_LOOKBACK_DAYS` | no, default 30 | How far back `GetMetricData` looks for an unrecovered failure |
| `BGD_ALERT_TOPIC_ARN` | yes (logged and dropped if absent, never raised on) | Where failure and rollback emails go |
| `BGD_APP_PIPELINE` | yes | Which pipeline's `SUCCEEDED` state change triggers a lead-time emission — the infra pipeline succeeding means nothing was deployed to production |

The first three have defaults, which is precisely why they are asserted in
`infra/foundation/tests/observability.tftest.hcl` rather than trusted: a
missing one is silent, not fatal, and a silent wrong namespace means metrics
land somewhere real while the dashboard stays empty.

### The return contract, and why it is the opposite of `lifecycle_hook`'s

**On a recognised event it returns a `{"handled": True, …}` dictionary. On an
event it does not recognise — an unrecognised `source`, an ECS `eventName`
outside the known sets, a CodePipeline state that is neither `SUCCEEDED` nor
`FAILED` — it also returns, `{"handled": False, …}`, logged at `INFO` or
`WARNING`. It raises only when an AWS call it actually needs — `PutMetricData`,
`GetMetricData`, `sns:Publish`, `GetPipelineExecution` — fails.**

Read the section above this one before concluding that is an inconsistency:
`lifecycle_hook` raises when in doubt because its failure mode is *promoting a
bad build*. This handler's failure mode, if it raised the same way, is
different in kind. It is invoked **asynchronously** by EventBridge, whose
retry policy here is `maximum_retry_attempts = 2` over five minutes — an
exception is retried, then fires the collector's own `Errors` alarm, then
emails you. The ECS rule is deliberately unfiltered on `eventName` (design
§8's D4): every deployment fires a `SERVICE_DEPLOYMENT_IN_PROGRESS` event this
handler has no opinion about, on purpose, so that a rollback-shaped event it
was never told to expect still reaches it rather than being filtered out
upstream. If the handler raised on every shape it merely does not recognise,
those routine in-progress events would retry and alert continuously — the
alarm that exists to say "the collector is broken" would fire nonstop while
the collector worked exactly as designed.

So the two contracts point in opposite directions for the same underlying
reason: each raises exactly when raising is the safe response to *its own*
invocation model, synchronous-and-gating for one, asynchronous-and-retried for
the other. `tests/test_release_metrics.py` has a case naming this directly —
an unrecognised source, event name and pipeline state each return cleanly
rather than raise, and a failing `put_metric_data` call does raise.

### boto3 only, from the managed runtime

`boto3` and `botocore` ship in every AWS Lambda managed Python runtime, so
this package still needs nothing vendored: `archive_file` over the single
`handler.py` still expresses the whole deployment package, and `terraform
test` still really builds the zip with no network access — see
[`infra/modules/lambda/README.md`](../infra/modules/lambda/README.md) for why
that property mattered enough to check before assuming it would need to
change.

## Running the tests

    make test-lambdas

They patch `urllib.request.urlopen` throughout, so they make no network call and
need no AWS session. Coverage is gated at 95%.
