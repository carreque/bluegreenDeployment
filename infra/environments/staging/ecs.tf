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

resource "aws_ecs_service" "api" {
  name            = "${local.env_prefix}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Both mandatory for cost attribution, and neither is computed: omitting
  # propagate_tags sends nothing and ECS defaults to no propagation, leaving
  # every running task untagged while terraform plan stays clean. SERVICE
  # rather than TASK_DEFINITION because Phase 8 revises the task definition on
  # every image push, which makes its tags the less reliable source.
  # Convention §6.1.
  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true

  # The application starts in a second or two, but the first health check is
  # scheduled immediately. Sixty seconds of grace stops a cold start being
  # counted as a failure and rolled back by the circuit breaker below.
  health_check_grace_period_seconds = 60

  # ROLLING is also the API default. It is stated because this one word is the
  # difference between this layer and Phase 6's, and a difference that matters
  # should be visible rather than implied by an absence. Plan §F7.
  deployment_configuration {
    strategy = "ROLLING"
  }

  # Staging's stated job is to fail fast. Without this, a task that never
  # becomes healthy is retried forever; with it, the service reverts to the
  # previous task definition and the failure is a finished event rather than an
  # ongoing one. The trade accepted is that the broken task set is gone before
  # it can be inspected — the log group keeps what the container printed, which
  # is the part worth reading. Plan §D8.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.network.private_subnet_ids
    security_groups  = [local.network.task_security_group_ids[local.environment]]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = local.container_name
    container_port   = local.container_port
  }

  # Load-bearing, and not inferable from the graph, for two independent
  # reasons.
  #
  # First: ECS refuses to create a service whose target group is not yet
  # attached to a load balancer, and Terraform sees only the service's
  # reference to the target group — not the listener that attaches it.
  # Without aws_lb_listener.https here, the first apply fails with "target
  # group does not have an associated load balancer" and the second succeeds,
  # which is the most confusing kind of intermittent failure.
  #
  # Second: the task definition above references aws_iam_role.task_exec.arn
  # and aws_iam_role.task.arn — the roles — but the permissions the running
  # task actually needs live in aws_iam_role_policy.task_exec and
  # aws_iam_role_policy.task. Nothing else in this file references those
  # policy resources, so without naming them here they are leaf nodes in the
  # graph and Terraform is free to create them in parallel with the service
  # rather than before it. IAM is eventually consistent even after
  # PutRolePolicy returns, so a task can start pulling its image or writing
  # its logs before the policy that permits it has actually propagated — the
  # first task can fail CannotPullContainerError ("not authorized to perform:
  # ecr:GetAuthorizationToken"), or start and silently drop its logs. Worse,
  # deployment_circuit_breaker below has rollback = true but no previous task
  # set to roll back to on a first apply, and there is no
  # wait_for_steady_state, so terraform apply reports SUCCESS while the
  # service never actually stabilises. Listing both policies here does not
  # guarantee IAM has propagated by the time the service is created, but it
  # does guarantee the roles are fully populated first, which is the ordering
  # within Terraform's own control.
  depends_on = [
    aws_lb_listener.https,
    aws_iam_role_policy.task_exec,
    aws_iam_role_policy.task,
  ]
}
