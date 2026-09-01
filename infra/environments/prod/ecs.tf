resource "aws_cloudwatch_log_group" "api" {
  # checkov:skip=CKV_AWS_338:fourteen-day retention is deliberate on an environment that make teardown destroys at the end of every session. Retention is the entirety of what a log group costs, and the blue/green evidence this phase produces is read within minutes of the deployment that produced it, not weeks later.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. A customer-managed key bills per API call on a log stream that carries application stdout and no credential, token or customer record.
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  # checkov:skip=CKV_AWS_65:Container Insights bills per custom metric, and Phase 9 owns observability and builds the dashboard that would consume it. Written as an explicit "disabled" rather than omitted so the choice is visible. Phase 5 plan §D7.
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
  # definition fails at task start with an exec format error — and in a
  # blue/green deployment green then never becomes healthy, the deployment
  # stalls, and wait_for_steady_state times the apply out several minutes later
  # with a message about steady state rather than about architecture.
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name = local.container_name

      # By digest, not by tag. There is one identifier for "what is running" in
      # this layer, and BGD_IMAGE_DIGEST below is the same expression, so
      # /version cannot disagree with what ECS actually deployed.
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

        # The second Phase 2 inheritance, and it matters more here than in
        # staging. An image cannot carry its own digest, because the digest is
        # its hash, so the deployer is the only party that knows it. /version is
        # this phase's evidence surface and the second exit criterion is read
        # directly off it — without this the endpoint reports "unknown" and the
        # criterion is unprovable.
        { name = "BGD_IMAGE_DIGEST", value = data.aws_ecr_image.api.image_digest },

        # BGD_DYNAMODB_ENDPOINT_URL is deliberately absent. The settings default
        # of null is what selects real AWS; setting it points the client at
        # DynamoDB Local.
      ]

      # Measured against the real image in Phase 5's F5: it starts and serves
      # under a read-only root filesystem, because the image sets
      # PYTHONDONTWRITEBYTECODE=1 and nothing in the request path writes to disk.
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

  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true

  # The application starts in a second or two, but the first health check is
  # scheduled immediately. Sixty seconds of grace stops a cold start being
  # counted as a failure — which here would mean green never registering
  # healthy and the deployment rolling back a build that was fine.
  health_check_grace_period_seconds = 60

  # Plan §D11. Without this, terraform apply returns success the moment ECS
  # accepts the deployment, and every part of blue/green that matters — the
  # hooks, the traffic shift, the bake, an alarm rollback — happens *after*
  # Terraform has already reported success. A rolled-back deployment would then
  # leave a green plan over a red service.
  #
  # The trade, stated: a production apply takes six to ten minutes instead of
  # returning immediately, and Phase 7's pipeline apply stage inherits that
  # duration. Accepted — a pipeline stage that finishes before the deployment it
  # triggered has succeeded is not a gate.
  #
  # Staging deliberately does not get this. Its job is to fail fast and its
  # circuit breaker already reverts it.
  wait_for_steady_state = true

  # The whole phase, in one block. Staging writes ROLLING here.
  deployment_configuration {
    strategy = "BLUE_GREEN"

    # tostring, because bake_time_in_minutes is typed *string* in the provider
    # schema and the number form fails terraform validate. Plan §F1.
    bake_time_in_minutes = tostring(var.bake_time_minutes)

    # A SET of three, one per stage. Each names the function built for that
    # stage — crossed, the dark canary would probe the production listener,
    # validate the colour already serving, and approve every bad build. Two
    # tests in different runs assert the pairing from opposite ends.
    #
    # role_arn is hook_invoke on all three, never bluegreen: this slot needs
    # lambda:InvokeFunction, and advanced_configuration's needs
    # elasticloadbalancing on listener rules. Two required slots, two different
    # permission sets, two roles. Plan §D4.
    lifecycle_hook {
      hook_target_arn  = module.pre_scale_hook.function_arn
      role_arn         = aws_iam_role.hook_invoke.arn
      lifecycle_stages = ["PRE_SCALE_UP"]
    }

    lifecycle_hook {
      hook_target_arn  = module.post_test_hook.function_arn
      role_arn         = aws_iam_role.hook_invoke.arn
      lifecycle_stages = ["POST_TEST_TRAFFIC_SHIFT"]
    }

    lifecycle_hook {
      hook_target_arn  = module.post_prod_hook.function_arn
      role_arn         = aws_iam_role.hook_invoke.arn
      lifecycle_stages = ["POST_PRODUCTION_TRAFFIC_SHIFT"]
    }
  }

  # NO deployment_circuit_breaker, deliberately. Staging sets it; this layer
  # does not. The bake period with alarms IS this environment's rollback
  # mechanism, and whether the two interact — and in what order they would each
  # try to revert — is not documented in the schema and not something to
  # discover during a production shift. One rollback mechanism, chosen on
  # purpose. A test asserts the omission so it reads as a decision rather than a
  # gap. If the bake alarms prove insufficient in practice, adding the circuit
  # breaker is a considered change with the interaction understood.

  network_configuration {
    subnets          = local.network.private_subnet_ids
    security_groups  = [local.network.task_security_group_ids[local.environment]]
    assign_public_ip = false
  }

  # ONE load_balancer block, not two. Two is the shape people expect and the
  # provider does not accept: one target group goes in target_group_arn, the
  # other in advanced_configuration.alternate_target_group_arn. Plan §F1.
  #
  # blue and green here are the *initial* assignment only. After the first
  # deployment, which colour is production is ECS's business — nothing in this
  # layer may assume blue is serving.
  #
  # And this block takes NO lifecycle ignore_changes, deliberately — unlike the
  # two listener rules in alb.tf, which need it. The asymmetry is real: ECS
  # never rewrites these two ARNs. They declare the pair, not the roles; the
  # role lives on the production listener rule, which is what ECS reads and what
  # ECS rewrites. Verified 2026-09-01 — the value is identical on every service
  # revision, and Terraform's UpdateService never sends loadBalancers at all, so
  # `terraform plan` reports no change here even mid-deployment.
  #
  # Ignoring it would also cost something: load_balancer is a set in the
  # provider schema, so ignore_changes could only take the whole block, and the
  # two listener rule ARNs and the bluegreen role ARN below would stop being
  # managed. Real cost, no benefit. See fixIssues.md.
  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = local.container_name
    container_port   = local.container_port

    advanced_configuration {
      alternate_target_group_arn = aws_lb_target_group.green.arn

      # RULE arns, not listener arns. Passing a listener ARN is an apply-time
      # failure with a message that names the attribute but not the reason
      # (Phase 0 A7), and alb.tf's two aws_lb_listener_rule resources exist for
      # these two lines alone.
      production_listener_rule = aws_lb_listener_rule.production.arn
      test_listener_rule       = aws_lb_listener_rule.test.arn

      role_arn = aws_iam_role.bluegreen.arn
    }
  }

  # Both required booleans — there is no "just list them" form. Omitting this
  # block means the five-minute bake observes nothing and rolls back on nothing,
  # and the deployment still succeeds, so the gap would be silent.
  alarms {
    alarm_names = local.bake_alarm_names
    enable      = true
    rollback    = true
  }

  # Phase 5's two reasons, plus the rules.
  #
  # First: ECS refuses to create a service whose target group is not yet
  # attached to a load balancer, and Terraform sees only the service's
  # reference to the target groups — not the listeners that attach them.
  #
  # Second: the task definition references the two roles, but the permissions
  # the running task needs live in their policies. Nothing else references those
  # policy resources, so without naming them here they are leaf nodes and
  # Terraform is free to create them in parallel with the service. IAM is
  # eventually consistent even after PutRolePolicy returns.
  #
  # Third, new here: advanced_configuration references both listener rules, and
  # Terraform sequences a rule no more reliably than it did the listener.
  #
  # The hook invoke policy is listed for the same eventual-consistency reason as
  # the task policies: PRE_SCALE_UP fires within seconds of the service being
  # created, and a hook ECS is not yet permitted to invoke is an invocation
  # error, which plan D3 makes a rejection of a deployment that was fine.
  depends_on = [
    aws_lb_listener.https,
    aws_lb_listener.test,
    aws_lb_listener_rule.production,
    aws_lb_listener_rule.test,
    aws_iam_role_policy.task_exec,
    aws_iam_role_policy.task,
    aws_iam_role_policy.hook_invoke,
    aws_iam_role_policy_attachment.bluegreen,
  ]
}
