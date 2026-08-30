# Controlled Deployment Platform with Blue/Green Strategy — Research & Design

**Date:** 2026-08-04
**Status:** Design proposed, awaiting approval
**Target account:** Single AWS account, `us-east-1`
**Deliverable language:** English

---

## 0. Context

A fintech company maintains a business-critical internal application. Deployments are currently manual or semi-manual: documented steps, but prone to human error, environment drift, and unreliable recovery times. The goal is a deployment platform that builds, versions, deploys and validates a new version with materially lower risk — where operational stability matters as much as delivery speed.

This project is scoped as a **portfolio / learning project** on a **real AWS account with normal cost discipline**. That framing matters: it means we are free to deviate from the original requirement list wherever a technically better option exists, provided the deviation is documented and defensible.

### Original requirements

**Minimum:**
- Automated pipeline from code to deployment
- Reproducible build
- Versioned artifacts
- Stage / environment separation
- Controlled deployment strategy
- Rollback or reversion evidence

**Advanced extensions (all in scope for this project):**
- Manual approval before production
- Automated testing
- Infrastructure as code
- Full blue/green deployment
- Deployment failure alerting
- Release and stability metrics

**Named AWS services:** CodePipeline, CodeBuild, CodeDeploy, S3, ECS or EC2, IAM, CloudWatch, ECR

---

## 1. Research findings

Everything below was verified on 2026-08-04 rather than recalled, because several of these items changed recently enough to invalidate most published tutorials.

### 1.1 CodeCommit is closed to new customers

AWS stopped accepting new CodeCommit customers in **July 2024**. The "classic" all-AWS pipeline diagram that most tutorials still show is no longer buildable on a new account.

**Consequence:** the source stage must be GitHub or GitLab via **AWS CodeConnections** (formerly CodeStar Connections), or an S3 bucket. CodeConnections uses a GitHub App authorization model — org-level, revocable — rather than the older personal-access-token approach of the GitHub v1 action.

**Decision:** GitHub via CodeConnections. The GitHub App installation itself requires one manual click in the console; everything after that is automated.

### 1.2 ECS now performs blue/green natively, without CodeDeploy

- **July 2025** — Amazon ECS launched built-in blue/green deployments, operating directly within the ECS service with no CodeDeploy dependency.
- **October 2025** — canary and linear traffic-shifting strategies added.
- **May 2026** — feature parity reached with the traffic-shifting patterns that previously required CodeDeploy.
- **March 2026** — AWS updated its published guidance to recommend **ECS-native as the default choice for new deployments**.

CodeDeploy blue/green for ECS is **not deprecated**, but it is no longer the recommended path.

The two paths differ structurally, not just cosmetically:

| | CodeDeploy path (`CODE_DEPLOY` controller) | Native path (`ECS` controller, `BLUE_GREEN` strategy) |
|---|---|---|
| Owner of the workflow | CodeDeploy | The ECS deployment controller |
| ECS's role | Participates via task sets | Owns the deployment, tracks service revisions internally |
| Validation hooks | `AppSpec` hooks | Lambda lifecycle hooks invoked by the ECS control plane |
| Traffic shift, bake, rollback | CodeDeploy deployment group config | ECS service definition |

**Decision:** **ECS-native**, with the rationale documented. This is a deliberate deviation from the requirement list's explicit mention of CodeDeploy, justified by AWS's own current guidance. Because this is a portfolio project rather than a graded rubric, the risk of an evaluator ticking "CodeDeploy: missing" does not apply.

### 1.3 Native blue/green brings lifecycle hooks and dark canary

Lifecycle hooks are **synchronous Lambda functions** that the ECS control plane invokes on your behalf at defined deployment stages. They can run test suites, check metrics, or gate on custom logic in any runtime.

Combined with a **separate ALB test listener**, this enables a **dark canary**: the green revision is validated with production-shaped traffic at **zero user impact** before any real traffic shifts. This is a materially stronger "controlled release" story than a plain target-group swap, and it is the single highest-value part of this design.

### 1.4 Terraform supports the native path

`aws_ecs_service` gained `deployment_configuration { strategy = "BLUE_GREEN" }` and lifecycle hooks in **AWS provider 6.4.0**, released 2025-07-17. Blue/green also requires `load_balancer.advanced_configuration`.

**Consequence:** pin the provider to `>= 6.4`. Local Terraform 1.15.7 is fine.

