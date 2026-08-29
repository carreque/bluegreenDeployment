terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }

    # The zip is built here, not committed. archive is a separate provider from
    # aws, which is why mock_provider "aws" leaves it alone and the calling
    # layer's terraform test really produces a deployment package on disk —
    # the offline gate proves the packaging rather than mocking it. Plan §F4.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}
