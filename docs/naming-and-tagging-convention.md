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

> **Amended in Phase 8 (2026-08-30).** A reading this section did not
> anticipate, recorded so a later reviewer does not "fix" four correct names.
>
> The application pipeline's CodeBuild projects, IAM roles and log groups are
> **project-wide resources** — they live in `infra/foundation`, whose
> `environment` tag is `shared`, and there is exactly one of each. By the rule
> above they take no `<env>` segment. But four of them contain the word
> `staging` or `prod`:
>
> ```
> bgd-us-east-1-app-deploy-staging-build     (CodeBuild project)
> bgd-us-east-1-app-deploy-staging-role      (IAM role)
> bgd-us-east-1-app-plan-prod-role           (IAM role)
> /bgd/us-east-1/shared/app-deploy-staging   (log group)
> ```
>
> **In these names, `staging` and `prod` are part of the *purpose* — which
> environment the build acts on — not the `<env>` segment.** The distinction is
> not pedantic: the `<env>` segment answers "which environment owns this
> resource", and the answer for all four is *neither, they are shared*. The
> resource segment answers "what does it do", and the answer includes the
> environment it deploys to, because that is precisely what distinguishes it
> from the project beside it.
>
> The log group makes the difference visible, since it carries both: the
> `shared` in `/bgd/us-east-1/shared/…` is the environment segment, and the
> `staging` after it is not.
>
> The same reading applies to the two SSM parameters Phase 7 created —
> `/bgd/staging/image_tag` and `/bgd/prod/image_tag` — where the environment
> names *whose tag this is*, and the parameters themselves are owned by the
> shared layer.

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
| SSM parameter | `/bgd/<env>/<key>` | `/bgd/prod/image_tag` |

### The deliberate deviations

**CloudWatch log groups use slashes, not hyphens.** Log group names are hierarchical by AWS convention (`/aws/ecs/…`, `/aws/lambda/…`), and the console builds its navigation tree from the slash structure. Using hyphens would produce one flat list of unrelated groups. The segments and their order are unchanged — only the separator differs.

> **Amended in Phase 6 (2026-08-29).** There are now **two**, and the heading
> above said "the one" until this phase.
>
> **Lambda log groups are `/aws/lambda/<function-name>`, not
> `/bgd/us-east-1/<env>/<service>`.** So the three lifecycle hooks write to
> `/aws/lambda/bgd-us-east-1-prod-post-test-hook` rather than to
> `/bgd/us-east-1/prod/post-test-hook`.
>
> That prefix is what Lambda writes to unless a `logging_config` block redirects
> it, and every console path, every sample query and every AWS tool assumes it.
> Deviating would gain consistency in this document and lose it everywhere an
> operator actually looks — including in the runbook step that tails these
> groups while a production deployment is in flight, which is the worst possible
> moment to be hunting for a log group under a name only this repository uses.
>
> The **function name** still follows §1 exactly, which is where the convention
> earns its keep. Only the prefix Lambda owns is left alone. See
> `infra/modules/lambda/main.tf`.

> **Amended in Phase 7 (2026-08-29).** There are now **three**.
>
> **SSM parameters use slashes, and they carry the environment where the log
> groups carry it too** — `/bgd/prod/image_tag`, not
> `bgd-us-east-1-prod-image-tag`.
>
> This is the log group argument applied to a different service, and it is the
> stronger case of the two. Parameter Store is hierarchical by design rather
> than by console convention: `GetParametersByPath` walks the tree, the console
> renders it as folders, and an IAM policy scopes access with
> `arn:aws:ssm:…:parameter/bgd/prod/*`. A hyphenated flat name would give up all
> three and gain nothing but a row that looks like the others.
>
> The region is omitted deliberately, unlike in the log group pattern. A
> parameter ARN already contains its region, and a parameter is not addressable
> from another one — so the segment would be noise in a path that four different
> tools have to match against.
>
> The two parameters are `/bgd/staging/image_tag` and `/bgd/prod/image_tag`. See
> `infra/foundation/ssm.tf` and the Phase 7 plan's D8.
>
> §2's rule is what puts no `<env>` segment in `bgd-us-east-1-infra-pipeline`,
> `bgd-us-east-1-infra-plan-build` or `bgd-us-east-1-infra-apply-role`: the
> pipeline deploys all four layers and exists once for the whole project, so
> there is nothing to disambiguate. **Confirmed rather than assumed**, because
> the alternative reading — one pipeline per environment — is a shape this
> project deliberately does not have.

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

