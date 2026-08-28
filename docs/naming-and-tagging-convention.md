# Resource Naming and Tagging Convention

**Date:** 2026-08-04
**Status:** Adopted in Phase 0
**Applies to:** every AWS resource created by this project, in every layer

Naming and tagging are decided once, here, before the first resource exists. Retrofitting a convention means renaming resources, and renaming an AWS resource usually means destroying and recreating it.

---

## 1. Naming pattern

```
<projectName>-<region>-<resource>
```

All lowercase, hyphen-separated, no underscores. Every segment is mandatory.

| Segment | Value |
|---|---|
| `projectName` | `bgd` |
| `region` | `us-east-1` |
| `resource` | a descriptive suffix, see §3 |

### Why `bgd` and not `bluegreen`

Application Load Balancer and target group names are capped at **32 characters**, and the cap is enforced at apply time with an unhelpful error. The fixed overhead of this pattern is `len(projectName) + 1 + 9 + 1`, since `us-east-1` is nine characters. The longest resource suffix in the design is `prod-api-blue` at thirteen.

| projectName | Longest name | Length | Fits in 32? |
|---|---|---|---|
| `bgd` | `bgd-us-east-1-prod-api-blue` | 27 | ✅ |
| `bgdeploy` | `bgdeploy-us-east-1-prod-api-blue` | 32 | exactly at the limit |
| `bluegreen` | `bluegreen-us-east-1-prod-api-blue` | 33 | ❌ |

`bgd` leaves five characters of headroom. Anything longer than eight characters cannot work with this pattern in this region.

The value lives in one Terraform variable, so changing it is a single edit:

```hcl
variable "project_name" {
  description = "Short project identifier used as the prefix of every resource name."
  type        = string
  default     = "bgd"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.project_name))
    error_message = "project_name must be 2-8 lowercase alphanumeric characters (ALB names are capped at 32)."
  }
}
```

---

## 2. Where the environment goes

The pattern has no environment segment, but staging and production each need their own ALB, ECS service, target groups and DynamoDB tables. Two resources cannot share a name.

**Resolution: the environment is the first word of the `resource` segment, for any resource that exists per-environment.**

```
bgd-us-east-1-prod-alb
bgd-us-east-1-staging-alb
```

Resources that exist once for the whole project — the state bucket, ECR repositories, the hosted zone — omit it, because there is nothing to disambiguate:

```
bgd-us-east-1-tfstate-590184028094
bgd-us-east-1-api            (ECR)
```

The environment still appears on every resource as a **tag** (§5), which is what cost allocation and filtering actually query. The name segment exists only to keep names unique and readable.

---

## 3. Per-resource-type naming

| Resource type | Pattern | Example |
|---|---|---|
| S3 bucket | `bgd-us-east-1-<purpose>-<accountId>` | `bgd-us-east-1-tfstate-590184028094` |
| ECR repository | `bgd-us-east-1-<service>` | `bgd-us-east-1-api` |
| VPC | `bgd-us-east-1-vpc` | `bgd-us-east-1-vpc` |
| Subnet | `bgd-us-east-1-<tier>-<az>` | `bgd-us-east-1-private-1a` |
| Security group | `bgd-us-east-1-<env>-<role>-sg` | `bgd-us-east-1-prod-task-sg` |
| ALB | `bgd-us-east-1-<env>-alb` | `bgd-us-east-1-prod-alb` |
| Target group | `bgd-us-east-1-<env>-<service>-<colour>` | `bgd-us-east-1-prod-api-blue` |
| ECS cluster | `bgd-us-east-1-<env>-cluster` | `bgd-us-east-1-prod-cluster` |
| ECS service | `bgd-us-east-1-<env>-<service>` | `bgd-us-east-1-prod-api` |
| DynamoDB table | `bgd-us-east-1-<env>-<entity>` | `bgd-us-east-1-prod-transactions` |
| Lambda function | `bgd-us-east-1-<env>-<purpose>` | `bgd-us-east-1-prod-post-test-hook` |
| IAM role | `bgd-us-east-1-<env>-<function>-role` | `bgd-us-east-1-prod-task-exec-role` |
| SNS topic | `bgd-us-east-1-<purpose>` | `bgd-us-east-1-alerts` |
| CodePipeline | `bgd-us-east-1-<purpose>-pipeline` | `bgd-us-east-1-infra-pipeline` |
| CodeBuild project | `bgd-us-east-1-<purpose>-build` | `bgd-us-east-1-app-build` |
| CloudWatch log group | `/bgd/us-east-1/<env>/<service>` | `/bgd/us-east-1/prod/api` |
| CloudWatch alarm | `bgd-us-east-1-<env>-<metric>` | `bgd-us-east-1-prod-5xx-rate` |

