# infra/modules/lambda — Phase 6, reused in Phase 9

Packaging and IAM for the project's Lambda functions.

**Phase 6 — three blue/green lifecycle hooks**, invoked synchronously by the ECS
control plane:

| Stage | Responsibility |
|---|---|
| `PRE_SCALE_UP` | Pre-flight checks before green is provisioned |
| `POST_TEST_TRAFFIC_SHIFT` | The dark canary gate — validates green through the `:8443` test listener. Failure aborts with **zero production traffic** ever reaching the bad build. |
| `POST_PRODUCTION_TRAFFIC_SHIFT` | Post-shift verification |

**Phase 9 — the metrics collector**, writing deployment frequency, lead time,
change failure rate and MTTR under a `ReleaseMetrics` namespace.

Runtime is **`python3.14`**, confirmed available in Phase 0 — matching the
container and the local interpreter exactly, with no version divergence.
Architecture is **`arm64`**, matching the container's Graviton choice and price.

## What it creates

Four resources per instantiation, which is the whole module:

| Resource | Why it is here rather than in the calling layer |
|---|---|
| `data.archive_file` | Builds the deployment zip from one `.py` file |
| `aws_lambda_function` | The function itself |
| `aws_cloudwatch_log_group` | Created explicitly so retention is managed and the role can be scoped to it |
| `aws_iam_role` + `aws_iam_role_policy` | Write to that log group, and nothing else |

## Inputs

| Name | Required | Default | Notes |
|---|---|---|---|
| `function_name` | yes | — | Already carries the naming prefix. Also names the log group and the role. Capped at 64 characters, validated |
| `source_file` | yes | — | Path to the single `.py` file that becomes the package |
| `handler` | no | `handler.handler` | Correct for one file named `handler.py`, which `archive_file` places at the zip root |
| `environment` | no | `{}` | The whole of a hook's per-instance configuration. Omitted from the function entirely when empty |
| `timeout_seconds` | no | `60` | On a synchronous deployment gate this bounds how long a stage can hang |
| `memory_size_mb` | no | `128` | The floor, and ample for three HTTP requests |
| `log_retention_days` | no | `14` | |

## Outputs

`function_arn`, `function_name`, `log_group_name`, `role_arn` — the identifiers
a caller wires into other resources.

`runtime`, `architectures`, `timeout_seconds`, `environment_variables` — the
function's *resolved* configuration, exposed for one reason: a module's resources
are not reachable from a `.tftest.hcl` file, only its outputs are. Without these
the calling layer cannot assert which listener each hook probes, and that is the
worst thing in this layer to get wrong.

## Single-file packaging is the design, not a limitation to work around

`archive_file` over one source file is what keeps the offline gate honest.
`mock_provider "aws"` does not mock the `archive` provider, so during
`terraform test` the zip is **really built** from the handler on disk — the gate
proves the packaging works instead of mocking away the step most likely to be
misconfigured, and it fails loudly if the source path is wrong. That property is
only available because the handler needs no dependencies.

`output_file_mode = "0644"` is set for a related reason: without it the archived
file inherits the mode it happens to have on the machine that ran the plan, so a
clone with a different umask produces a different hash and `terraform plan` shows
a redeploy that changes nothing.

**Phase 9 needed no variant.** This README predicted one on the assumption
that the metrics collector's use of `boto3` would force a dependency-bearing
package. It does not: `boto3` and `botocore` ship in every AWS Lambda managed
Python runtime, so the collector's imports — `boto3`, `json`, `logging`, `os`,
`datetime` — are nothing this module has to vendor. `archive_file` over the
single `lambdas/release_metrics/handler.py` still expresses the whole
package, and `terraform test` still really builds that zip against a mocked
provider — the exact property this section calls "the design", now proven
under the one case that was supposed to require an exception rather than
assumed to survive it. The accepted cost is that the collector runs whatever
`boto3` version the runtime happens to ship, which AWS can change without
notice; for four API calls whose signatures predate this project by a decade
(`put_metric_data`, `get_metric_data`, `publish`, `get_pipeline_execution`),
that is not worth a vendoring step, a layer or a build. See the Phase 9 plan's
D10 and F2.

### The six checkov skips, re-examined for an asynchronous invoker

`main.tf` carried a note telling Phase 9 to re-examine its six suppressions,
because a metrics collector added to this module inherits every one of them.
Five hold unchanged for the same reasons Phase 6 gave — one http.client call is
already logged in full (`CKV_AWS_50`), concurrency is bounded by how rarely
deployments and pipeline executions happen (`CKV_AWS_115`), CloudWatch, SNS
and CodePipeline are public API endpoints reachable with no VPC (`CKV_AWS_117`),
the environment variables carry no secret (`CKV_AWS_173`), and the zip is
built by `archive_file` in the same apply that deploys it (`CKV_AWS_272`).

**One does not.** `CKV_AWS_116` — no dead-letter queue — was written for the
three lifecycle hooks, which ECS invokes **synchronously** and itself consumes
the result of; there is no dropped event for a queue to catch. The collector
is invoked **asynchronously**, by EventBridge, so a dropped invocation is a
real possibility this module's original reasoning did not cover. The skip's
comment is rewritten to say so explicitly, and the answer is still no DLQ —
for a different reason than before: nothing in this project polls a queue, and
a DLQ here would accumulate events no human or process ever reads while
suggesting to the next reader that dropped invocations are handled somewhere.
What actually handles them is the collector's own `Errors` alarm, publishing
to the alert topic within a minute, plus a `retry_policy` on both EventBridge
targets bounding delivery to three attempts over five minutes rather than
EventBridge's own default of 185 attempts over 24 hours.

## Why it has no test suite of its own

It has no logic: no conditionals beyond one `dynamic` block that omits an empty
environment, no `for_each`, no computed names. The calling layers' assertions
on its four real instantiations — the three lifecycle hooks in
[`prod/tests/bluegreen.tftest.hcl`](../../environments/prod/tests/bluegreen.tftest.hcl)
and the release metrics collector in
[`foundation/tests/observability.tftest.hcl`](../../foundation/tests/observability.tftest.hcl)
— test everything it does. A suite over a module with no branches asserts that
Terraform works.

Phase 9 added a fourth instantiation and no branching, so this remains true
rather than needing its own test suite for the first time.
