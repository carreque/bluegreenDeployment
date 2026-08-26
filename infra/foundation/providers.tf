# Identical in shape to infra/bootstrap/providers.tf, and repeated rather than
# shared: a two-layer provider block is not a module's worth of abstraction, and
# each root module owning its own provider configuration is what lets a later
# layer diverge without touching this one.
provider "aws" {
  region = var.region

  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.common_tags
  }
}