### The one deliberate deviation

**CloudWatch log groups use slashes, not hyphens.** Log group names are hierarchical by AWS convention (`/aws/ecs/…`, `/aws/lambda/…`), and the console builds its navigation tree from the slash structure. Using hyphens would produce one flat list of unrelated groups. The segments and their order are unchanged — only the separator differs.

---

## 4. Constraints that bite at apply time

These are silent or cryptic failures, so they are recorded rather than rediscovered:

| Constraint | Affects | Consequence |
|---|---|---|
| **32-character limit, no underscores** | ALB, target groups | Apply fails. Drove the choice of `bgd` in §1. |
| **Globally unique across all AWS accounts** | S3 buckets | `bgd-us-east-1-tfstate` is short and generic enough to already be taken by a stranger. Every bucket appends the account ID `590184028094`. |
| **Immutable after creation** | Target group names | A rename forces replacement. During blue/green that means downtime. |
| **Lowercase only, 2–63 chars** | S3, ECR | Apply fails on capitals. |
| **IAM roles are global, not regional** | IAM | Including the region is harmless and becomes useful if a second region is ever added. |
| **Log group names are case-sensitive** | CloudWatch | A mismatched case creates a second, silently empty group. |

---

## 5. Tagging

Four tags on every resource that supports tagging:

| Tag key | Value | Purpose |
|---|---|---|
| `environment` | `shared` \| `staging` \| `prod` | Cost allocation and filtering |
| `projectName` | `bgd` | Separates this project from anything else in the account |
| `region` | `us-east-1` | Cross-region cost queries; explicit rather than inferred |
| `owner` | `carreque45@gmail.com` | Who to contact; who pays |

`shared` covers the `foundation` and `network` layers, which are not environments but are used by both. The layer itself is recoverable from the resource name and from which state file owns the resource, so it does not need a tag of its own.

**Tag keys are case-sensitive.** `environment` and `Environment` are two different tags, and a mixture silently splits every cost report in two. The spellings above are the only correct ones.

### Applied through `default_tags`

Tags are set once on the provider, not repeated on every resource. This is what makes the convention hold rather than merely be documented:

```hcl
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      environment = var.environment   # shared | staging | prod
      projectName = var.project_name  # bgd
      region      = var.region        # us-east-1
      owner       = var.owner         # carreque45@gmail.com
    }
  }
}
```

A resource-level `tags` block merges with these, and on key collision the resource-level value wins. Use that only to add tags, never to override the four above.

> **Amended in Phase 4 (2026-08-26).** One bounded exception: **resources that
> incur no cost may override `environment`.** The rule above exists to stop a
> single cost line being split across two spellings of a key — a reason that
> does not apply to something that generates no cost line at all. It is used by
> the four per-environment security groups in `network`, which are created by a
> `shared` layer but belong to `staging` and `prod`. Anything billable still
> takes `environment` from the provider's `default_tags` and nowhere else.

### Two gaps `default_tags` does not cover

1. **ECS tasks do not inherit them.** The service must set `propagate_tags = "SERVICE"` (or `"TASK_DEFINITION"`), otherwise running tasks appear untagged and Fargate cost — the largest line item after the ALBs and NAT — cannot be attributed.
2. **Some resource types accept no tags at all**, and a few accept them only at creation. Where a resource cannot be tagged, its name is the only attribution available, which is a further reason the naming pattern is mandatory rather than advisory.

