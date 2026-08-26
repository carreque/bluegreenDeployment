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
