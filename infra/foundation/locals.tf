locals {
  name_prefix = "${var.project_name}-${var.region}"

  api_domain         = "api.${var.domain_name}"
  staging_api_domain = "staging-api.${var.domain_name}"

  common_tags = {
    environment = "shared"
    projectName = var.project_name
    region      = var.region
    owner       = var.owner
  }
}
