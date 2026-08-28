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
  description = "Expected AWS account. Asserted by the provider."
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

variable "vpc_cidr" {
  description = "Address space for the whole VPC. Public subnets are /24s carved from its first /20; private subnets are /20s after it."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be valid and no smaller than a /16; the /20 private subnets do not fit otherwise."
  }
}

variable "az_count" {
  description = <<-EOT
    How many availability zones to spread across.

    Two is the floor, not a preference: an ALB requires subnets in at least two
    AZs, and a blue/green deployment confined to one AZ is not an availability
    story (design §3.1). Raising it multiplies subnets and route tables but not
    NAT Gateways — there is deliberately still only one.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "flow_log_retention_days" {
  description = "How long VPC flow logs are kept. Short by design: they are a debugging aid for an ephemeral layer, and retention is what they cost."
  type        = number
  default     = 7
}

variable "container_port" {
  description = "Port the application listens on. Fixed by app/Dockerfile (EXPOSE 8080); the ALB-to-task rules open exactly this."
  type        = number
  default     = 8080
}