> **Amended in Phase 6 (2026-08-29).** The Phase 6 half of the row is now done
> too: `aws_ecs_service.api.propagate_tags = "SERVICE"` in
> `infra/environments/prod/ecs.tf`, asserted by the same-named run in
> `infra/environments/prod/tests/compute.tftest.hcl`. **Both halves of the
> Phases 5 and 6 row are complete in code; neither is confirmed on a running
> task until the runbooks are executed**, for the reason the Phase 5 amendment
> gives — `propagate_tags` is not `computed`, so no plan can show it landed.
>
> It matters more here than in staging: production runs **two** tasks rather
> than one, plus an entire green task set during every blue/green deployment.
> The command, against this layer's names:
>
> ```bash
> aws ecs list-tasks --cluster bgd-us-east-1-prod-cluster \
>   --query 'taskArns[0]' --output text
> aws ecs describe-tasks --cluster bgd-us-east-1-prod-cluster \
>   --tasks <arn> --include TAGS --query 'tasks[0].tags'
> ```
>
> Expected: all four convention tags, with `environment = prod`.

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
Task role        bgd-us-east-1-prod-task-role
Blue/green role  bgd-us-east-1-prod-bluegreen-role
Hook invoke role bgd-us-east-1-prod-hook-invoke-role
Hook exec roles  bgd-us-east-1-prod-pre-scale-hook-exec-role      (and two more)
Lambda functions bgd-us-east-1-prod-pre-scale-hook
                 bgd-us-east-1-prod-post-test-hook
                 bgd-us-east-1-prod-post-prod-hook
Log group        /bgd/us-east-1/prod/api
Hook log groups  /aws/lambda/bgd-us-east-1-prod-post-test-hook    (and two more)
DynamoDB         bgd-us-east-1-prod-accounts
                 bgd-us-east-1-prod-transactions
Alarms           bgd-us-east-1-prod-target-5xx
                 bgd-us-east-1-prod-p95-latency
                 bgd-us-east-1-prod-unhealthy-blue
                 bgd-us-east-1-prod-unhealthy-green

tags on all of the above:
  environment = prod
  projectName = bgd
  region      = us-east-1
  owner       = carreque45@gmail.com
```

> **Amended in Phase 6 (2026-08-29).** This example predated the layer and
> listed nine resources; the layer contains rather more. Brought up to what
> `infra/environments/prod` actually creates — the two extra IAM roles, the
> three hook functions and their execution roles, the test listener's rules, the
> second table, and four alarms rather than one.
>
> **Two names changed rather than being added.** The alarm example read
> `bgd-us-east-1-prod-5xx-rate`; the alarm that exists is
> `bgd-us-east-1-prod-target-5xx`, because it measures
> `HTTPCode_Target_5XX_Count` — 5xx the *application* returned — rather than a
> rate, and distinguishing it from ELB-generated 5xx is the point. And there are
> four alarms, not one, because `UnHealthyHostCount` has no LoadBalancer-only
> form and so takes one per colour.
>
> **The longest name in the whole project appears here:**
> `bgd-us-east-1-prod-api-green`, at 28 characters against the 32-character cap
> that §4 records and that §1 chose `bgd` to fit inside. Nothing needs
> truncating anywhere, with four characters to spare.

> **Amended in Phase 9 (2026-08-30).** The observability plane, added beside
> the production plane above rather than replacing it — it is a second,
> independent worked example, not a correction to the first.
>
> ```
> Lambda function      bgd-us-east-1-release-metrics
> Lambda exec role      bgd-us-east-1-release-metrics-exec-role
> Log group             /aws/lambda/bgd-us-east-1-release-metrics
> Event rules            bgd-us-east-1-pipeline-executions
>                        bgd-us-east-1-prod-deployments
> Watchdog alarm         bgd-us-east-1-release-metrics-errors
> Dashboard              bgd-us-east-1-release
>
> tags on all of the above:
>   environment = shared
>   projectName = bgd
>   region      = us-east-1
>   owner       = carreque45@gmail.com
> ```
>
> Every one of these carries `environment = shared`, the same tag the two
> pipelines and their build projects carry — this plane lives in `foundation`
> for the reason [the design research's §8
> amendment](./2026-08-04-blue-green-deployment-platform-design-research.md#8-observability-and-release-metrics)
> gives (a layer cycle, and the metric history outliving teardown), and
> `foundation` is the shared layer.
>
> **`prod` in `bgd-us-east-1-prod-deployments` names what the rule watches,
> not where the rule lives.** The rule itself is `shared` — it is a
> `foundation` resource, tagged and destroyed on `foundation`'s own lifecycle
> — and its name still carries `prod` because that is the production ECS
> service its event pattern matches. This is §2's amendment applied a second
> time: a resource's `environment` tag says what plane it belongs to, and a
> name segment can say something else entirely — here, what it is scoped to
> rather than where it runs.