> **Amended in Phase 0 (2026-08-04).** The paragraph above originally described
> `lifecycle_hook` as a block alongside `deployment_configuration`, with camelCase
> attributes taken from the changelog. Inspecting the installed provider's schema
> (6.57.1) shows both are wrong. `lifecycle_hook` nests **inside**
> `deployment_configuration`, and attributes are snake_case:
>
> ```hcl
> deployment_configuration {
>   strategy             = "BLUE_GREEN"
>   bake_time_in_minutes = "5"        # string, not number
>
>   lifecycle_hook {
>     hook_target_arn  = "..."        # required
>     role_arn         = "..."        # required
>     lifecycle_stages = ["..."]      # required, list(string)
>     hook_details     = "..."        # optional
>   }
> }
> ```
>
> `canary_configuration` and `linear_configuration` are also present, confirming
> the October 2025 traffic-shifting strategies of §1.2 exist in the provider and
> not only in release notes. Full schema output in
> [the Phase 0 findings](./phases/phase0/2026-08-04-phase-00-verification-findings.md#a6--does-aws_ecs_service-expose-deployment_configuration-and-lifecycle_hook).

### 1.5 CodePipeline can trigger native blue/green directly

The CodePipeline **standard Amazon ECS deploy action** can drive an ECS native blue/green deployment. No CodeDeploy stage is required.

**Important limitation:** that action deploys **container image changes only** — not other service configuration changes. This directly shapes the pipeline design (see §5): task definition and service shape must be owned by Terraform, with only images flowing through the app pipeline.

> **Amended in Phase 8 (2026-08-30). The finding stands, and this project does
> not use it.**
>
> The heading is still true — the standard ECS deploy action *can* drive a
> native blue/green deployment, and no CodeDeploy stage is required. What was
> wrong was the next paragraph's confidence that the image-only limitation is
> the whole of the limitation, and that Terraform owning the service shape
> makes it a non-issue.
>
> **The limitation that actually bites is narrower and worse: the action can
> set an image URI and nothing else in the container definition.** It reads the
> service's current task definition revision, substitutes the image URI of each
> container named in `imagedefinitions.json`, and copies every other field —
> including `environment` — from that revision. There is no mechanism on this
> action to set an environment variable. (`CodeDeployToECS` takes a full
> `taskdef.json` and can; that is the CodeDeploy path, which §1.2 and the
> roadmap both discarded, and which this native strategy replaces.)
>
> Both of this project's task definitions carry
>
> ```hcl
> { name = "BGD_IMAGE_DIGEST", value = data.aws_ecr_image.api.image_digest }
> ```
>
> in that environment, because Phase 2 discovered that **an image cannot
> contain its own digest** — the digest is a function of the bytes, so a build
> argument carrying it changes it. The digest therefore has to be injected at
> deploy time, and the only writer of a task definition is Terraform.
>
> A revision produced by the ECS action would carry the **new image alongside
> the previous image's digest**, and nothing about the deployment would fail.
> `/version` — this design's own stated blue/green evidence surface (§4) —
> would report a digest that is not what is running. `scripts/smoke.sh`'s
> fourth assertion, the one that makes it a deployment check rather than a
> liveness check, would fail on every deploy. And the action registers a
> revision Terraform does not know about, so `aws_ecs_service.task_definition`
> drifts and the next `infra/**` merge reverts it, mid-deployment, on
> production.
>
> **So the app pipeline's deploy actions run Terraform**, applying the
> environment layer with `-var image_tag=<the tag just built>` and letting
> `data.aws_ecr_image` resolve that tag to a digest **once** — feeding both the
> container's `image` field and `BGD_IMAGE_DIGEST` from the same expression.
> There is one identifier for "what is running" and it cannot disagree with
> itself.
>
> **The property this section cares about is preserved, by a better mechanism
> than the one it named.** Only images flow through the app pipeline: the
> environment layers' Terraform is whatever is on `main`, and the single input
> the pipeline supplies is a tag. An `app/**` merge cannot change the service
> shape, because an `app/**` merge does not change `infra/`. See the Phase 8
> plan's §D2 and §F1.
>
> This is worth stating rather than quietly working around, because the finding
> above is *correct* and a later reader would otherwise reasonably ask why the
> project ignored its own research. It did not: the action is unusable here for
> a reason that has nothing to do with blue/green, and predates it.

### 1.6 Python 3.14 is viable — and preferable

The local environment runs Python 3.14.6. Verified against Docker Hub and PyPI:

- `python:3.14-slim` exists as an official image (also verified `python:3.13-slim`).
- **`pydantic-core 2.47.0`** — the only dependency with compiled (Rust) code, and therefore the only real risk — ships **cp314 manylinux wheels for x86_64 and aarch64**, plus musllinux and free-threaded `cp314t` variants. No source build required.
- `fastapi 0.141.1`, `uvicorn 0.52.1`, `boto3 1.43.63` are pure-Python `py3-none-any` and declare 3.14 support.

**Decision:** pin the container to `python:3.14-slim`, matching local 3.14.6. This is *better* than targeting 3.12: local-vs-container version drift is a real source of "works on my machine" defects, and for a **build reproducibility** requirement, identical versions is something concrete to point at. The container version governs regardless; local Python only runs tests and linting.

### 1.7 Route 53 find-or-create is possible without a flag

The singular `aws_route53_zone` **data source errors at plan time** if the zone does not exist, so the naive "look it up, else create it" does not work.

However, **`aws_route53_zones` (plural)** takes no arguments and returns a plain `ids` list — it does **not** error when nothing matches. Because data sources resolve during plan, `for_each` over its result receives known values.

```hcl
data "aws_route53_zones" "all" {}

data "aws_route53_zone" "candidates" {
  for_each = toset(data.aws_route53_zones.all.ids)
  zone_id  = each.value
}

locals {
  matched     = [for z in data.aws_route53_zone.candidates : z.zone_id
                 if z.name == "${var.domain_name}." && !z.private_zone]
  zone_exists = length(local.matched) > 0
}

resource "aws_route53_zone" "this" {
  count = local.zone_exists ? 0 : 1
  name  = var.domain_name
}

locals {
  zone_id = local.zone_exists ? local.matched[0] : aws_route53_zone.this[0].zone_id
}
```

> **Amended in Phase 3 (2026-08-24).** The filter above reads
> `!z.private_zone`; it must be **`z.private_zone != true`**. The `for_each`
> resolves **every** hosted zone in the account, so each zone's attributes have
> to survive the expression before the name filter can exclude it — and a null
> boolean makes the negation abort the entire plan with
> `argument must not be null`, on a line that looks correct. `!= true` is
> null-safe and identical for every non-null value. Found by the Phase 3 test
> suite before the first apply, not by an apply that failed.

**Caveat that must be handled explicitly:** on the *create* path, the new zone's NS records are not yet delegated at the registrar, so `aws_acm_certificate_validation` will wait for a validation CNAME that is not publicly resolvable — and hang until its 75-minute default timeout. The create path is therefore inherently a **two-phase apply**: create zone → delegate NS at registrar → apply again for the certificate. This is built in as a `wait_for_validation` flag rather than left to be discovered as a hang.

> **Amended in Phase 3 (2026-08-24).** The AWS provider now resolves to
> **6.61.0**; Phase 0 recorded 6.57.1. Both Phase 3 layers pin `~> 6.61` and
> commit `.terraform.lock.hcl` with hashes for `darwin_arm64`, `linux_arm64` and
> `linux_amd64`. The second and third matter because Phase 8's CodeBuild runs
> `ARM_CONTAINER` (Phase 2 §D1): a lock file generated only on this Mac fails
> there with a missing-hash error that reads as a corrupt lock rather than a
> missing platform.

### 1.8 Terraform state locking no longer needs DynamoDB

The S3 backend supports native lockfile-based locking (`use_lockfile = true`) as of Terraform 1.10+. Local Terraform is 1.15.7, so the separate DynamoDB lock table that older guides mandate is unnecessary.

---

## 2. Environment audit

Re-audited on the target machine in Phase 0. The table below is the verified state;
see the note underneath for what changed and why.

| Tool | Version | Notes |
|---|---|---|
| aws-cli | 2.35.4 | region `us-east-1`; profile `bootcamp-administrator-access` |
| docker | 28.3.2 | |
| terraform | 1.15.7 | supports `use_lockfile`; pinned in `.terraform-version` |
| python | 3.14.6 | matches target container; pinned in `.python-version` |
| git | 2.50.1 (Apple Git-155) | |
| make | 3.81 | macOS's GPLv2 build — no `.ONESHELL` or `.RECIPEPREFIX` |
| jq | 1.7.1 | required for provider schema inspection |
| sam / cdk | not installed | not required |

**Action required before any deployment:** SSO tokens expire. Run `aws sso login --profile bootcamp-administrator-access`, or `make verify-aws`, which reports the session state and prints that command when it has lapsed.

> **Amended in Phase 0 (2026-08-04).** The original table was captured on a
> different machine — the `git 2.39.1.windows.1` entry gives it away — and
> disagreed with the target machine on every row. Two decisions rested on it:
> §1.8's "no DynamoDB lock table" needs Terraform ≥ 1.10 (1.5.7 was installed),
> and §1.6's local-matches-container argument needs Python 3.14 (3.12.3 was
> resolving). Both were remediated rather than amended around, so §1.6 and §1.8
> stand as written. `node` is dropped from the table: no part of this project
> uses it.



