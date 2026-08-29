# Phase 6 — local verification record

**Date:** 2026-08-29
**Branch:** `feat/Phase6_ProdBlueGreen`
**AWS resources created:** **none.** See §4.

What this branch actually proves, and what it does not. The plan's D1 split
this phase in two: everything here was written and verified with no AWS
session, and everything that needs one is
[the runbook](../../runbooks/phase-06-prod-blue-green.md).

**None of the phase's three exit criteria is met by this branch.** All three
need a running service. §5 enumerates exactly what remains.

---

## 1. The gate

Both commands run on a machine that has never run `aws sso login`.
`scripts/tf.sh` initialises with `-backend=false` for `validate` and `test`,
so the whole gate is offline.

```
$ make tf-check

==> terraform validate — bootstrap    Success! The configuration is valid.
==> terraform validate — foundation   Success! The configuration is valid.
==> terraform validate — network      Success! The configuration is valid.
==> terraform validate — staging      Success! The configuration is valid.
==> terraform validate — prod         Success! The configuration is valid.

==> tflint — bootstrap    ✓ bootstrap clean
==> tflint — foundation   ✓ foundation clean
==> tflint — network      ✓ network clean
==> tflint — staging      ✓ staging clean
==> tflint — prod         ✓ prod clean

==> checkov — infra/
    Passed checks: 333, Failed checks: 0, Skipped checks: 68
    ✓ checkov clean

==> terraform test — bootstrap    Success! 5 passed, 0 failed.
==> terraform test — foundation   Success! 14 passed, 0 failed.
==> terraform test — network      Success! 17 passed, 0 failed.
==> terraform test — staging      Success! 16 passed, 0 failed.
==> terraform test — prod         Success! 35 passed, 0 failed.

  all infra checks passed
```

```
$ make test-lambdas

Name                        Stmts   Miss Branch BrPart  Cover   Missing
lifecycle_hook/handler.py      49      0      6      0   100%
TOTAL                          49      0      6      0   100%
Required test coverage of 95.0% reached. Total coverage: 100.00%
17 passed in 0.04s
```

**87 Terraform test runs across five layers, 35 of them this layer's**, spread
over six files and 136 assertions. Plus 17 handler tests at 100% coverage
against a 95% gate.

| File | Runs | What it covers |
|---|---|---|
| `mocks.tftest.hcl` | 1 | The reference mock block; asserts the overrides reach `locals` |
| `data_and_iam.tftest.hcl` | 7 | Both tables and the LSI; all four of this layer's own roles |
| `edge.tftest.hcl` | 5 | ALB, both target groups, three listeners, two rules, the DNS record |
| `bluegreen.tftest.hcl` | 15 | The three hooks, the four alarms, and the whole service block |
| `compute.tftest.hcl` | 5 | The Phase 5 assertions re-pointed: ARM64, digest, tags, private subnets |
| `outputs.tftest.hcl` | 2 | Every name a later phase or the runbook depends on by string |

### What each group of assertions protects against

| Assertion | The failure it catches |
|---|---|
| `strategy == "BLUE_GREEN"` | The one word that is the whole difference from staging |
| `bake_time_in_minutes == "5"`, a **string** | The number form fails `validate`; asserting the string keeps a refactor from "fixing" it |
| Exactly three `lifecycle_hook` members | A missing hook is a missing gate, and a `set` gives no ordering to notice it by |
| **Stage↔function pairing, asserted from both ends** | The worst failure in the layer: a `POST_TEST_TRAFFIC_SHIFT` hook probing `:443` validates the colour already serving and approves every bad build, silently, with a green deployment each time |
| `post_test` probes `:8443` | The same failure, caught from the function's side |
| Hooks use `hook_invoke`; `advanced_configuration` uses `bluegreen` | D4. Merging the two roles would give the rule-rewriter permission to invoke arbitrary Lambdas |
| The two roles are different roles | D4 again, asserted so a later simplification has to argue with a test |
| `advanced_configuration` carries **rule** ARNs | A listener ARN fails at apply with a message naming the attribute, not the reason |
| One `load_balancer` block, blue + alternate green | Two blocks is the shape people expect and the provider rejects |
| `alarms.alarm_names == local.bake_alarm_names`, both booleans true | Omitting the block means the bake observes nothing — and the deployment still succeeds, so the gap is silent |
| Four alarms, right dimensions, 60s periods, `notBreaching` | An alarm that cannot evaluate inside the bake it gates contributes nothing |
| No `alarm_actions` | D9 — Phase 9 attaches to these same alarms |
| `wait_for_steady_state`, no circuit breaker | D11, and one rollback mechanism chosen on purpose |
| Two symmetric target groups, both polling `/health` | An asymmetry means the colours are not interchangeable and blue/green stops being a swap |
| Both defaults are a fixed 503 | A forwarding default keeps serving from a stale group if a rule is deleted — the wrong colour half the time |
| ARM64, `BGD_IMAGE_DIGEST`, `desired_count == 2`, `propagate_tags` | The Phase 2 and Phase 5 inheritances |
| Tables match `schema.py`, LSI included | An LSI cannot be added after the table exists |
| Terraform never sets `BGD_EXPECT_DIGEST` | D12 — no failure toggle in the committed infrastructure |

