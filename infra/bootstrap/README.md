# infra/bootstrap — Phase 3

The S3 bucket holding every other layer's Terraform state: versioned, encrypted,
public access blocked, with `use_lockfile = true` for native S3 locking.

No DynamoDB lock table. Native lockfile locking needs Terraform ≥ 1.10 and this
project pins 1.15.7 (see `.terraform-version`), so the separate table older guides
mandate is unnecessary.

This layer's own state is **local and gitignored**, which is deliberate: it is
trivially recreatable, and the alternative is a bucket that stores its own state.

Recreating it, if the file is ever lost:

```bash
terraform -chdir=infra/bootstrap import \
  aws_s3_bucket.tfstate bgd-us-east-1-tfstate-590184028094
terraform -chdir=infra/bootstrap plan
```

The plan then shows the six configuration resources as additions; applying them
against a bucket that already carries those settings is idempotent.

**Never destroyed**, and `prevent_destroy = true` on the bucket makes that
enforceable rather than advisory. Phase 10's teardown stops at `network` and
never reaches here. Do not remove the flag to make a `destroy` succeed.