---

## 3. Decisions

| Question | Decision |
|---|---|
| Project framing | Portfolio / learning project — free to deviate where justified |
| AWS constraints | Real account, normal cost discipline |
| Blue/green mechanism | **ECS-native**, deviation from spec documented |
| Deliverable language | English |
| Application | Purpose-built fintech-flavoured API |
| Stack | Python 3.14 + FastAPI + DynamoDB on-demand |
| Environments | **staging + prod, one ALB each** |
| Networking | Private subnets, **one shared NAT Gateway** |
| IaC | Terraform |
| IaC delivery | **Two pipelines** — infra and app, separate |
| Source | GitHub monorepo via CodeConnections |
| Region / accounts | Single account, `us-east-1` |
| TLS | Own domain, Route 53 + ACM |
| DNS model | Terraform **find-or-create** hosted zone |
| Alerts | SNS → email (`carreque45@gmail.com`) |
| Extensions | All four: manual approval, layered tests, failure alerting, release metrics |

### 3.1 Why NAT and not VPC endpoints

This was the main cost lever and deserves its reasoning recorded, because the intuitive answer is wrong.

The frequently-quoted "~$22/month for VPC endpoints" figure only holds in **a single AZ**. This design requires two AZs — the ALB mandates two subnets, and blue/green confined to one AZ is not a credible availability story. Interface endpoints bill **per endpoint, per AZ**. ECR requires `ecr.api` *and* `ecr.dkr`, plus `logs` for CloudWatch: 3 × 2 AZs × $7.30 = **~$44/month**, plus $0.01/GB processed. One NAT Gateway is **~$33/month**. At the AZ count this design actually needs, the "cheaper" option is the more expensive one.

Three further reasons:

1. **No egress at all.** Endpoints-only means the application cannot reach any external API — a payment provider, an FX rate feed, a webhook callback, an error-reporting agent. For something framed as fintech this is a wall you hit immediately, fixable only by adding NAT back.
2. **It does not scale with the design.** Adding Secrets Manager, SSM, KMS or STS later costs another $7.30/AZ/month each. NAT absorbs new services at no marginal cost.
3. **The security gap is smaller than it appears, and we close most of it for free.** The **S3 gateway endpoint costs nothing**, and ECR stores image layers in S3 — so the bulk of image-pull traffic bypasses NAT data-processing charges entirely.

**Honest counterpoint, recorded deliberately:** a real regulated fintech typically runs **both** — interface endpoints for AWS-service traffic that must never traverse the internet, *and* NAT for genuine third-party egress. Choosing one here is a budget trade-off, not an oversight.

> **Amended in Phase 4 (2026-08-26).** A DynamoDB gateway endpoint was added
> alongside the S3 one — not in the original list above. This **strengthens**
> the third argument rather than revising it: free-endpoint coverage now
> spans the application's entire data path, not only the ECR layer pulls S3
> was covering. Every account read and every transaction write reaches
> DynamoDB without touching the NAT's data-processing meter at all.

