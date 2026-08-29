terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }

    # New to this layer. The lambda module zips handler.py with
    # data.archive_file, and mock_provider "aws" does not touch a different
    # provider — so the archive is really built during terraform test, which is
    # what proves the packaging works offline rather than mocking it away.
    # Plan §F4.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # A backend block cannot interpolate, so the bucket bootstrap created appears
  # as a literal — the same trade the four layers before this one make. Only
  # the key differs, and it matches the layer name tf.sh and teardown.sh use.
  backend "s3" {
    bucket       = "bgd-us-east-1-tfstate-590184028094"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