### Two assertions were strengthened after they were found to pass vacuously

Recorded because both were *green* before the fix, which is the dangerous kind
of wrong.

**The D4 wiring assertions.** `mock_provider` fills every `aws_iam_role.arn`
with one shared string, so "the hooks are invoked through `hook_invoke`" and
"the listener rules are rewritten by `bluegreen`" both passed **even when both
slots named the same role** — precisely the mistake D4 exists to prevent.
`bluegreen.tftest.hcl` now carries two `override_resource` blocks giving each
role an ARN that says which one it is. Verified by crossing the wiring in
`ecs.tf` and watching the assertion fail, then reverting.

**The hook invoke policy's resource list.** For the same reason, a policy built
from `module.*.function_arn` would be three identical mocked ARNs, so "no
wildcard has crept in, and there are exactly three distinct functions" could not
discriminate. `iam.tf` composes the ARNs from `local.hook_function_names`
instead — real strings under mocks — and `bluegreen.tftest.hcl` closes the loop
by asserting each module's own `function_name` equals the entry it was built
from, so the composed ARN cannot drift from the function it permits.

---

## 2. Static analysis triage

**Before:** 26 findings across 9 distinct checks, all in this phase's new
shapes — 24 of them the eight Lambda checks firing once per function, and 2 the
same check on both target groups. **After:** 0 failed, every one carrying its
own written reason.

The project-wide total is 68 skips; this layer and its module contribute 19
skip comments covering those 9 checks plus the six carried over from Phase 5's
shapes (`CKV_AWS_150`, `CKV_AWS_91`, `CKV2_AWS_28`, `CKV_AWS_28`,
`CKV_AWS_119`, `CKV_AWS_65`), rewritten for production rather than pointing at
staging.

### New to this phase, from the three Lambda functions

Eight checks, six on the function and two on its log group, all living on
`infra/modules/lambda/main.tf`, because that is where the
resources are. They are written for the risk profile of a **blue/green
lifecycle hook**: a synchronous deployment gate, invoked three times per
deployment by the ECS control plane, running standard-library code that makes
three HTTP requests to a public endpoint and holds no secret.

| Check | Reason, in brief |
|---|---|
| `CKV_AWS_50` X-Ray | Traces a request across services. This calls one thing over plain `urllib` and already logs the stage, URL, outcome and digest. The thing an operator needs after a rejection is the exception message naming path and status — in CloudWatch, not in a trace |
| `CKV_AWS_116` DLQ | Captures *asynchronous* invocations that failed after retries. These are **synchronous**, and ECS is itself the consumer: a failure is an invocation error and becomes a rejected stage (D3), which is the point. There is no dropped event to catch |
| `CKV_AWS_115` reserved concurrency | Concurrency is bounded by the deployment controller, not by load — at most three invocations per deployment, sequential, and deployments do not overlap. A reservation would *add* a failure mode: a gate throttled by its own reservation fails closed, and D3 turns that into rejecting a build that was fine |
| `CKV_AWS_117` VPC | D6. Both listeners are public either way, so a private ENI buys no isolation, and would cost an attachment delay on cold start inside a synchronous gate plus a NAT dependency — a VPC-attached hook needs NAT egress to reach its own ALB and fails closed during exactly the deployments it gates |
| `CKV_AWS_173` env var CMK | The environment holds a probe URL, a stage name, and (only when the runbook sets it) an expected digest. All three are public facts about a public API — the URL is in DNS, the digest is served at `/version` |
| `CKV_AWS_272` code signing | Answers "did someone replace the zip out of band". The zip is built by `archive_file` from a file in this repository during the same apply that deploys it, and `source_code_hash` makes any change visible in the plan. There is no unsigned-upload path to guard |
| `CKV_AWS_158` / `CKV_AWS_338` on the hook log groups | Three probe verdicts per deployment, read within minutes by the runbook step watching the deployment happen. Nothing in them is a credential; nobody reads a hook verdict from eleven months ago |

> **These suppressions live on the module, so Phase 9's metrics collector would
> inherit every one of them.** `main.tf` says so in capitals. A function that
> calls boto3, writes CloudWatch metrics and runs on a schedule answers at least
> the DLQ and concurrency questions differently.

