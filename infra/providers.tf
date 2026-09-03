# Repeated from the layers before it rather than shared: a provider block is not
# a module's worth of abstraction, and each root module owning its own is what
# lets this layer set its own environment tag without touching those. It is now
# the only root module serving two environments, which is var.environment rather
# than a second provider block.
provider "aws" {
  region = var.region

  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.common_tags
  }
}
