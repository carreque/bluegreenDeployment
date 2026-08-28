resource "aws_cloudwatch_log_group" "api" {
  # checkov:skip=CKV_AWS_338:fourteen-day retention is deliberate on an environment that is destroyed when idle. Retention is the entirety of what a log group costs. Same reasoning as network's flow logs.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. These are application logs from a staging environment carrying no production data.
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  # checkov:skip=CKV_AWS_65:Container Insights bills per custom metric on the layer whose purpose is being cheap to leave running, and Phase 9 owns observability and builds the dashboard that would consume it. Written as an explicit "disabled" rather than omitted so the choice is visible. Plan §D7.
  name = "${local.env_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.env_prefix}-api"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  # Two roles, not one. The execution role is assumed by the ECS agent before
  # the container starts, to pull the image and open the log stream; the task
  # role is what the application code itself runs as. Design §8.1.
  execution_role_arn = aws_iam_role.task_exec.arn
  task_role_arn      = aws_iam_role.task.arn

  # Inherited from Phase 2, and not optional: the image is built linux/arm64
  # only, because it runs on Graviton, which is cheaper. An X86_64 task
  # definition fails at task start with an exec format error — after a clean
  # apply, so Terraform reports success and the service never stabilises.
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name = local.container_name

      # By digest, not by tag. There is one identifier for "what is running" in
      # this layer, and BGD_IMAGE_DIGEST below is the same expression, so
      # /version cannot disagree with what ECS actually deployed. Plan §D3.
      image     = local.image_reference
      essential = true

      portMappings = [
        {
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "BGD_ENVIRONMENT", value = local.environment },
        { name = "BGD_AWS_REGION", value = var.region },
        { name = "BGD_ACCOUNTS_TABLE", value = aws_dynamodb_table.accounts.name },
        { name = "BGD_TRANSACTIONS_TABLE", value = aws_dynamodb_table.transactions.name },

        # The second Phase 2 inheritance. An image cannot carry its own digest,
        # because the digest is its hash, so the deployer is the only party that
        # knows it. Without this /version reports "unknown" in a live
        # environment — nothing fails, the evidence surface is simply wrong.
        { name = "BGD_IMAGE_DIGEST", value = data.aws_ecr_image.api.image_digest },

        # BGD_DYNAMODB_ENDPOINT_URL is deliberately absent. The settings default
        # of null is what selects real AWS; setting it points the client at
        # DynamoDB Local.
      ]

      # Measured against the real image before this was written: it starts and
      # serves under a read-only root filesystem, because the image sets
      # PYTHONDONTWRITEBYTECODE=1 and nothing in the request path writes to
      # disk. Plan §F5.
      readonlyRootFilesystem = true

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}
