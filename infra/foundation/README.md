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
- CodeConnections link to GitHub, and both CodePipelines
- Shared IAM roles

**Both irreducibly manual steps in the project live here:**

1. Terraform creates the CodeConnections link in `PENDING`; it must be authorised
   by a single click in the console.
2. The four cost allocation tag keys must be activated under Billing. This is
   **not retroactive** — cost recorded before activation is permanently
   unattributed — and it cannot be done any earlier, because a key only becomes
   activatable once AWS has seen it on a real resource. This layer creates the
   first ones.

The pipelines live in this layer, so the infra pipeline ends up managing the layer
that contains it. That is intentional — but it means a broken pipeline definition
must be repaired by a local `terraform apply`.