---

## 4. Application design

FastAPI on `python:3.14-slim` pinned **by digest**, multi-stage build, non-root user.

| Endpoint | Purpose |
|---|---|
| `/health` | ALB target-group health check — liveness only |
| `/ready` | Dependency readiness (DynamoDB reachable) |
| `/version` | Build number, git SHA, image digest |
| `/api/accounts` | Account listing / lookup |
| `/api/transactions` | The "critical internal operations" surface |

Backed by DynamoDB on-demand tables, one set per environment.

`/version` is load-bearing. During a blue/green shift it can be curled against the production listener and the test listener simultaneously, returning two different SHAs — that is the direct, visual proof of which colour is serving whom.

### 4.1 Build reproducibility

Listed as a minimum requirement, so it gets real treatment rather than "we run `docker build`":

- Base image pinned by **SHA256 digest**, not tag
- `requirements.txt` compiled with `pip-compile --generate-hashes`, installed with `pip install --require-hashes`
- Images tagged `<major>.<minor>.<codebuild-build-number>-<git-sha>` — **never `latest`**
- ECR repository with **immutable tags** and scan-on-push
- Deployments reference the image **digest**, not the tag
- SBOM generated per build (syft), stored as a versioned artifact

> **Amended in Phase 2 (2026-08-12).** Built and measured; see
> [the Phase 2 verification record](./phases/phase2/2026-08-12-local-verification.md).
>
> - The base is **`python:3.14.6-slim`**, pinned by *index* digest and built for
>   **`linux/arm64`**. The exact patch version keeps the container, `app/.venv`
>   and CI on one interpreter; the index digest keeps the Dockerfile
>   architecture-neutral.
> - **Reproducibility is proved by digest comparison, not asserted.** Two clean
>   builds of a commit produce the same manifest digest. Three things are each
>   necessary, and the first is not obvious: the default buildx driver **accepts
>   `rewrite-timestamp` and ignores it**, so a `docker-container` driver and the
>   OCI exporter are required; `SOURCE_DATE_EPOCH` and the image's `built_at`
>   both derive from the commit rather than the clock; and bytecode is compiled
>   with PEP 552 hash-based invalidation, because a default `.pyc` header embeds
>   the source mtime.
> - `rewrite-timestamp` applies **`min(mtime, SOURCE_DATE_EPOCH)`** — it
>   normalises files newer than the commit and preserves ones older than it — so
>   the build normalises the application sources' timestamps itself rather than
>   relying on it. Without that, a fresh clone and a long-lived working copy
>   produce different digests from identical source.
> - The tag's build number is `CODEBUILD_BUILD_NUMBER` in the pipeline and **`0`
>   locally**, with a **`-dirty`** suffix on an unclean tree, so a local artifact
>   can never be mistaken for a pipeline one.
> - SBOM by **syft 1.51.0 from a digest-pinned container**, reading the **OCI
>   archive** rather than the Docker daemon — so no third-party image is given
>   the daemon socket, and the SBOM describes the artifact of record.
> - The image cannot carry its own digest, so `/version` reports `image_digest`
>   only when the deployer injects it: the **ECS task definition** in Phases 5
>   and 6.

### 4.2 Artifact versioning

- Version scheme: `MAJOR.MINOR.<CodeBuild build number>` plus git SHA
- ECR images immutable, with a lifecycle policy capping retained image count
- S3 artifact bucket with **versioning enabled** and a lifecycle rule, holding build outputs, test reports and SBOMs

---

## 5. Infrastructure

Single account, `us-east-1`, one VPC across 2 AZs.

- **Public subnets:** the two ALBs
- **Private subnets:** Fargate tasks
- **One NAT Gateway** (single AZ, shared by both environments) plus the free **S3 gateway endpoint**
- **Separate ALB per environment**
- **One ACM certificate** covering `api.<domain>` and `staging-api.<domain>`, HTTP→HTTPS redirect

**The production ALB has two listeners:** `:443` production and `:8443` **test**. The test listener is what makes dark canary possible.

> **Amended in Phase 0 (2026-08-04).** Two listeners are necessary but not
> sufficient. The provider's `load_balancer.advanced_configuration` requires
> `production_listener_rule` — a **listener rule** ARN, not a listener ARN — so
> each listener also needs an `aws_lb_listener_rule`, and a default listener
> action will not do. `test_listener_rule` is optional in the schema but is what
> the dark canary depends on, so it is mandatory in this design.

---

## 6. Pipelines

Two pipelines, both sourced from the same monorepo with path-based trigger filters.

**Infra pipeline** — triggers on `infra/**`:

```
Source → Validate (fmt, validate, tflint, checkov) → Plan → Manual approval (plan in message) → Apply
```

**App pipeline** — triggers on `app/**`:

```
Source → Build (unit tests, coverage, image, SBOM, push) → Deploy staging
       → Smoke tests vs staging → Manual approval → Deploy prod (blue/green)
```

This split is what makes the "image changes only" limitation of the CodePipeline ECS action (§1.5) a non-issue: task definition and service shape are owned by Terraform in the infra pipeline; only images flow through the app pipeline.

