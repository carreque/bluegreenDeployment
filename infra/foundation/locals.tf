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
  #
  # tflint sees no use because the only consumer is
  # tests/pipeline_shape.tftest.hcl, which it does not read. That is the
  # declaration doing its job rather than a leftover: the whole point is to
  # keep the three names in one place a test can compare the buildspec
  # against.
  # tflint-ignore: terraform_unused_declarations
  plan_exported_variables = ["PLAN_STATUS", "PLAN_SUMMARY", "PLAN_URL"]

  # Only the two environment layers take an image tag. foundation and network
  # have no container in them.
  image_tag_environments = ["staging", "prod"]
}

# ---------------------------------------------------------------------------
# Phase 8 — the application pipeline
# ---------------------------------------------------------------------------

locals {
  # A MAP here, where pipeline_layers above is a LIST, and the difference is
  # not an inconsistency.
  #
  # pipeline_layers is *iterated* to build four structurally identical stages,
  # so its order is the pipeline's order and a map would have put prod before
  # staging. This one is only ever **looked up**, by two stages that
  # codepipeline-app.tf writes out explicitly — because they are not
  # structurally identical: staging holds Deploy and Smoke, production holds
  # Plan, Approve and Apply. Nothing iterates it, so nothing can be reordered
  # by it.
  #
  # staging runs under two of the three scopes and prod under one, which is why
  # staging takes a regex and prod an equality: a condition's rules are ANDed,
  # and there is no arrangement of EQ and NE that expresses "two of three". The
  # same reasoning pipeline_layers records for `network`, and Phase 7 §F2
  # records what to change if MATCHES turns out not to be an accepted operator.
  app_scope_conditions = {
    staging = { operator = "MATCHES", value = "^(staging|all)$" }
    prod    = { operator = "EQ", value = "all" }
  }

  # The names pipelines/app-build.yml exports and the later stages interpolate
  # as #{Build.IMAGE_TAG}. Declared here so a test can assert the buildspec
  # still exports them — a renamed variable does not fail anything, it makes
  # every downstream action receive the literal string "#{Build.IMAGE_TAG}"
  # and try to deploy it as a tag.
  #
  # tflint sees no use because the only consumer is
  # tests/app_pipeline_shape.tftest.hcl, which it does not read. That is the
  # declaration doing its job rather than a leftover.
  # tflint-ignore: terraform_unused_declarations
  app_build_exported_variables = ["IMAGE_TAG", "IMAGE_DIGEST"]

  # The staging Deploy action's exports, interpolated by the smoke action
  # beside it as #{DeployStaging.SMOKE_URL} and #{DeployStaging.SMOKE_DIGEST}.
  # These two are what let the smoke build hold no AWS credentials at all
  # (plan §D6): it is handed the URL and the digest rather than reading either
  # from state.
  # tflint-ignore: terraform_unused_declarations
  app_deploy_exported_variables = ["SMOKE_URL", "SMOKE_DIGEST"]

  # The production Plan action's exports, interpolated by the approval beside
  # it as #{PlanProd.PLAN_SUMMARY} and #{PlanProd.PLAN_URL}. The same three
  # names plan_exported_variables carries for the infra pipeline, declared
  # separately because pipelines/app-plan.yml is a different file that can be
  # edited without touching pipelines/infra-plan.yml.
  # tflint-ignore: terraform_unused_declarations
  app_plan_exported_variables = ["PLAN_STATUS", "PLAN_SUMMARY", "PLAN_URL"]
}

# ---------------------------------------------------------------------------
# Phase 9 — the observability plane
# ---------------------------------------------------------------------------

locals {
  # Production is addressed BY NAME, never through remote state, and that is
  # forced rather than chosen. infra/ (enable_prod = true) already reads this
  # layer's state; reading prod's back would make each layer depend on the
  # other — and Terraform would not report it as a cycle, because the two are
  # separate state files read at plan time. The symptom would be this layer's
  # plan failing to read a state file `make teardown` emptied, in the layer
  # whose whole purpose is surviving teardown. Plan §D2 and §F1.
  #
  # Every segment below is this layer's own convention variables. The two names
  # that cross the boundary are pinned as string literals by
  # infra/tests/prod_outputs.tftest.hcl, so a rename over there
  # fails there rather than silently orphaning the rule over here.
  observability = {
    collector_name = "${local.name_prefix}-release-metrics"
    dashboard_name = "${local.name_prefix}-release"

    prod_cluster_name = "${local.name_prefix}-prod-cluster"
    prod_service_name = "${local.name_prefix}-prod-api"

    prod_service_arn = join("", [
      "arn:aws:ecs:${var.region}:${var.account_id}:service/",
      "${local.name_prefix}-prod-cluster/${local.name_prefix}-prod-api",
    ])

    # Load balancer NAMES, not ARNs. The CloudWatch LoadBalancer dimension is
    # app/<name>/<16 hex characters>, and the hex is assigned at creation — the
    # one dimension in this dashboard the convention cannot supply. Widgets
    # search on these instead, which also survives a teardown/rebuild giving
    # the load balancer a new suffix. Plan §D17.
    prod_alb_name    = "${local.name_prefix}-prod-alb"
    staging_alb_name = "${local.name_prefix}-staging-alb"

    prod_table_names = [
      "${local.name_prefix}-prod-accounts",
      "${local.name_prefix}-prod-transactions",
    ]
  }
}
