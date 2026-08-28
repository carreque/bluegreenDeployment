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

variable "state_bucket" {
  description = "Bucket holding every layer's state. This layer reads foundation's and network's outputs from it."
  type        = string
  default     = "bgd-us-east-1-tfstate-590184028094"
}

variable "image_tag" {
  description = <<-EOT
    ECR tag to deploy. Resolved to a digest by data.aws_ecr_image, and the task
    definition references the digest rather than this tag.

    The tag must already exist in ECR or terraform plan fails in the data source.
    That is deliberate: the alternative is applying a task definition ECS cannot
    pull. Phase 3's `make seed-ecr` is what puts the first one there, and
    `cat app/dist/image-ref.txt` names it.
  EOT
  type        = string
}

variable "task_cpu" {
  description = "Fargate CPU units. 256 is a quarter vCPU, the smallest Fargate offers and what design §10 priced."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate memory in MiB. 512 is the minimum permitted at 256 CPU units."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "How many tasks the service runs. One, deliberately: staging exists to fail fast, not to be available."
  type        = number
  default     = 1

  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "log_retention_days" {
  description = "CloudWatch retention for the application log group. Short by design on an environment destroyed when idle."
  type        = number
  default     = 14
}