> **Amended in Phase 8 (2026-08-30).** The app pipeline as built, with the two
> differences from the sketch above marked:
>
> ```
> Source ─ CODEBUILD_CLONE_REF, because the build reads git
>   │
> Build ─ tests in python:3.14.6-slim, image, SBOM, push, publish
>   │       exports IMAGE_TAG and IMAGE_DIGEST
>   │
> DeployStaging ─ skipped unless APP_SCOPE matches ^(staging|all)$
>   ├─ 1. Deploy   terraform apply -auto-approve -var image_tag=…   ← Terraform, not
>   │              then record /bgd/staging/image_tag                  the ECS action
>   └─ 2. Smoke    scripts/smoke.sh staging, credentials: none      ← its own action,
>   │                                                                  its own role
> Prod ─ skipped unless APP_SCOPE == all
>   ├─ 1. Plan     terraform plan -out=pipeline.tfplan, exports PLAN_SUMMARY
>   ├─ 2. Approve  manual, showing that summary
>   └─ 3. Apply    terraform apply pipeline.tfplan  ← the saved plan, no -var
>                  then record /bgd/prod/image_tag  ← after the apply, never before
> ```
>
> **"Deploy staging" is not an ECS deploy action** — see §1.5's amendment for
> why it cannot be. Both deploy actions run Terraform, and the paragraph above
> stays true by mechanism rather than by the action's limitation.
>
> **Production is Plan → Approve → Apply**, matching the infra pipeline's stage
> shape, rather than one approval followed by a deploy. The approval then
> approves a specific change — this digest, this task definition revision —
> and the apply applies that saved plan rather than computing a new one.
>
> **Smoke is a separate action**, with its own project and a role that makes no
> AWS API call at all: it is handed the URL and the digest by the deploy action
> beside it. Folding it into the deploy would make "the apply failed" and "the
> deployment succeeded but the service is wrong" indistinguishable in the
> pipeline view.
>
> Staging has no approval, deliberately: its stated job is to be the gate, and a
> human gate in front of it would be a strange shape.
>
> Both pipelines' triggers watch their own buildspecs and scripts as well as
> their source directory — `pipelines/infra-*.yml` and `pipelines/app-*.yml`,
> never `pipelines/**` — because a change to a buildspec changes what every
> stage does, and a shared glob would fire both pipelines on one merge.

---

## 7. Blue/green and rollback

The production ECS service runs `deployment_configuration { strategy = "BLUE_GREEN" }` with two target groups and three Lambda **lifecycle hooks**:

| Hook stage | Responsibility |
|---|---|
| `PRE_SCALE_UP` | Pre-flight checks before green is provisioned |
| `POST_TEST_TRAFFIC_SHIFT` | Validate green through the `:8443` test listener. **Failure aborts with zero production traffic ever reaching the bad build.** |
| `POST_PRODUCTION_TRAFFIC_SHIFT` | Post-shift verification |

Followed by a **5-minute bake period** with CloudWatch alarms attached, triggering automatic rollback on breach. Alarms: ALB 5xx rate, target response time p95, unhealthy host count.

> **Amended in Phase 6 (2026-08-29).** This table says what each hook is *for*
> but not what it must **return**, and that is what someone implementing one
> comes here looking for.
>
> **The handler returns `{"hookStatus": "SUCCEEDED"}` on success and *raises* on
> failure.** It deliberately does not return a symmetric `"FAILED"` payload.
>
> The reason is that the contract could not be confirmed offline. The exact
> payload ECS expects back is **not in the Terraform provider schema** — it is a
> runtime API contract, not a resource attribute — and there is no local source
> of truth for it. The two possible mistakes are not symmetric:
>
> - If ECS reads a `hookStatus` field and the handler raises on failure, ECS
>   sees an invocation error. No plausible contract reads an invocation error as
>   success. **Safe.**
> - If ECS treats any successful invocation as a pass and the handler returns
>   `{"hookStatus": "FAILED"}`, **the bad build is promoted to production** —
>   the exact failure §7.1's first demonstration exists to prove cannot happen.
>
> So the handler is built to be correct under either contract, choosing the
> failure mode that rejects rather than promotes. The runbook's step 9 reads the
> hook's CloudWatch log after the first real deployment and records what ECS
> actually did; if the real contract turns out narrower, the fix is an
> **addition**, never a rewrite into a symmetric return.
>
> A related note on the alarm count: this section names three signals but the
> layer creates **four** alarms. `UnHealthyHostCount` has no LoadBalancer-only
> form — CloudWatch publishes it per target group — so it takes one alarm per
> colour, both listed in `alarm_names`.

### 7.1 Rollback evidence — three distinct demonstrations

1. **Hook rejection** — the bad build never receives production traffic
2. **Alarm-triggered rollback during bake** — 5xx rate breaches, ECS reverts automatically
3. **Manual rollback** — redeploy the previous image digest

Each captured with screenshots and CloudWatch logs under `/docs/evidence/`.

These use a **genuinely broken commit** on a dedicated branch, not a simulated failure toggle. The evidence is only worth something if the failure is real.

---

## 8. Observability and release metrics

EventBridge rules on ECS deployment state changes and CodePipeline execution state changes feed a Lambda that writes custom CloudWatch metrics under a `ReleaseMetrics` namespace:

- Deployment frequency
- Lead time (commit → production)
- Change failure rate
- MTTR

Surfaced on a single CloudWatch dashboard. SNS → email notifications on pipeline failure, deployment failure, and rollback.

