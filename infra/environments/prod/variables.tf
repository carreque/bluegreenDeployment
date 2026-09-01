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

    Ninety, by arithmetic rather than taste. The handler opens ONE connection
    and issues three requests over it, and it retries the connection — and only
    the connection — when the transport fails:

      connect(), 3 attempts x 10s      30s
      backoff between attempts, 1 + 3   4s
      /health read                      5s
      /ready read                      30s   Phase 5 F5: 25.6s to fail when
      /version read                     5s   DynamoDB is unreachable
                                       ----
                                       74s   + a 5s reserve = 79s

    /ready keeps the larger budget because botocore retries with backoff and a
    shorter cap would report a timeout instead of the 503 that names the real
    cause — on exactly the failure the dark canary exists to catch.

    A function killed mid-probe produces an invocation error, and plan §D3 makes
    that a rejection of a build that was fine. The handler holds its own deadline
    from context.get_remaining_time_in_millis() so it returns a reasoned verdict
    rather than being killed, and this value is what that deadline is derived
    from.

    Sixty was the previous value, sized for 10 + 30 + 10 = 50s of probing with no
    retry. One deployment in four was then reversed by a single TLS handshake
    that hung for ten seconds. See
    docs/phases/phase6/2026-08-31-dark-canary-transport-timeout.md.

    ECS imposes no competing limit: describe-services reports each hook's
    timeoutConfiguration as timeoutInMinutes 1440, action ROLLBACK. Confirmed
    against the real service on 2026-09-01, so raising this costs nothing but
    the wall-clock of a deployment that is already failing.
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.hook_timeout_seconds >= 90
    error_message = "hook_timeout_seconds must be at least 90; three reads plus a retried connection are worst-case 74s, and the handler reserves 5s to return a verdict rather than be killed."
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
