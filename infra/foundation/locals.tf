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

locals {
  # A LIST, not a map, and that is load-bearing. Terraform iterates a map in
  # lexical key order, which for these four names is foundation, network, prod,
  # staging — so a map would build a pipeline that applies production before
  # staging. A list preserves the order written here, which is the dependency
  # order the layers actually have.
  #
  # scope_operator/scope_value are the VariableCheck rule that decides whether
  # the stage runs at all (plan §D3). foundation has none because every scope
  # includes it, so a rule there could only ever evaluate true.
  #
  # The regexes exist because a condition's rules are ANDed and `network` runs
  # under three of the four scopes; there is no arrangement of EQ and NE that
  # expresses that. Plan §F2 records what to change if MATCHES is unavailable.
  pipeline_layers = [
    {
      name           = "foundation"
      title          = "Foundation"
      scope_operator = null
      scope_value    = null
    },
    {
      name           = "network"
      title          = "Network"
      scope_operator = "MATCHES"
      scope_value    = "^(network|staging|all)$"
    },
    {
      name           = "staging"
      title          = "Staging"
      scope_operator = "MATCHES"
      scope_value    = "^(staging|all)$"
    },
    {
      name           = "prod"
      title          = "Prod"
      scope_operator = "EQ"
      scope_value    = "all"
    },
  ]

  # The names pipelines/infra-plan.yml exports and the approval action
  # interpolates. Declared once so a test can assert the buildspec still
  # exports them — a renamed variable does not fail anything, it just makes
  # every approval message read `#{PlanProd.PLAN_SUMMARY}` literally.
  plan_exported_variables = ["PLAN_STATUS", "PLAN_SUMMARY", "PLAN_URL"]

  # Only the two environment layers take an image tag. foundation and network
  # have no container in them.
  image_tag_environments = ["staging", "prod"]
}
