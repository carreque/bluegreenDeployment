locals {
  name_prefix = "${var.project_name}-${var.region}"

  # S3 bucket names are globally unique across every AWS account, so the
  # convention appends the account ID. See the naming convention, §4.
  bucket_name = "${local.name_prefix}-tfstate-${var.account_id}"

  common_tags = {
    environment = "shared"
    projectName = var.project_name
    region      = var.region
    owner       = var.owner
  }
}
