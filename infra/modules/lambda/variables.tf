variable "function_name" {
  description = "Full function name, already carrying the naming convention's prefix. Also names the log group and the execution role."
  type        = string

  validation {
    condition     = length(var.function_name) <= 64
    error_message = "Lambda function names are capped at 64 characters."
  }
}

variable "source_file" {
  description = <<-EOT
    Absolute or module-relative path to the single .py file that becomes the
    deployment package.

    One file, deliberately. Every function this module packages uses the
    standard library only, so the zip is one entry and archive_file can build it
    with no network access. A dependency-bearing package needs a different
    module — Phase 9's metrics collector is the first candidate, and
    README.md says so.
  EOT
  type        = string
}

variable "handler" {
  description = "Lambda handler path. `handler.handler` is correct for a single file named handler.py, because archive_file places it at the zip root."
  type        = string
  default     = "handler.handler"
}

variable "environment" {
  description = "Environment variables for the function. This is the whole of a hook's per-instance configuration — the code is identical across all three."
  type        = map(string)
  default     = {}
}

variable "timeout_seconds" {
  description = "Function timeout. A lifecycle hook is a synchronous deployment gate, so this bounds how long a deployment stage can hang."
  type        = number
  default     = 60
}

variable "memory_size_mb" {
  description = "Function memory. 128 is the floor and ample for a handler whose work is three HTTP requests; memory also scales CPU, which nothing here needs."
  type        = number
  default     = 128
}

variable "log_retention_days" {
  description = "CloudWatch retention for this function's log group."
  type        = number
  default     = 14
}
