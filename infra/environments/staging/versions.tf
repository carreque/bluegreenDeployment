terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
  }

  # A backend block cannot interpolate, so the bucket bootstrap created appears
  # as a literal — the same trade the three layers before this one make. Only
  # the key differs, and it matches the layer name tf.sh and teardown.sh use.
  backend "s3" {
    bucket       = "bgd-us-east-1-tfstate-590184028094"
    key          = "staging/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