> **Amended in Phase 9 (2026-08-30).** Built as: two EventBridge rules feeding
> one Lambda that decides what is alert-worthy, writing six metric names under
> `ReleaseMetrics`, all argued in [the Phase 9
> plan](./phases/phase9/2026-08-30-phase-09-implementation-plan.md)'s §0.1.
>
> - **The six metric names are `DeploymentSucceeded`, `DeploymentFailed`,
>   `DeploymentRolledBack`, `LeadTimeSeconds`, `RecoveryTimeSeconds` and
>   `PipelineFailed`** — not the four named above. **Change failure rate and
>   deployment frequency are deliberately not among them.** Both are ratios
>   over a time window — `100 * failed / (failed + succeeded)` and
>   `SUM(succeeded)` — and a ratio stored as its own metric can only ever
>   describe the window its writer chose, never the window whoever is looking
>   at the dashboard just dragged to. Both are computed as CloudWatch metric
>   math on the dashboard instead, from the stored counts, and recompute for
>   whatever range is selected (D5).
> - **Two EventBridge rules, one filtering narrowly and one barely at all.**
>   The CodePipeline rule matches on the two pipelines' exact names and the
>   closed set `{SUCCEEDED, FAILED}` — CodePipeline's execution states are a
>   documented, finite vocabulary, so there is nothing to leave room for. The
>   ECS rule matches only `source`, `detail-type` and the production service's
>   exact ARN; it deliberately does not constrain `detail.eventName` at all,
>   because which names ECS emits for a *blue/green* deployment — and
>   specifically what an alarm-triggered rollback produces — is a runtime
>   contract with no offline source of truth. Guessing that vocabulary and
>   filtering on it wrong would make the rollback this project exists to
>   demonstrate produce no metric and no email while the rule still looks
>   correct in the console; filtering on nothing costs one invocation and one
>   log line for a name the handler does not recognize, and is how the real
>   vocabulary gets discovered (D4).
> - **Lead time is commit-to-production where the API allows it, with a
>   stated fallback.** The application pipeline's own execution reaching
>   `SUCCEEDED` is the moment a change is live, so the collector reads that
>   execution's `artifactRevisions[].created` — the source commit's timestamp
>   — for a genuine commit-to-production number. Whether CodePipeline
>   populates that field for a CodeConnections source cannot be confirmed
>   without a real pipeline run, so the handler falls back to the execution's
>   own start time (merge-to-production) when it is absent, and logs
>   `lead_time_basis=commit` or `=merge` on every emission rather than staying
>   silent about which one a given datapoint means (D6, F4).
> - **The collector is the alerting decision point, not EventBridge.** A rule
>   with an `input_transformer` targeting SNS directly would need no Lambda,
>   and was rejected because "what deserves an email" would then live in a
>   template string inside a Terraform resource, where nothing can test it.
>   Routed through the collector instead, that decision is ordinary Python
>   under a pytest suite (D3).

### 8.1 IAM

Least-privilege roles, separated by function: CodeBuild, CodePipeline, ECS task execution, ECS task, lifecycle Lambda, and the **ECS blue/green controller** each get their own role rather than sharing a permissive one.

> **Amended in Phase 0 (2026-08-04).** The sixth role was missing from the
> original list of five. `load_balancer.advanced_configuration.role_arn` is a
> **required** attribute — it is the role the ECS deployment controller assumes to
> rewrite ALB listener rules during a traffic shift. Without it the production
> service cannot be created at all.

> **Amended in Phase 6 (2026-08-29).** There is a **seventh**, and Phase 0's
> amendment did not find it because it was reading the attribute that had gone
> missing rather than the whole schema.
> `deployment_configuration.lifecycle_hook.role_arn` is a separately **required**
> slot: the role ECS assumes to invoke the three lifecycle hook functions.
>
> It is not the sixth role under another name. One needs
> `elasticloadbalancing` permissions on this ALB's listener rules; the other
> needs `lambda:InvokeFunction` on exactly three functions. This section's own
> stated premise is "least-privilege roles, separated by function", and merging
> them would give the rule-rewriter permission to invoke arbitrary Lambdas and
> the invoker permission to rewrite production routing. `infra/environments/prod`
> creates both, and asserts in a test that they are different roles so a later
> simplification has to argue with it.
>
> One further note on the blue/green controller, which is the one place in this
> project where the AWS-**managed** policy is the stricter choice rather than
> the lazier one. The action set ECS uses to rewrite listener rules mid-shift is
> not in the provider schema and cannot be read offline; a hand-rolled policy
> that is slightly too narrow does not fail at apply, it fails halfway through a
> production traffic shift, in the window where neither colour cleanly owns the
> listener. So that role attaches
> `AmazonECSInfrastructureRolePolicyForLoadBalancers`. Every other role in the
> project is still hand-written. See the Phase 6 plan's D5.

> **Amended in Phase 7 (2026-08-29).** The single **CodeBuild** role above is
> three: `infra-validate`, `infra-plan` and `infra-apply`.
>
> The forcing fact is that a build's permissions come from `service_role` on
> `aws_codebuild_project`, which is a property of the *project*.
> `action.role_arn` on a CodePipeline action is a different thing — the role
> CodePipeline assumes to *invoke* the action, whose documented use is
> cross-account actions — and it cannot substitute. `EnvironmentVariables` can
> be overridden per action; the service role cannot. So three roles that differ
> in what a build may do means three projects, and one shared role would mean
> every infra build ran with the reach the widest of them needs.
>
> The split is what makes this section's stated premise true rather than
> aspirational. `infra-plan` attaches `ReadOnlyAccess` plus four narrow
> additions — the `*.tflock` lock file, both spellings of the CodeConnections
> read API, the two image-tag parameters and its own log group — because a plan
> reads the world and writes nothing but a lock, so least privilege costs
> nothing here and a compromised plan build cannot mutate the account.
> `infra-validate` is narrower still and makes **no AWS API call at all**: it
> runs `terraform validate` and `terraform test` with `-backend=false`, and
> tflint and checkov read files. A test asserts that its policy contains no
> action outside `logs:` and `s3:`, because that property erodes the first time
> someone adds a step needing "just one read" and nothing fails when they do.
>
> `infra-apply` attaches `AdministratorAccess`, and the reason is the same rule
> the Phase 6 amendment above applied to the blue/green controller, reaching an
> opposite-looking conclusion: **write the policy that is honest about the
> boundary, not the one that looks strict.** This role creates IAM roles in four
> layers, and a principal that can create a role and attach a policy to it can
> already grant itself anything — so a narrower policy would describe a boundary
> that does not exist, while failing at apply time in whichever layer it forgot.
> The control that stands between a merge and a production change is not this
> role: it is the manual approval on a plan a human read, and the fact that the
> apply applies that plan file rather than deciding again. See the Phase 7
> plan's D5, D6 and F3.
>
> With the CodePipeline role, this phase creates four. Design §8.1's list is
> therefore nine roles, not six.

