# Repeated from foundation rather than shared: a provider block is not a
# module's worth of abstraction, and each root module owning its own is what
# lets this layer diverge without touching that one.
provider "aws" {
  region = var.region

  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.common_tags
  }
}
