# Build outputs, test reports and SBOMs (design §4.2).
#
# Versioned, because the point of the bucket is history: an SBOM for the image
# running in production three deployments ago is only available if the object
# that described it was not overwritten.
#
# No prevent_destroy, unlike the state bucket. This one is destroyed only by
# destroying foundation, which the Phase 10 teardown does not do — and a
# lifecycle flag that must be commented out to complete a legitimate operation
# teaches people to comment out lifecycle flags.

resource "aws_s3_bucket" "artifacts" {
  # checkov:skip=CKV_AWS_145:SSE-S3 is deliberate, for the reason recorded in the Phase 3 plan §D4. Decided once and applied to all three encrypted-at-rest resources.
  # checkov:skip=CKV_AWS_144:Single-region project by design (design §5). Build history is reproducible from the commit that produced it.
  # checkov:skip=CKV_AWS_18:Same reasoning as the state bucket — logging needs a target bucket that needs a target bucket, and CloudTrail already records configuration changes.
  # checkov:skip=CKV2_AWS_62:Nothing subscribes to S3 events here. Phase 8 writes artifacts and Phase 9 reads metrics from CloudWatch, not from bucket notifications.
  bucket = "${local.name_prefix}-artifacts-${var.account_id}"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-superseded-artifact-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_artifact_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.artifacts]
}
