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

    Changing this value is what *initiates* a blue/green deployment: Terraform
    registers a new task definition revision and ECS begins the shift. Plan §D10.
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
  description = <<-EOT
    How many tasks the service runs. Two, not staging's one, and for two
    independent reasons: design §10 prices production at two tasks, and two
    tasks across two availability zones is the minimum that makes the
    UnHealthyHostCount bake alarm mean "one task is sick" rather than being a
    synonym for "the service is down". Plan §D13.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "log_retention_days" {
  description = "CloudWatch retention for the application and hook log groups. Short by design on an environment destroyed when idle."
  type        = number
  default     = 14
}

variable "bake_time_minutes" {
  description = <<-EOT
    How long ECS observes the alarms after the production traffic shift before
    calling the deployment done. Converted to a string at the call site, because
    deployment_configuration.bake_time_in_minutes is typed string in the provider
    schema and the number form fails terraform validate. Plan §F1.
  EOT
  type        = number
  default     = 5

  validation {
    condition     = var.bake_time_minutes >= 1
    error_message = "bake_time_minutes must be at least 1; a zero-minute bake observes nothing."
  }
}

variable "hook_timeout_seconds" {
  description = <<-EOT
    Timeout for each lifecycle hook function, in seconds.

    Sixty, by arithmetic rather than taste. The handler probes three paths in
    sequence and /ready is allowed max(BGD_TIMEOUT_SECONDS, 30) because Phase 5's
    F5 measured /ready taking 25.6 seconds to fail when DynamoDB is unreachable —
    botocore retries with backoff. Worst case is therefore 10s + 30s + 10s = 50s
    of probing. A 30-second function would be killed mid-/ready, ECS would see an
    invocation error, and plan §D3 makes that a rejection of a build that was
    fine. Plan Task 2 Step 3.
  EOT
  type        = number
  default     = 60

  validation {
    condition     = var.hook_timeout_seconds >= 60
    error_message = "hook_timeout_seconds must be at least 60; three sequential probes are worst-case 50s."
  }
}

variable "alarm_p95_seconds" {
  description = <<-EOT
    Threshold for the p95 target response time bake alarm, in seconds.

    Chosen, not measured — as are the other three thresholds in alarms.tf. The
    runbook's step 10 records the real numbers under real traffic. Plan §D8.
  EOT
  type        = number
  default     = 2
}
