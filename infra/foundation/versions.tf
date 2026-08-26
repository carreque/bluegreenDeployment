terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
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
