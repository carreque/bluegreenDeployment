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
| _the metrics collector_ | 9 | Deployment frequency, lead time, change failure rate, MTTR |

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

Phase 9's metrics collector will need boto3, and `archive_file` over a single
source file cannot express a dependency-bearing package — that phase adds the
variant, and this note is where it should start.

## Running the tests

    make test-lambdas

They patch `urllib.request.urlopen` throughout, so they make no network call and
need no AWS session. Coverage is gated at 95%.
