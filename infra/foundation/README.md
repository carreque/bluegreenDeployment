# infra/foundation — Phases 3, 7, 8 and 9

Durable, effectively free, and painful to recreate. Survives every teardown.

- Route 53 hosted zone, via find-or-create. **Verified in Phase 0: the zone already
  exists** (`Z01311493LQ7UOIRHM1H9`, created by the registrar) and is correctly
  delegated, so this takes the adopt path and `wait_for_validation` can be `true`
  on the first apply.
- ACM certificate for `api.` and `staging-api.carloscloudengineer.com`
- ECR repositories — immutable tags, scan on push, lifecycle policy
- Versioned S3 artifact bucket for build outputs, test reports and SBOMs
- SNS topic with an email subscription
- CodeConnections link to GitHub

**Both pipelines live here.** The layer now owns two, in separate files that
share a connection, a bucket and nothing else — not a stage, not a role, not a
buildspec.

| | Infra pipeline (Phase 7) | App pipeline (Phase 8) |
|---|---|---|
| Files | `codepipeline.tf`, `codebuild.tf`, `iam-pipeline.tf` | `codepipeline-app.tf`, `codebuild-app.tf`, `iam-app-pipeline.tf` |
| Fires on | `infra/**`, `pipelines/infra-*.yml`, and the scripts it runs | `app/**`, `pipelines/app-*.yml`, and the scripts it runs |
| Stages | Source → Validate → Foundation → Network → Staging → Prod | Source → Build → DeployStaging → Prod |
| Approvals | four | one |
| Projects / roles | 3 / 4 | 5 / 6 |
| Source artifact | `CODE_ZIP` | `CODEBUILD_CLONE_REF` — the build reads git |
| Scope variable | `DEPLOY_SCOPE` | `APP_SCOPE` |

Two SSM parameters, `/bgd/staging/image_tag` and `/bgd/prod/image_tag`, sit
between them: the app pipeline writes each **after** a successful apply, and the
infra pipeline reads them so an `infra/**` merge plans against the tag already
deployed and cannot change what is running. Writing them after rather than
before is what stops an `infra/**` merge landing mid-run from deploying a new
image to production with no approval.

A reader asking "what happens when I merge an application change" should find
`codepipeline-app.tf` and have it answered there. Its stages are written out
where `codepipeline.tf`'s are generated, because the infra pipeline's four
layer stages are structurally identical and these two are not.

Each IAM role is still created by the phase that creates the resource it acts
on, which is why Phase 3 created none: a policy cannot be scoped to resources
that do not exist yet.

**All three irreducibly manual steps in the project live here:**

1. Terraform creates the CodeConnections link in `PENDING`; it must be authorised
   by a single click in the console.
2. The SNS email subscription is created `PendingConfirmation` and does nothing
   until the link AWS emails is clicked. Terraform reports it as created and
   `plan` stays clean forever, so skipping it is silent — the symptom is Phase
   9's alerts never arriving.
3. The four cost allocation tag keys must be activated under Billing. This is
   **not retroactive** — cost recorded before activation is permanently
   unattributed — and it cannot be done any earlier, because a key only becomes
   activatable once AWS has seen it on a real resource. This layer creates the
   first ones.

> **Amended in Phase 3 (2026-08-24).** This section said *both*, listing two.
> The SNS confirmation is the third, and it is the one with no error path.

Exact commands for all three, with their verification calls, are in
[the Phase 3 runbook](../../docs/runbooks/phase-03-bootstrap-and-foundation.md).

The pipelines live in this layer, so each ends up managing the layer that
contains it. That is intentional — but it means a broken pipeline definition
must be repaired by a local `terraform apply`. The
[Phase 7 runbook](../../docs/runbooks/phase-07-infra-pipeline.md) has that
procedure as a step of its own, because the moment it is needed is the moment
the pipeline cannot help.

## Phase 9 — the observability plane

One Lambda, two EventBridge rules, one watchdog alarm and one dashboard,
defined in `observability.tf` and `dashboard.tf`.

- **The collector** (`module.release_metrics`, function name
  `bgd-us-east-1-release-metrics`) is invoked by the two rules below, reads
  back the pipeline and deployment history CloudWatch already holds, and
  writes lead time, deployment frequency, change failure rate and MTTR into
  the `ReleaseMetrics` namespace. It can write only that namespace — the IAM
  condition on `cloudwatch:PutMetricData` is the one lever that action offers
  — and it can read pipeline executions but never start, stop or approve one.
- **The pipeline-executions rule** fires on `SUCCEEDED` and `FAILED` states
  from both the infra and the app pipeline, named rather than wildcarded.
  **The prod-deployments rule** fires on every ECS deployment state change on
  the production service, deliberately unfiltered by `eventName` — which name
  a blue/green rollback emits is a runtime contract with no offline source of
  truth, and a wrong guess would make rollbacks invisible.
- **The dashboard** (`bgd-us-east-1-release`) is the one console tab covering
  release health and both environments' ALB health, so "why did the pipeline
  stop" and "is staging sick" don't need two tabs.
- **The watchdog alarm** watches the collector's own `Errors` metric and
  publishes to the alerts topic directly, bypassing the collector — every
  other alert this phase produces travels through the Lambda, so this is the
  one that still has to work when the Lambda does not.

This layer owns all four, and that is forced rather than preferred: `prod`
already reads this layer's remote state, so the mirror — this layer reading
`prod`'s back to build the alarm actions and event pattern it needs — would
make each layer depend on the other. Terraform would not report that as a
cycle, because the two are separate state files read at plan time, not a
single dependency graph. The symptom would be this layer's plan failing to
read a state file `make teardown` emptied, in the layer whose whole purpose is
surviving teardown. What `prod` owns instead is four lines: `alarm_actions` on
its own bake alarms, which can only be set where the alarm is.

## Phase 10 — the platform marker

- **`/bgd/platform/deployed_scope`** — how deep the platform is currently
  applied. Written by `make teardown` and `make rebuild`; read by both pipeline
  drivers, which clamp their own scope to it so that a merge to `main` while the
  platform is torn down skips the layers that do not exist rather than
  recreating them. It lives here because it has to survive what it describes.
