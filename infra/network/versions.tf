terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
  }

  # A backend block cannot interpolate, so the bucket bootstrap created appears
  # as a literal. Nothing mechanical keeps this string and var.account_id's
  # default in agreement — only the naming convention does.
  backend "s3" {
    bucket       = "bgd-us-east-1-tfstate-590184028094"
    key          = "network/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
