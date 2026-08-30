terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }

    # New to this layer with Phase 9. The lambda module zips
    # lambdas/release_metrics/handler.py with data.archive_file, and
    # mock_provider "aws" does not touch a different provider — so the archive
    # is really built during terraform test, which is what proves the
    # collector's packaging works offline rather than mocking it away.
    # Declared here, matching infra/environments/prod/versions.tf, so the lock
    # file records the resolution rather than leaving it to the implicit
    # dependency Terraform would otherwise infer from the child module — which
    # would leave this layer's .terraform.lock.hcl changed-but-uncommitted and
    # the next `terraform init` inside CodeBuild resolving a provider no lock
    # pinned. Plan §F4.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # A backend block cannot interpolate: variables, locals and functions are all
  # parse errors here, so the bucket name Task 1's convention produces appears
  # as a literal. The naming convention is what keeps this string and
  # var.account_id's default in agreement; nothing mechanical can.
  #
  # use_lockfile is native S3 locking, available from Terraform 1.10 and the
  # reason this project has no DynamoDB lock table (design §1.8).
  backend "s3" {
    bucket       = "bgd-us-east-1-tfstate-590184028094"
    key          = "foundation/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