> **Amended in Phase 8 (2026-08-30). Nine roles are fifteen.** The application
> pipeline adds six: `app-pipeline`, `app-image`, `app-deploy-staging`,
> `app-smoke`, `app-plan-prod` and `app-deploy-prod`.
>
> The forcing fact is Phase 7's, unchanged and applied a second time: a build's
> permissions come from `service_role` on the project, so five roles that differ
> in what a build may do means five projects. What is new here is that **two of
> the six are separated structurally rather than by policy**, and that is a
> different kind of claim from anything above.
>
> `app-deploy-staging` and `app-deploy-prod` both attach `AdministratorAccess`,
> for the reason the Phase 7 amendment above gives for `infra-apply`: each runs
> `terraform apply` on a layer that creates IAM roles, and a principal that can
> create a role and attach a policy to it can already grant itself anything.
> **A policy separation between two such roles would be fiction.** They are two
> roles anyway, because the separation that *is* real is which principal each
> stage's actions run as: the staging deploy action physically cannot act as the
> production one. That is the only boundary available given the paragraph above,
> and a test asserts the two ARNs differ so a later simplification has to argue
> with it.
>
> At the other end, `app-smoke` joins `infra-validate` as a role that makes **no
> AWS API call at all**. `scripts/smoke.sh` needs `curl` and `jq`; the URL and
> the digest it asserts on are handed to it as action-level environment
> variables by the deploy action beside it, precisely so it need not read
> Terraform state or describe a service. Its policy grants its log group and the
> artifact bucket, and a test asserts no action outside `logs:` and `s3:`
> appears in it — the same assertion, and the same erosion argument, as
> `infra-validate`'s.
>
> One consequence of `CODEBUILD_CLONE_REF` (see §1.5's amendment and the Phase 8
> plan's D8) shows up here: because the **build** performs the git clone rather
> than CodePipeline, four of these roles need `codeconnections:UseConnection` on
> the connection ARN, scoped to the one connection. `app-deploy-prod` does not,
> and that absence is asserted — it consumes the Plan action's output artifact,
> which is an ordinary S3 zip, and clones nothing.
>
> `app-smoke`'s clone grant lives in a **second policy resource** rather than
> beside its log-group and bucket statements. That is not tidiness: merging them
> would have meant relaxing the "nothing outside `logs:` and `s3:`" assertion to
> admit a `codeconnections:` prefix, and the next thing added under a relaxed
> assertion is the "just one read" the assertion exists to refuse. See the
> Phase 8 plan's D5, D6 and F13.

> **Amended in Phase 9 (2026-08-30). Fifteen roles stays fifteen.** Every
> phase since Phase 6 has added to this count, which makes a phase that does
> not the surprising case, worth recording rather than leaving implicit.
>
> The release metrics collector's execution role comes from
> `infra/modules/lambda`, the same module the three lifecycle hooks already
> use — one `aws_iam_role` per instantiation, scoped to writing that
> function's own log group and nothing else. The collector's extra
> permissions — `cloudwatch:PutMetricData` and `GetMetricData`, `sns:Publish`
> on the alert topic, `codepipeline:GetPipelineExecution` and
> `ListPipelineExecutions` on both pipelines — are a **second policy attached
> to that same module-created role**, not a role of its own. No new role,
> because there is nothing here for a second role to separate: the module
> already gives this function a role no other function shares.

---

## 9. Repository layout

Single GitHub monorepo:

```
/app          FastAPI service, Dockerfile, tests
/infra
  /bootstrap  S3 state backend (native locking via use_lockfile — no DynamoDB table)
  /modules    network, alb, ecs-service, pipeline, observability
  /envs       staging/, prod/
/pipelines    buildspecs
/lambdas      lifecycle hooks, metrics collector
/docs         design, ADRs, runbook, evidence/
```

---

## 10. Cost

**Estimated ~$105–135/month**, fully destroyable with `terraform destroy`.

| Item | Approx. monthly |
|---|---|
| 2 × ALB | $36 |
| NAT Gateway | $33 |
| Fargate (staging 1 task, prod 2 tasks, 0.25 vCPU / 0.5 GB) | $27 |
| ECR, DynamoDB on-demand, CloudWatch, Route 53, S3, public IPv4 | ~$15 |

> **Amended in Phase 5 (2026-08-28).** Nothing here is contradicted, so this
> amendment is small: staging's half of the combined `$27` Fargate line is one
> 0.25 vCPU / 0.5 GB task running on **ARM64** (Phase 2 builds `linux/arm64`
> only), and this table did not price ARM64 specifically. Graviton Fargate is
> cheaper than x86 at the same size, so the $27 figure is conservative for
> staging's share rather than wrong.

> **Amended in Phase 6 (2026-08-29).** The same correction for production's
> share, plus one line item this table does not have at all.
>
> Production's half of the `$27` Fargate line is **two** 0.25 vCPU / 0.5 GB
> tasks, also on **ARM64**, so the figure is conservative here for the same
> reason. During a blue/green deployment both colours run simultaneously, so
> production briefly costs four tasks rather than two — for eight to twelve
> minutes per deployment, which rounds to nothing monthly but is worth knowing
> before anyone deploys in a loop.
>
> **Three Lambda functions are not priced here.** They are invoked three times
> per deployment, run for seconds, and sit far inside the perpetual free tier —
> effectively $0, and named only so the absence reads as checked rather than
> forgotten. Phase 9's metrics collector joins them.
>
> Record the real figure from the runbook once production has run for a full
> billing period. Nothing in this table is contradicted.

---

## 11. Known risks and trade-offs

| Risk | Status |
|---|---|
| **Single NAT Gateway** — one AZ is a SPOF for egress | Deliberate cost trade-off, documented |
| ~~**ACM validation hangs** on the zone-create path until NS delegation~~ | **Retired in Phase 0.** The hosted zone already exists (`Z01311493LQ7UOIRHM1H9`, created by the Route 53 registrar) and its NS records, the registrar's published set and public DNS all agree. Terraform adopts it, `wait_for_validation` can be `true` on the first apply, and the two-phase apply never occurs. |
| ~~**Lambda may not offer a Python 3.14 managed runtime**~~ | **Retired in Phase 0.** `python3.14` is offered, and `python3.15` already exists. The hooks and metrics collector pin to 3.14, matching the container and local interpreter exactly. |
| **Domain expires 2026-12-18 with auto-renew disabled** | Found in Phase 0. Nothing before Phase 5 depends on it; from Phase 5 onward every environment's TLS and DNS does. Expiry would take both environments down and invalidate the captured evidence. Requires a decision: enable auto-renew, or diarise the renewal. |
| **Blue/green needs listener *rules*, and a sixth IAM role** | Found in Phase 0 by inspecting the provider schema; §5 and §8.1 amended. No workaround needed, but both are required attributes and would have failed at apply time in Phase 6. |
| **Staging deploys are rolling, not blue/green** | Deliberate — blue/green only on prod keeps cost sane; staging's job is to fail fast |
| **Deviation from the named service list** — ECS-native instead of CodeDeploy | Justified by AWS's March 2026 guidance; acceptable because this is a portfolio project, not a graded rubric |
| **CodePipeline ECS action deploys image changes only** | Mitigated by the two-pipeline split (§6) |
| **SSO token expired** | Run `aws sso login --profile bootcamp-administrator-access` before deploying |

---

## 12. Open inputs

Two values are still required before implementation. Neither affects the architecture.

1. **Domain name** — needed for the ACM certificate and Route 53 records
2. **GitHub username/org and repository name** — needed for the CodeConnections source stage (suggested repo name: `deployment-handled`)

---

## Sources

- [ECS Blue/Green Deployments No Longer Need CodeDeploy — DEV Community](https://dev.to/aws-builders/ecs-bluegreen-deployments-no-longer-need-codedeploy-16j2)
- [Choosing between Amazon ECS blue/green native or AWS CodeDeploy in AWS CDK — AWS DevOps Blog](https://aws.amazon.com/blogs/devops/choosing-between-amazon-ecs-blue-green-native-or-aws-codedeploy-in-aws-cdk)
- [Migrating from AWS CodeDeploy to Amazon ECS for blue/green deployments — AWS Containers Blog](https://aws.amazon.com/blogs/containers/migrating-from-aws-codedeploy-to-amazon-ecs-for-blue-green-deployments/)
- [Extending deployment pipelines with Amazon ECS blue/green deployments and lifecycle hooks — AWS Containers Blog](https://aws.amazon.com/blogs/containers/extending-deployment-pipelines-with-amazon-ecs-blue-green-deployments-and-lifecycle-hooks)
- [CodeDeploy blue/green deployments for Amazon ECS — AWS Docs](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-bluegreen.html)
- [Amazon ECS and CodeDeploy blue-green deploy action reference — AWS CodePipeline Docs](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-ECSbluegreen.html)
- [ECS Native Blue/Green is Here! With Strong Hooks and Dark Canary — DEV Community](https://dev.to/aws-builders/ecs-native-bluegreen-is-here-with-strong-hooks-and-dark-canary-8ff)
- [Introducing AWS CodeConnections, formerly known as AWS CodeStar Connections](https://aws.amazon.com/about-aws/whats-new/2024/03/aws-codeconnections-formerly-codestar-connections/)
- [Use third-party Git source repositories in AWS CodePipeline — AWS Prescriptive Guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/use-third-party-git-source-repositories-in-aws-codepipeline.html)
- [Post-CodeCommit EOL: CodePipeline linking to remote GitHub repos — GitHub Community Discussion](https://github.com/orgs/community/discussions/174185)
- [terraform-provider-aws issue #43431 — aws_ecs_service: Support deployment configuration strategy](https://github.com/hashicorp/terraform-provider-aws/issues/43431)
- [How to Create ECS Blue-Green Deployment in Terraform — OneUptime](https://oneuptime.com/blog/post/2026-02-23-how-to-create-ecs-blue-green-deployment-in-terraform/view)
- [aws_route53_zones data source — terraform-provider-aws](https://github.com/hashicorp/terraform-provider-aws/blob/main/website/docs/d/route53_zones.html.markdown)
- [aws-samples/ecs-blue-green-deployment-with-codedeploy](https://github.com/aws-samples/ecs-blue-green-deployment-with-codedeploy)