### Where F7's prediction was wrong

F7 predicted all eight Lambda checks and got every one right. It **missed one**:

**`CKV_AWS_378` — "Ensure AWS Load Balancer doesn't use HTTP protocol", on both
target groups.** Worth recording precisely, because the interesting part is
*why it fires here and not on staging's identically-configured target group*.

The protocol is the same in both layers — `HTTP` from the ALB to the task, which
is the design: TLS terminates at the load balancer and the hop behind it is
inside the VPC, to a private subnet, over a security group that accepts traffic
from the ALB's group alone. What differs is checkov's **visibility**. Staging's
HTTPS listener forwards to its target group directly, so the graph sees a TLS
listener in front of it and the check passes. This layer's listeners default to
a fixed 503 and reach the groups through `aws_lb_listener_rule` — because
`advanced_configuration` takes rule ARNs — and the check cannot follow that
edge.

So the finding is an artefact of the blue/green shape rather than a real
difference in exposure, and the skip says exactly that rather than claiming the
configuration is different.

---

## 3. The executed evidence

The parts of this phase that genuinely **ran** rather than being asserted
against mocks.

### The handler suite — 17 tests, 100% coverage

`urllib.request.urlopen` is patched throughout, so no network call and no AWS.
The tests that carry the most weight:

| Test | What it pins |
|---|---|
| `test_unhealthy_raises_rather_than_returning_failed` | **D3.** The asymmetric contract, in executable form. A returned `FAILED` that ECS does not parse promotes a bad build to production |
| `test_digest_mismatch_raises` / `test_no_expectation_ignores_digest` | **D12.** The mechanism exit criterion 3 uses, and that it is opt-in |
| `test_ready_is_allowed_a_longer_timeout_than_the_others` | Phase 5's F5 measured `/ready` taking 25.6s to fail when DynamoDB is unreachable. A 10s probe would report a timeout and hide the 503 naming the real cause — on exactly the failure the dark canary exists to catch |
| `test_failure_message_names_path_and_status` | A hook rejection's only trace is this string in CloudWatch, and it is what tells "green never became healthy" apart from "green was healthy and served the wrong image" |
| `test_the_test_listener_url_is_probed_verbatim` | The dark canary's identity, from the handler's side |

### The deployment package is really built — F4 confirmed

`mock_provider` mocks one provider. `archive` is a different provider, so
`data.archive_file` executes for real during `terraform test`:

```
$ ls -l infra/modules/lambda/.build/
-rw-r--r--  3229  bgd-us-east-1-prod-post-prod-hook.zip
-rw-r--r--  3229  bgd-us-east-1-prod-post-test-hook.zip
-rw-r--r--  3229  bgd-us-east-1-prod-pre-scale-hook.zip

$ unzip -l infra/modules/lambda/.build/bgd-us-east-1-prod-post-test-hook.zip
  Length      Date    Time    Name
     7068  01-01-2049 00:00   handler.py
```

This is a benefit rather than a gap in the mocking. It proves three things the
gate could not otherwise reach: the packaging works offline, the source path in
`hooks.tf` is right (a wrong one fails the gate loudly instead of failing at the
first invocation of a production deployment gate), and **`handler.py` sits at
the zip root** — which is what makes `handler = "handler.handler"` correct.

All three archives are byte-identical in size and carry a fixed timestamp,
which is `output_file_mode = "0644"` doing its job: without it the archived file
inherits the mode it happens to have on the machine that ran the plan, and a
clone with a different umask would show a redeploy that changes nothing.

### Which mocks were actually needed

Following Phase 5's F2 discipline: each was added **because omitting it produced
a hard error**, not because it looked tidy.

| Mock | Verdict |
|---|---|
| `aws_iam_role`, `aws_dynamodb_table`, `aws_cloudwatch_log_group`, `aws_lb`, `aws_lb_target_group`, `aws_ecs_task_definition`, `aws_ecr_image` | Carried from staging, all still needed |
| `aws_lb_listener` | **Needed.** `aws_lb_listener_rule` validates `listener_arn` client-side |
| `aws_lb_listener_rule` | **Needed.** The service validates `production_listener_rule` and `test_listener_rule`, and they are rule ARNs, so the listener mock does not cover them |
| `aws_lambda_function` | **Needed.** The service validates every `hook_target_arn` |
| `aws_cloudwatch_metric_alarm` | **NOT needed, and never added.** The plan's Task 1 Step 2 listed it. Nothing consumes an alarm's ARN — `alarm_names` is a list of *names*, and names are configured rather than computed, so `mock_provider`'s random string never reaches an ARN validator |

The last row is the plan's one wrong prediction about mocks. It is recorded
here rather than added anyway — an unnecessary mock is a claim that a resource
needs one, and the next reader would believe it.

