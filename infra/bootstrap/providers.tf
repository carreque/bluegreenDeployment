provider "aws" {
  region = var.region

  # A hard stop, at plan time, when the session points at the wrong account.
  # Cheaper than discovering it from a bucket that appeared somewhere else.
  allowed_account_ids = [var.account_id]

  # The four tags of the naming and tagging convention, §5. Set once here so a
  # resource can add tags but never has to repeat these — which is what stops
  # the convention drifting into "documented but not applied".
  default_tags {
    tags = local.common_tags
  }
}
