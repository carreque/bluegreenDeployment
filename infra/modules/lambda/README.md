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
