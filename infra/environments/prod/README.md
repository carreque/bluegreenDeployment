# infra/environments/prod

The production environment, and the technical centre of the project. An
internet-facing ALB with a `:443` production listener and a `:8443` test
listener over two target groups, two Fargate tasks on the **native blue/green
deployment controller**, three Lambda lifecycle hooks, a five-minute
alarm-gated bake, the two DynamoDB tables, and the
`api.carloscloudengineer.com` record.

What distinguishes it from `../staging` is not that it is bigger — it is two
tasks rather than one — but that a deployment to it is **a sequence with
gates**, not a replacement: green is provisioned alongside blue, validated
through a listener no user reaches, promoted, baked under alarms, and abandoned
if any of that fails.

## The deployment, in order

| Stage | What happens | What can stop it |
|---|---|---|
| `PRE_SCALE_UP` | Before green exists | The pre-scale hook probes `:443`. A deployment into an already-broken environment is refused, so a later failure is unambiguously the new build |
| Provision green | The new task set starts and registers in the idle target group | Health checks on `/health` |
| Test traffic shift | The `:8443` rule points at green | — |
| `POST_TEST_TRAFFIC_SHIFT` | **The dark canary.** The post-test hook probes `:8443` | A green task that starts but cannot reach DynamoDB passes `/health` and fails `/ready`. Rejected before one user request touches it |
| Production traffic shift | The `:443` rule points at green | — |
| `POST_PRODUCTION_TRAFFIC_SHIFT` | The post-prod hook probes `:443` | Confirms the promotion actually worked |
| Bake, 5 minutes | ECS watches four alarms | Any alarm in ALARM rolls the deployment back automatically |

`terraform apply` does not return until all of that has finished or rolled back
(`wait_for_steady_state`), so **expect six to ten minutes**. That is deliberate:
an apply that reports success while the deployment it started is still running
could leave a green plan over a reverted service.

## What it owns

| File | Contents |
|---|---|
| `alb.tf` | The load balancer, two target groups, three listeners, two listener **rules** |
| `ecs.tf` | Log group, cluster, task definition, and the blue/green service |
| `hooks.tf` | Three instantiations of `../../modules/lambda` |
| `alarms.tf` | The four alarms the bake is gated on |
| `iam.tf` | Four of this layer's five roles; the fifth is the module's, created three times |
| `dynamodb.tf` | `accounts` and `transactions`, LSI included — prod's own, not shared with staging |
| `dns.tf` | The one cross-layer write, into `foundation`'s hosted zone |

`hooks.tf` and `alarms.tf` are separate from `ecs.tf` even though the service
references both, because they are the parts a reviewer comparing the two
environments needs to find, and burying them in a 200-line `ecs.tf` hides the
diff that is the whole point of this layer.

## What it depends on

Both through `terraform_remote_state`:

| Layer | Consumed |
|---|---|
| `foundation` | certificate ARN, hosted zone id, `api_domain`, ECR repository URL and ARN |
| `network` | VPC id, public and private subnet ids, the **`prod`** ALB and task security groups, the container port |

**Nothing in `network` changes for this layer.** Phase 4 built four security
groups rather than two shared ones, and opened `:8443` on the prod ALB group
alone — which is why blue/green needs no edit there.

It does **not** read `foundation`'s `name_prefix` or `common_tags`. That layer's
tags say `environment = shared`; this one is `prod`.

## Two things that are not obvious

**Which colour is production is not a property of either target group.** It is
whichever one the `:443` listener rule currently forwards to, and ECS swaps that
during every deployment. `blue` in `alb.tf` and `ecs.tf` is the *initial*
assignment only. Nothing in this layer may assume blue is serving.

**Both serving listeners carry a listener rule rather than relying on a default
action.** `advanced_configuration` takes `production_listener_rule` and
`test_listener_rule`, which are **rule** ARNs — a default action cannot be named
there, so a listener without a rule cannot participate in a shift at all. The
default actions are a fixed 503 precisely because they should be unreachable.

## What it costs

Roughly $40/month: the ALB is most of it, two 0.25 vCPU ARM64 Fargate tasks are
most of the rest, and the on-demand tables and three rarely-invoked Lambdas cost
close to nothing. Destroyed **first** by `make teardown`.

## Applying it

    cp terraform.tfvars.example terraform.tfvars   # then set image_tag
    make plan-prod
    make apply-prod        # six to ten minutes; it waits for the deployment
    make smoke-prod

After the first apply, **changing `image_tag` and running `make apply-prod` is
what starts a blue/green deployment.** Terraform initiates; the AWS CLI observes
(`aws ecs list-service-deployments`, `describe-service-deployments`) and
intervenes (`aws ecs stop-service-deployment`). Never
`aws ecs update-service --task-definition` — Terraform owns the service shape,
and a CLI update registers drift the next apply reverts, mid-deployment.

See [the Phase 6 runbook](../../../docs/runbooks/phase-06-prod-blue-green.md).
