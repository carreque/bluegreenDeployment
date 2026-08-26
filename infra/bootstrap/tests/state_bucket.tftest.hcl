# The state bucket's properties, asserted at plan time against a mocked provider.
#
# Every assertion here is something that fails silently rather than loudly.
# A bucket without versioning applies cleanly and holds one recoverable copy of
# the state; a bucket missing one of the four public-access flags applies cleanly
# and is public. Neither shows up in a plan review as anything but a short diff.

mock_provider "aws" {}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
}

run "bucket_name_follows_the_naming_convention" {
  command = plan

  assert {
    condition     = aws_s3_bucket.tfstate.bucket == "bgd-us-east-1-tfstate-590184028094"
    error_message = "state bucket name must be <project>-<region>-tfstate-<accountId> — S3 names are globally unique and immutable"
  }
}

run "versioning_is_enabled" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.tfstate.versioning_configuration[0].status == "Enabled"
    error_message = "versioning is the only recovery path for a corrupted or truncated state file"
  }
}

run "encryption_is_server_side_and_free" {
  command = plan

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.tfstate.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "SSE-S3, not KMS: every state read and write would otherwise be a billed KMS request (plan §D4)"
  }
}

run "the_bucket_is_closed_to_the_public_four_ways" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.tfstate.block_public_acls,
      aws_s3_bucket_public_access_block.tfstate.block_public_policy,
      aws_s3_bucket_public_access_block.tfstate.ignore_public_acls,
      aws_s3_bucket_public_access_block.tfstate.restrict_public_buckets,
    ])
    error_message = "all four public access block flags must be true — three of four leaves a hole"
  }
}

run "old_state_versions_expire_but_not_immediately" {
  command = plan

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.tfstate.rule).noncurrent_version_expiration).noncurrent_days == 90
    error_message = "noncurrent state versions must be retained long enough to recover from a bad apply nobody noticed"
  }
}
