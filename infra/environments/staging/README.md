# infra/environments/staging

The staging environment: an internet-facing ALB terminating TLS, one Fargate
task on the rolling deployment controller, the two DynamoDB tables the
application uses, and the `staging-api.carloscloudengineer.com` record.

Deliberately the simpler of the two environments. Its job is to fail fast, not
to demonstrate blue/green — that is `../prod`.

## What it depends on

Both through `terraform_remote_state`, unlike `../../network`, because it
consumes real ARNs and ids rather than derived strings:

| Layer | Consumed |
|---|---|
| `foundation` | certificate ARN, hosted zone id, staging hostname, ECR repository URL and ARN |
| `network` | VPC id, public and private subnet ids, the `staging` ALB and task security groups, the container port |

It does **not** read `foundation`'s `name_prefix` or `common_tags`. That layer's
tags say `environment = shared`; this one is `staging`. Derived strings are
rebuilt locally and only real identifiers cross the boundary.

## What it costs

Roughly $25/month: the ALB is most of it, the single 0.25 vCPU Fargate task is
most of the rest, and the on-demand tables cost nothing while idle. Destroyed
by `make teardown` along with `prod` and `network`.

## Applying it

`image_tag` has no default, because the correct value changes with every build:

    cp terraform.tfvars.example terraform.tfvars   # then set image_tag
    make plan-staging
    make apply-staging
    make smoke-staging

The tag must already be in ECR or the plan fails in `data.aws_ecr_image`,
naming the tag it could not find. `make seed-ecr` is what puts the first one
there.

See [the Phase 5 runbook](../../../docs/runbooks/phase-05-staging.md).