---

## 4. No AWS resource was created

The same proof Phases 4 and 5 give.

- **No `terraform apply` or `terraform plan` was run against a backend.**
  `scripts/tf.sh` initialises `validate` and `test` with `-backend=false`;
  `plan` and `apply` were never invoked.
- **No AWS credentials were used.** No `aws sso login`, and `make verify-aws`
  was not run.
- **`data.terraform_remote_state`** for both `foundation` and `network` is
  satisfied by `override_data` in every test file. Without those overrides the
  tests would reach the real S3 backend and fail on credentials — they do not
  fail, which is itself the evidence they never tried.
- **`data.aws_ecr_image`** — the one data source that reaches an AWS *service*
  API — is satisfied by `mock_data`.
- **`data.archive_file`** is the only data source that really executed, and it
  reads and writes the local filesystem only.

The three zips under `infra/modules/lambda/.build/` are the only artefacts this
session produced, and `.gitignore` excludes them.

---

## 5. What remains before the exit criteria are met

Everything below needs an AWS session, and all of it is
[the runbook](../../runbooks/phase-06-prod-blue-green.md).

| # | Criterion | Runbook step |
|---|---|---|
| 1 | A blue/green deployment completes | 12 — bump `image_tag`, `make apply-prod`, watch the stage transitions. Met when the deployment reads `SUCCESSFUL` **and** the apply returns 0; either alone can mislead |
| 2 | `/version` returns different SHAs on `:443` and `:8443` mid-deployment | 13 — and it needs **two images from two different commits** (F5), which is why step 11 builds the second one *before* step 12 |
| 3 | A deliberately failing hook aborts with zero production traffic shifted | 14 — `BGD_EXPECT_DIGEST` set to a bogus value on the post-test hook. The check is genuine; only the expectation is wrong |

### The open question the runbook closes

**F2 — the hook response contract.** The single largest unverified assumption in
the phase. The payload ECS expects back is not in the provider schema, not in
the AWS CLI's local models, and not anywhere in this repository; confirming it
needs a real invocation.

D3 is the response rather than a fix: the handler returns
`{"hookStatus": "SUCCEEDED"}` on success and **raises** on failure, which is
correct under either plausible contract and chooses the failure mode that
rejects rather than promotes. **Runbook step 9 retires it** by reading the
hook's CloudWatch log after the first real deployment.

If the real contract turns out narrower than D3 assumed, the fix is an
**addition** — never a rewrite into a symmetric return.

Two smaller open questions the runbook also closes: whether
`AmazonECSInfrastructureRolePolicyForLoadBalancers` exists under that name
(step 3, before the apply, because D5's failure mode is benign only if caught
early), and whether F3's reasoning about `UnHealthyHostCount`'s dimensions is
right (step 10). Both fail visibly rather than silently.

---

## 6. Carried forward

| Phase | What it inherits |
|---|---|
| **7** | `wait_for_steady_state` means the prod apply stage takes six to ten minutes. Accepted deliberately (D11) — a pipeline stage that finishes before the deployment it triggered has succeeded is not a gate |
| **8** | **`BGD_EXPECT_DIGEST` as a per-deployment assertion** (D12). The pipeline knows the digest it just pushed and can set it on the post-test hook, turning the dark canary into a full "the thing I built is the thing serving" check. Also: only images flow through the pipeline — this layer owns the task definition and the service shape, which is what makes the ECS action's image-only limitation a non-issue |
| **9** | **These four alarms are the notification targets.** They exist with no `alarm_actions` precisely so Phase 9 attaches SNS to them rather than creating parallel ones (D9), and `bake_alarm_names` is an output for that. Also `infra/modules/lambda` — reusable for the metrics collector, but it will need a dependency-bearing variant if that uses boto3, and it must re-examine all seven Lambda checkov skips |
| **10** | `make teardown` now destroys `prod` first and stops printing "no `.tf` files yet, skipping". `TF_LAYERS` covers all five layers |
| **11** | `docs/evidence/phase-06-exit-criterion-2.txt` from runbook step 13, and the hook log excerpts from steps 9 and 14 — the only durable record of a deployment that no longer exists. Phase 11's "genuinely broken commit, not a simulated failure toggle" standard is why D12 chose an expectation mismatch over a `FORCE_FAIL` boolean |

### One decision worth revisiting with real data

**The alarm thresholds are chosen, not measured** — 5 target-5xx in a minute, a
2-second p95, one unhealthy host. Stated as chosen everywhere they appear,
including in capitals in `alarms.tf`. Too tight rolls back a good deployment;
too loose and the bake gates nothing. Runbook step 10 records the real numbers,
and adjusting them is a one-line change.
