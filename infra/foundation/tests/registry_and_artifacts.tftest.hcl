# ECR, the artifact bucket, the alert topic and the GitHub connection.
#
# The ECR assertions are the load-bearing ones. Tag immutability is what makes
# a deployed tag mean one image forever — without it, redeploying "the same"
# tag can quietly ship different bytes, which would make the blue/green
# evidence in Phase 11 worthless.

mock_provider "aws" {}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
  domain_name  = "carloscloudengineer.com"
}

run "the_registry_name_matches_the_image_phase_2_builds" {
  command = plan

  assert {
    condition     = aws_ecr_repository.api.name == "bgd-us-east-1-api"
    error_message = "the repository name must equal the image name build-image.sh produces, or seeding is a retag rather than a push"
  }
}

run "tags_in_the_registry_are_immutable_and_scanned" {
  command = plan

  assert {
    condition     = aws_ecr_repository.api.image_tag_mutability == "IMMUTABLE"
    error_message = "a mutable tag can point at different bytes over time, which makes every deployment record ambiguous"
  }

  assert {
    condition     = one(aws_ecr_repository.api.image_scanning_configuration).scan_on_push
    error_message = "scan on push is the only scan that happens without something else remembering to ask for one"
  }
}

run "the_registry_does_not_grow_without_bound" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_ecr_lifecycle_policy.api.policy).rules) == 2
    error_message = "expected two lifecycle rules: expire untagged, then cap the retained count"
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.api.policy).rules[1].selection.countNumber == 10
    error_message = "the retained image count must come from var.ecr_max_image_count"
  }
}

run "the_artifact_bucket_is_versioned_and_private" {
  command = plan

  assert {
    condition     = aws_s3_bucket.artifacts.bucket == "bgd-us-east-1-artifacts-590184028094"
    error_message = "artifact bucket name must be <project>-<region>-artifacts-<accountId>"
  }

  assert {
    condition     = aws_s3_bucket_versioning.artifacts.versioning_configuration[0].status == "Enabled"
    error_message = "design §4.2 requires versioning: build history is the point of this bucket"
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.artifacts.block_public_acls,
      aws_s3_bucket_public_access_block.artifacts.block_public_policy,
      aws_s3_bucket_public_access_block.artifacts.ignore_public_acls,
      aws_s3_bucket_public_access_block.artifacts.restrict_public_buckets,
    ])
    error_message = "test reports and SBOMs describe the application's dependencies; this bucket is not public"
  }
}

run "alerts_go_to_a_named_topic_by_email" {
  command = plan

  assert {
    condition     = aws_sns_topic.alerts.name == "bgd-us-east-1-alerts"
    error_message = "topic name must follow <project>-<region>-<purpose>"
  }

  assert {
    condition     = aws_sns_topic_subscription.alerts_email.protocol == "email"
    error_message = "the subscription protocol must be email"
  }

  assert {
    condition     = aws_sns_topic_subscription.alerts_email.endpoint == "carreque45@gmail.com"
    error_message = "the subscription endpoint must be the owner address"
  }
}

run "the_github_connection_is_a_github_connection" {
  command = plan

  assert {
    condition     = aws_codeconnections_connection.github.provider_type == "GitHub"
    error_message = "CodeCommit is closed to new customers (design §1.1); the source is GitHub"
  }

  assert {
    condition     = length(aws_codeconnections_connection.github.name) <= 32
    error_message = "CodeConnections names are capped at 32 characters"
  }
}
