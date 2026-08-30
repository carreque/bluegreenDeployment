variable "project_name" {
  description = "Short project identifier used as the prefix of every resource name."
  type        = string
  default     = "bgd"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.project_name))
    error_message = "project_name must be 2-8 lowercase alphanumeric characters (ALB names are capped at 32)."
  }
}

variable "region" {
  description = "AWS region. Also a name segment and a tag value, not only a provider setting."
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "Expected AWS account. Asserted by the provider, and the suffix that makes globally-unique bucket names unique."
  type        = string
  default     = "590184028094"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be twelve digits."
  }
}

variable "owner" {
  description = "Value of the owner tag: who to contact, and who pays."
  type        = string
  default     = "carreque45@gmail.com"
}

variable "domain_name" {
  description = "Registered apex domain. Both API hostnames derive from it."
  type        = string
  default     = "carloscloudengineer.com"
}

variable "wait_for_validation" {
  description = <<-EOT
    Whether to block the apply until the ACM certificate is issued.

    True is correct here: Phase 0 confirmed the hosted zone already exists and is
    correctly delegated, so the validation CNAME resolves publicly within minutes.
    Set false only on the zone-create path, where the registrar's name servers do
    not yet point at the new zone and the wait would hang for its 75-minute
    default timeout before failing (design §1.7).
  EOT
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Address subscribed to the alert topic. Requires a manual confirmation click; see the Phase 3 runbook."
  type        = string
  default     = "carreque45@gmail.com"
}

variable "ecr_max_image_count" {
  description = "How many images the registry retains before the lifecycle policy expires the oldest."
  type        = number
  default     = 10
}

variable "noncurrent_artifact_retention_days" {
  description = "How long superseded artifact-bucket object versions are kept."
  type        = number
  default     = 90
}

variable "github_repository_id" {
  description = "owner/name of the repository CodePipeline sources from, through the CodeConnections link."
  type        = string
  default     = "carreque/bluegreenDeployment"

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository_id))
    error_message = "github_repository_id must be owner/name, not a URL."
  }
}

variable "github_branch" {
  description = "Branch the infra pipeline watches. Merging to it is what fires a deployment (roadmap §2.1)."
  type        = string
  default     = "main"
}

variable "deploy_scope_default" {
  description = <<-EOT
    DEPLOY_SCOPE for a run nobody chose a scope for.

    A run started by the git trigger cannot supply execution variables, so every
    merge to main takes this value (plan §F4). It is `all` deliberately: an infra
    change is normally a change you want in production, and the four manual
    approvals — not this default — are what stand between the merge and prod.

    Cumulative. `staging` also applies foundation and network; `all` reaches prod.
  EOT
  type        = string
  default     = "all"

  validation {
    condition     = contains(["foundation", "network", "staging", "all"], var.deploy_scope_default)
    error_message = "deploy_scope_default must be one of foundation, network, staging, all."
  }
}

variable "pipeline_log_retention_days" {
  description = "Retention on the three CodeBuild log groups. A pipeline log is worth keeping only until the next deployment is understood."
  type        = number
  default     = 30
}

variable "pipeline_artifact_retention_days" {
  description = "How long CodePipeline's own artifacts — the source zip and the four saved plans, one set per execution — are kept before the lifecycle rule expires them."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Phase 8 — the application pipeline
# ---------------------------------------------------------------------------

variable "app_scope_default" {
  description = <<-EOT
    APP_SCOPE for a run nobody chose a scope for.

    A run started by the git trigger cannot supply execution variables, so every
    merge to main under app/** takes this value — the same fact Phase 7 §F4
    recorded for DEPLOY_SCOPE. It is `all` deliberately: an application change is
    normally a change you want in production, and the manual approval on a plan a
    human read — not this default — is what stands between the merge and prod.

    Cumulative, and it names where a run STOPS. `build` builds, tests, SBOMs and
    pushes without deploying anything, which is what Phase 11 needs to put a
    deliberately broken image in the registry. `staging` also deploys and smokes
    staging. `all` reaches production.
  EOT
  type        = string
  default     = "all"

  validation {
    condition     = contains(["build", "staging", "all"], var.app_scope_default)
    error_message = "app_scope_default must be one of build, staging, all."
  }
}

variable "app_build_compute_type" {
  description = <<-EOT
    Compute size for the image build.

    Its own variable rather than the shared local the three infra projects use,
    because this is the only ARM project in the account and the only one that
    runs a buildx build and two test containers.

    SMALL, and the reason is a constraint rather than a preference: CodeBuild's
    documented compute matrix offers ARM_CONTAINER only BUILD_GENERAL1_SMALL and
    BUILD_GENERAL1_LARGE, and which sizes a region actually accepts cannot be
    confirmed without an AWS session (plan §F12). SMALL is the value that is
    certainly valid; LARGE is the escalation if the build turns out to be the
    long pole of a deployment, and it is one variable away.
  EOT
  type        = string
  default     = "BUILD_GENERAL1_SMALL"

  validation {
    condition     = contains(["BUILD_GENERAL1_SMALL", "BUILD_GENERAL1_LARGE"], var.app_build_compute_type)
    error_message = "app_build_compute_type must be BUILD_GENERAL1_SMALL or BUILD_GENERAL1_LARGE — ARM_CONTAINER offers no others."
  }
}

variable "app_artifact_prefix" {
  description = <<-EOT
    Key prefix in the artifact bucket under which the build publishes the SBOM,
    the two test reports and build-metadata.json, one directory per image tag.

    Deliberately NOT covered by any expiry rule (plan §D16): design §4.2 wants
    an SBOM for the image running in production three deployments ago, and that
    is only available if the object describing it is still there.
  EOT
  type        = string
  default     = "app-builds"
}

variable "app_pipeline_artifact_retention_days" {
  description = <<-EOT
    How long the APPLICATION pipeline's own artifacts — the clone reference and
    one saved production plan per execution — are kept before the prefix-scoped
    lifecycle rule expires them.

    Separate from var.pipeline_artifact_retention_days so the two pipelines'
    stores can diverge without one edit silently changing both, and because
    this one's rule must never be widened to cover var.app_artifact_prefix.
  EOT
  type        = number
  default     = 30
}
