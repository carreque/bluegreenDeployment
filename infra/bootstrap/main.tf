# The bucket every other layer's state lives in.
#
# Seven resources rather than one: the modern AWS provider splits bucket
# configuration into separate resources, and a property that is simply absent
# is not an error — it is a default. That is why each one below has a test.

resource "aws_s3_bucket" "tfstate" {
  # Skips live INSIDE the block and are attributed to the resource checkov names
  # in its finding — for every S3 rule that is aws_s3_bucket, not the
  # configuration resource that actually carries the setting. A skip comment
  # placed above the block is ignored without warning: the run reports
  # "Skipped checks: 0" and the finding still fails.
  # checkov:skip=CKV_AWS_145:SSE-S3 is deliberate. Every state read and write across five layers would otherwise be a billed KMS request, on a bucket already private to one account. Phase 3 plan §D4.
  # checkov:skip=CKV_AWS_144:Single-region project by design (design §5). Replication doubles storage for a disaster model that is "rebuild from code" — and the code, not the state, is the thing that must survive.
  # checkov:skip=CKV_AWS_18:S3 server access logging needs a target bucket, which needs a target bucket. CloudTrail management events already record every change to this bucket's configuration and every role that assumed access. Object-level reads are genuinely not logged; accepted for a single-account project where the only reader is Terraform.
  # checkov:skip=CKV2_AWS_62:Nothing subscribes to S3 events here. An event notification with no consumer is configuration that does nothing but appear to.
  bucket = local.bucket_name

  # This bucket holds the state of every layer in the project. Losing it does
  # not lose the infrastructure, but it loses Terraform's knowledge of it, and
  # the recovery is importing every resource by hand. Never destroyed
  # (infra/bootstrap/README.md), and now enforceably so.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs are disabled outright rather than merely blocked. With BucketOwnerEnforced
# an ACL cannot be set at all, so there is no path by which a later apply, a
# console click or a CLI call re-introduces one.
resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-superseded-state-versions"
    status = "Enabled"

    # An empty filter means "every object". The provider requires filter or
    # prefix to be present; omitting both is a plan-time error.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_state_retention_days
    }

    # Native lockfile locking writes small .tflock objects. An interrupted
    # upload of any object otherwise accrues storage nobody can see.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Lifecycle rules referencing noncurrent versions are rejected on a bucket
  # where versioning has not yet been enabled, and the two resources have no
  # implicit dependency to order them.
  depends_on = [aws_s3_bucket_versioning.tfstate]
}

# Terraform sends state over TLS, but nothing stops something else from not
# doing so. A bucket policy is the only place that can be refused outright.
data "aws_iam_policy_document" "tfstate" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate.json

  # The policy denies non-TLS access to everyone including the account root.
  # Applying it before public access is blocked would briefly present a bucket
  # with a wildcard principal policy, which is exactly what block_public_policy
  # exists to refuse.
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}
