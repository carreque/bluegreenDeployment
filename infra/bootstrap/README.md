# infra/bootstrap — Phase 3

The S3 bucket holding every other layer's Terraform state: versioned, encrypted,
public access blocked, with `use_lockfile = true` for native S3 locking.

No DynamoDB lock table. Native lockfile locking needs Terraform ≥ 1.10 and this
project pins 1.15.7 (see `.terraform-version`), so the separate table older guides
mandate is unnecessary.

This layer's own state is **local and gitignored**, which is deliberate: it is
trivially recreatable, and the alternative is a bucket that stores its own state.
Never destroyed.