---

## 6. When the tags actually take effect

Tagging a resource is not the same as being able to query its cost. Three separate
things must all be true, and two of them are easy to miss.

### 6.1 The tags must reach the resource

`default_tags` covers most of it. ECS **tasks** are the exception — they inherit
nothing unless the service says so:

```hcl
resource "aws_ecs_service" "api" {
  propagate_tags = "SERVICE"
  # ...
}
```

`propagate_tags` is `optional` and **not `computed`** in the provider schema. That
distinction matters: a computed attribute would adopt whatever the API chose, but a
non-computed optional means omitting the line sends nothing and the ECS default —
no propagation — applies. There is no warning and no drift. `terraform plan` stays
clean while every running task is untagged.

`SERVICE` rather than `TASK_DEFINITION`, because task definitions are revised on
every image push by the app pipeline, making their tags the less reliable source;
and because `environment` describes where a service runs, not the image it runs.

### 6.2 The tag keys must be activated for cost allocation

**This is a manual console action, and it is not retroactive.**

User-defined tags do nothing in Cost Explorer until they are activated under
**Billing → Cost allocation tags**. Three consequences follow:

1. A key only becomes activatable *after* AWS has observed it on a real resource,
   so it cannot be done in advance.
2. Cost recorded before activation stays permanently unattributed. There is no
   backfill.
3. Terraform cannot do it. No provider resource covers it.

### 6.3 Timeline

| When | Action | Why then |
|---|---|---|
| Phase 3 | Activate `environment`, `projectName`, `region`, `owner` under Billing → Cost allocation tags | The first tagged resources exist, which is the earliest the keys can be activated — and every day of delay is permanently unattributable spend |
| Phases 5 and 6 | Set `propagate_tags = "SERVICE"` on both ECS services | The services are created here. Fargate is the largest cost line after the ALBs and NAT, and it is attributed at the task level |

Phase 3 is the one with a deadline attached, because that is when the
non-retroactive window opens. It is also the phase that already carries the
CodeConnections authorisation, so both manual steps belong in the same runbook.

> **Amended in Phase 5 (2026-08-28).** The Phase 5 half of the row above is
> done: `aws_ecs_service.api.propagate_tags = "SERVICE"` in
> `infra/environments/staging/ecs.tf`, asserted by
> `tests/compute.tftest.hcl`'s `the_service_runs_private_tasks_with_attributable_tags`
> run. `propagate_tags` is `optional` and **not `computed`**, so `terraform
> plan` cannot confirm it landed on a running task — only the AWS CLI can, and
> this document previously stated the requirement without saying how to
> confirm it. The command, from [the Phase 5
> runbook](./runbooks/phase-05-staging.md)'s tag-verification step:
>
> ```bash
> aws ecs list-tasks --cluster bgd-us-east-1-staging-cluster \
>   --query 'taskArns[0]' --output text
> aws ecs describe-tasks --cluster bgd-us-east-1-staging-cluster \
>   --tasks <arn> --include TAGS --query 'tasks[0].tags'
> ```
>
> Expected: all four convention tags, with `environment = staging`. Phase 6
> repeats this against its own cluster and service names.

---

## 7. Worked example

The production API service, named and tagged end to end:

```
ALB              bgd-us-east-1-prod-alb
Target groups    bgd-us-east-1-prod-api-blue
                 bgd-us-east-1-prod-api-green
ECS cluster      bgd-us-east-1-prod-cluster
ECS service      bgd-us-east-1-prod-api
Task exec role   bgd-us-east-1-prod-task-exec-role
Log group        /bgd/us-east-1/prod/api
DynamoDB         bgd-us-east-1-prod-transactions
Alarm            bgd-us-east-1-prod-5xx-rate

tags on all of the above:
  environment = prod
  projectName = bgd
  region      = us-east-1
  owner       = carreque45@gmail.com
```
