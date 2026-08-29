# infra/foundation — Phase 3

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

The **infrastructure pipeline** lives here, added in Phase 7 — a CodePipeline
v2 with three CodeBuild projects, four IAM roles, and the two SSM parameters
that tell the environment layers which image tag to deploy. The application
pipeline arrives in Phase 8, as more files in this layer rather than a new one.

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

The pipelines live in this layer, so the infra pipeline ends up managing the layer
that contains it. That is intentional — but it means a broken pipeline definition
must be repaired by a local `terraform apply`. The
[Phase 7 runbook](../../docs/runbooks/phase-07-infra-pipeline.md) has that
procedure as a step of its own, because the moment it is needed is the moment
the pipeline cannot help.
