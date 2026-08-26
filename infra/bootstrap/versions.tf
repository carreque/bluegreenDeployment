terraform {
  # >= 1.10 for the S3 backend's native lockfile support, which is what makes
  # the DynamoDB lock table older guides mandate unnecessary (design §1.8).
  # This layer does not use a backend itself — see README.md — but every layer
  # that stores state in the bucket it creates does.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
  }
}
