# Implementation Phase Roadmap

**Date:** 2026-08-04
**Status:** Proposed, awaiting approval
**Companion document:** [`2026-08-04-blue-green-deployment-platform-design-research.md`](./2026-08-04-blue-green-deployment-platform-design-research.md)

This roadmap sequences the design into phases. A separate detailed plan, written after this document is approved, expands each phase into specific tasks.

---

## 0. Decisions taken since the design document

The design document left two open inputs and several sequencing questions unanswered. These are now settled.

| Question | Decision |
|---|---|
| Domain | `carloscloudengineer.com`, registered with the **Route 53 registrar**. Terraform uses the find-or-create pattern of §1.7 and honours the `wait_for_validation` flag. |
| GitHub repository | `carreque/bluegreenDeployment` — the repository this working copy already points at. The design document's suggested name `deployment-handled` is dropped. |
| AWS account | `bootcamp-administrator-access`, persistent. Long-lived resources are safe. |
| Terraform layering | **Five layers**, not the four originally sketched (see §1). |
| Image chicken-and-egg | Seed ECR with the **real application image**, built locally, before the first ECS apply. This forces app-before-infra ordering. |
| Build order | **Application first, then infrastructure.** AWS spend starts only once there is something to deploy. |
| Application depth | **Thin but real** — genuine DynamoDB reads and writes, validation and error handling; not a full ledger. |
| Infra pipeline shape | One pipeline, sequential stages, with a `DEPLOY_SCOPE` execution variable so a run can stop after `foundation`, `network` or `staging` without touching production. |
| Cost policy | **Destroy when idle.** Teardown and rebuild are first-class deliverables, driven by scripts plus a runbook. |
| Rollback evidence | Its own final phase. Claude writes an exact step-by-step demo runbook; **you execute it and capture the screenshots.** |
| Plan delivery | Roadmap first for review, then the detailed plan. **Nothing is committed automatically** — a commit is proposed at the end of each completed phase. |
| Branching | **One feature branch per phase**, landed on `main` by a GitHub pull request that you merge. Commits within a branch are preserved, not squashed (see §2). |

---

## 1. Why five layers instead of four

The four-layer split (bootstrap → platform → staging → prod) collides with the destroy-when-idle policy. The NAT Gateway is the single largest idle cost at ~$33/month (unverified — see §3's Phase 4 amendment, which puts it nearer $36-37) and it lives in the platform layer — but so do the hosted zone, the ACM certificate, the ECR images, the artifact bucket holding build history, and the CodeConnections link that requires a manual console click. Destroying platform to stop paying for NAT takes all of that with it.

Splitting platform into **foundation** (durable, effectively free, painful to recreate) and **network** (ephemeral, expensive) resolves the conflict.

```
infra/
  bootstrap/      S3 state backend, native lockfile locking   never destroyed
  foundation/     Route 53 zone, ACM cert, ECR, artifact       persistent   ~$1/mo
                  bucket, SNS, CodeConnections, both
                  pipelines, shared IAM roles
  network/        VPC, subnets, IGW, NAT, S3 gateway           ephemeral   ~$33/mo*
                  endpoint, security groups
  envs/staging/   ALB, ECS service (rolling), DynamoDB         ephemeral   ~$25/mo
  envs/prod/      ALB (:443 + :8443), ECS service              ephemeral   ~$40/mo
                  (BLUE_GREEN), lifecycle hooks, DynamoDB
```

\* Unverified — see §3's Phase 4 amendment: arithmetic against published rates, not a measurement, and probably nearer $36-37/mo once the NAT Gateway's in-use Elastic IP charge (billed since 1 February 2024) is counted.

**Teardown** destroys `prod` → `staging` → `network`, in that order. Idle cost falls to roughly $1/month. **Rebuild** applies `network` → `staging` → `prod`. The certificate is not re-issued, images are not lost, and the CodeConnections click is not repeated.

Layers are wired together with `terraform_remote_state` data sources reading the S3 backend.

A note on the pipelines living in `foundation`: the pipelines are created by a local `terraform apply`, and from then on the infra pipeline manages the layer that contains itself. This is intentional and normal, but it means a broken change to the pipeline definition must be repaired by a local apply. The detailed plan calls this out in the runbook.

---

## 2. Working agreement

**One feature branch per phase**, branched from `main`.

| Phase | Branch |
|---|---|
| 0 | `feat/Phase0_Scaffolding` |
| 1 | `feat/Phase1_Application` |
| 2 | `feat/reproducible_container_build` |
| 3 | `feat/Phase3_BootstrapFoundation` |
| 4 | `feat/Phase4_Network` |
| 5 | `feat/Phase5_Staging` |
| 6 | `feat/Phase6_ProdBlueGreen` |
| 7 | `feat/Phase7_InfraPipeline` |
| 8 | `feat/Phase8_AppPipeline` |
| 9 | `feat/Phase9_Observability` |
| 10 | `feat/Phase10_TeardownRebuild` |
| 11 | `feat/Phase11_EvidenceDocs` |

> Amended in Phase 0. The table originally read `phase-NN-kebab-case`; it was
> changed to match `feat/Phase0_Scaffolding`, the branch already in flight when
> this convention was settled.
>
> Amended in Phase 2, for the same reason: row 2 read
> `feat/Phase2_ContainerBuild`, and the branch already in flight was
> `feat/reproducible_container_build`.
>
> Phase 3 needed no amendment: `feat/Phase3_BootstrapFoundation` is the branch
> the table names and the branch that was used.

The cycle for each phase:

1. Branch from `main`.
2. Work the phase's tasks, committing as the work naturally divides — commits are **proposed for your approval, never made automatically**. Within a phase, test commits precede implementation commits where the work is test-driven.
3. Verify the phase's exit criteria and show you the evidence.
4. Push the branch and open a pull request whose description is the phase's exit criteria and how each was verified.
5. **You review and merge.** Merging is always your action.

Commits are **preserved on merge, not squashed**. In a portfolio project the history showing tests written before implementation is worth more than a tidy one-line-per-phase log.

### 2.1 Branching interacts with the pipelines

The pipelines trigger on pushes to `main` filtered by path, so from Phase 7 onward **merging a phase branch is what fires a deployment**. This is a feature, not a complication — it means every phase from 7 on is delivered through the platform being built, and the merge button becomes the release control.

Two consequences the detailed plan accounts for:

- Pull requests themselves do not trigger the pipelines; only the merge does. Pre-merge validation therefore runs locally via `make`, and the pipeline's own validate stage is the authoritative gate after merge.
- Phases 9, 10 and 11 touch `infra/` and `app/`, so merging them triggers real deployments to a live production environment. Each of those phases ends by confirming the post-merge pipeline run succeeded, not merely that the merge happened.

---

## 3. Phase roadmap

Twelve phases. Phases 0–2 cost nothing on AWS. Phase 3 starts minimal spend. Phase 4 onward is when the monthly estimate applies.

| # | Phase | Depends on | AWS cost from here |
|---|---|---|---|
| 0 | Prerequisites and repository scaffolding | — | $0 |
| 1 | Application (local, test-driven) | 0 | $0 |
| 2 | Reproducible container build | 1 | $0 |
| 3 | Terraform bootstrap and foundation | 0, 2 | ~$1/mo |
| 4 | Network layer | 3 | ~$34/mo |
| 5 | Staging environment | 4 | ~$59/mo |
| 6 | Production environment with native blue/green | 5 | ~$99/mo |
| 7 | Infrastructure pipeline | 6 | +CodeBuild/CodePipeline usage |
| 8 | Application pipeline | 7 | ~$105–135/mo total |
| 9 | Observability and release metrics | 8 | — |
| 10 | Teardown and rebuild automation | 9 | reduces idle cost to ~$1/mo |
| 11 | Rollback evidence and documentation | 10 | — |

### Phase 0 — Prerequisites and repository scaffolding

Establish the working environment and verify every assumption the design rests on before any of it is built on top.

Verification tasks, each of which could invalidate part of the design if the answer differs from what is assumed:

- `aws sso login --profile bootcamp-administrator-access`, then confirm account and region.
- **Does a hosted zone for `carloscloudengineer.com` already exist?** Route 53 domain registration normally creates one. If it does, Terraform adopts it and the two-phase apply never happens. If it does not, the create path applies and the registrar's name servers must be updated to match the new zone.
- **Which Python runtimes does AWS Lambda currently offer as managed runtimes?** The lifecycle hooks and metrics collector are Lambdas. The container targets Python 3.14, but Lambda may not offer a 3.14 managed runtime yet; if not, the Lambdas pin to the newest available and this divergence is documented rather than discovered later.
- Confirm the AWS Terraform provider ≥ 6.4 resolves and that `aws_ecs_service` exposes `deployment_configuration` and `lifecycle_hook`.
- Confirm the ECS-native blue/green attributes are present in the installed provider version, not just in the changelog.

Scaffolding: directory skeleton per §9 of the design (adjusted for five layers), `.gitignore`, `.editorconfig`, a `Makefile` as the single entry point for every local command, and a resource naming and tagging convention recorded in writing.

**Exit criteria:** every verification question above has a recorded answer; the repository skeleton exists; `make help` lists the intended commands.

### Phase 1 — Application (local, test-driven)

The FastAPI service, built test-first, running entirely locally against DynamoDB Local. No AWS account involvement.

- Domain layer for accounts and transactions, kept free of AWS specifics.
- A repository interface with a DynamoDB implementation and an in-memory fake, so unit tests never touch the network.
- Endpoints: `/health` (liveness only — no dependency checks, because the ALB health check must not fail when DynamoDB hiccups), `/ready` (DynamoDB reachability), `/version` (version, git SHA, image digest), `/api/accounts`, `/api/transactions`.
- Validation, structured error responses, structured JSON logging.
- `pytest` with coverage; `ruff` for lint and format.
- `requirements.txt` compiled by `pip-compile --generate-hashes`.
- `docker compose` for local development with DynamoDB Local.

**Exit criteria:** full test suite green locally; the service runs against DynamoDB Local and every endpoint returns correct responses.

### Phase 2 — Reproducible container build

Turn the application into an artifact that satisfies the build-reproducibility requirement (§4.1) in a way that can be pointed at, not merely asserted.

- Multi-stage `Dockerfile` on `python:3.14.6-slim` **pinned by SHA256 digest**, running as a non-root user.
- `pip install --require-hashes` against the compiled requirements.
- Version metadata injected at build time as build arguments and surfaced by `/version`.
- SBOM generated with syft.
- Local build, container smoke test, and a repeatability check that the same input produces the same image content.

> **Amended in Phase 2 (2026-08-12).** Three changes, each with a consequence a
> later phase inherits.
>
> - **`python:3.14.6-slim`, not `python:3.14-slim`.** The floating tag now
>   resolves to 3.14.7, which would put the container one patch ahead of
>   `.python-version` and of CI. The exact tag restores design §1.6's parity
>   claim; a patch upgrade becomes a deliberate commit moving both pins together.
> - **The image targets `linux/arm64` only.** It builds natively on the
>   development machine and runs on Graviton, which is cheaper. **Phases 5 and 6
>   must therefore set `runtime_platform { cpu_architecture = "ARM64" }` on both
>   task definitions** — an `X86_64` task definition cannot start this image —
>   and **Phase 8's CodeBuild project needs `ARM_CONTAINER` compute.**
> - **`/version` reports `image_digest` only when the deployer supplies it.** An
>   image cannot contain its own digest, since the digest is its hash, so
>   **Phases 5 and 6 must set `BGD_IMAGE_DIGEST` in the ECS task definition's
>   container environment.** Without it a live task reports `unknown`.
>
> The repeatability check is stronger than "the same image content": two clean
> builds produce the **same manifest digest**, the identifier ECR stores and ECS
> deploys against. That holds because every timestamp derives from the commit
> rather than the clock. It requires a `docker-container` buildx driver — the
> default driver accepts `rewrite-timestamp` and silently ignores it — so
> `scripts/build-image.sh` is the only supported build path.

**Exit criteria:** the image builds locally, the container serves all endpoints, `/version` reports the injected metadata, an SBOM is produced, two clean builds produce the same manifest digest, and the image does not run as root.

### Phase 3 — Terraform bootstrap and foundation

First AWS resources. Both applies are local — the pipelines that will later manage this do not exist yet.

- **bootstrap:** S3 state bucket with versioning, encryption, public access blocked, and `use_lockfile = true`. No DynamoDB lock table. Local state, gitignored, documented as trivially recreatable.
- **foundation:** hosted zone via find-or-create; ACM certificate for `api.carloscloudengineer.com` and `staging-api.carloscloudengineer.com` behind the `wait_for_validation` flag; ECR repositories with immutable tags, scan-on-push and a lifecycle policy; versioned artifact bucket with lifecycle rules; SNS topic with email subscription to `carreque45@gmail.com`; shared IAM roles.
- **CodeConnections:** created by Terraform in `PENDING` state, then authorised by one manual click in the console.
- **Cost allocation tags:** activate `environment`, `projectName`, `region` and `owner` under Billing → Cost allocation tags.

These are the **two irreducibly manual steps in the whole project**, and the Phase 3 runbook says so plainly rather than burying them in a list.

> **Amended in Phase 3 (2026-08-24).** There are **three**. The SNS email
> subscription is the third: `aws_sns_topic_subscription` with
> `protocol = "email"` is created `PendingConfirmation` and stays there until the
> recipient clicks the link AWS sends. Terraform reports the resource as created
> and `terraform plan` stays clean indefinitely, so an unconfirmed subscription
> is silent — its symptom is Phase 9's alerts never arriving, three phases later
> and looking like a bug in the alerting. The
> [Phase 3 runbook](./runbooks/phase-03-bootstrap-and-foundation.md) lists it as
> a step with its own verification command.
>
> **Also amended in Phase 3.** §1's layer diagram lists both pipelines and the
> shared IAM roles under `foundation`; this task list does not, and the task list
> is what was built. `foundation` still owns the pipelines — Phases 7 and 8 add
> files to this layer rather than creating a new one — and each of design §8.1's
> six IAM roles is created by the phase that creates the resource it acts on,
> because a role's policy cannot be scoped to resources that do not exist yet.

The second has a deadline the first does not. Tag activation is **not retroactive**: a key only becomes activatable once AWS has observed it on a real resource — so it cannot be done before this phase — and any cost recorded before activation stays permanently unattributed. Doing it late does not delay anything; it silently loses data. See [the naming and tagging convention](./naming-and-tagging-convention.md#6-when-the-tags-actually-take-effect).
- **Seed ECR** with the real image from Phase 2, so the ECS services in Phases 5 and 6 have something to run.

**Exit criteria:** state backend live and locking; certificate issued and validated; ECR holds the seeded image; the SNS email subscription is confirmed.

> **Amended in Phase 3 (2026-08-24).** The phase was delivered in two halves.
> Everything that can be built and proved without an AWS session was — both
> layers, their tests, the linting and the seed script, verified by
> `make tf-check` against mocked providers — and the applies that create the
> resources these four criteria describe were handed over as
> [a runbook](./runbooks/phase-03-bootstrap-and-foundation.md). **None of the
> four criteria is met by the branch alone.** The branch's own gate is
> `make tf-check`; the criteria above are met when the runbook is executed.

### Phase 4 — Network layer

- VPC across two availability zones; public subnets for the ALBs, private subnets for Fargate tasks.
- Internet gateway, one NAT Gateway shared by both environments, route tables.
- Free S3 gateway endpoint, so ECR layer pulls bypass NAT data-processing charges.
- Security groups: ALB-to-task and task-to-egress, least privilege.
- Outputs consumed by both environment layers via remote state.

A first-cut teardown script lands here, because this is the first layer that costs real money when idle. Phase 10 hardens it.

**Exit criteria:** `terraform apply` and `terraform destroy` both succeed cleanly; a task in a private subnet can reach the internet through NAT.

> **Amended in Phase 4 (2026-08-26).** The layer built more than this task
> list names, all decided and recorded in [the Phase 4
> plan](./phases/phase4/2026-08-26-phase-04-implementation-plan.md)'s §0.1:
>
> - **A DynamoDB gateway endpoint, alongside the S3 one** (D4). Not named
>   above or in design §3.1. Free, and DynamoDB is the application's entire
>   data path — without it, every read and write leaves through the NAT and
>   pays $0.045/GB for traffic that never needed to leave AWS.
> - **Four security groups, one ALB/task pair per environment, not one
>   shared pair** (D3). The naming convention's `<env>` segment wins over this
>   task list's "ALB-to-task and task-to-egress" phrasing, which reads as a
>   single pair. Staging and production tasks cannot reach each other, and
>   production's ALB group opens an extra `:8443` for Phase 6's blue/green
>   test listener that staging's does not.
> - **VPC flow logs**, `ALL` traffic at 7-day retention (D5). Not in the
>   original list; added because checkov fails a VPC with none of them
>   (`CKV2_AWS_11`), and because they are the tool that answers "why can this
>   task not reach that endpoint" — the likeliest failure mode of Phases 5
>   and 6.
> - **`network` takes no `terraform_remote_state` dependency on `foundation`**
>   (D2), unlike Phases 5 and 6. It rebuilds the four convention variables
>   itself rather than reading them, which keeps `make tf-check` fully
>   offline and keeps `terraform destroy` on this layer working even if
>   `foundation`'s state is unreadable.
> - **The cost figure needs confirming.** ~$34/month above was arithmetic,
>   not a measurement — no AWS session was available when the plan was
>   written, and since 1 February 2024 AWS also bills the NAT Gateway's
>   in-use Elastic IP (~$3.60/month on top of the ~$32.85/month gateway
>   rate). [The runbook](./runbooks/phase-04-network.md)'s step 8 confirms
>   the real number against the pricing API.
>
> **Neither exit criterion above is met by the branch alone.** The branch's
> own gate is `make tf-check`; both criteria are met when [the
> runbook](./runbooks/phase-04-network.md) is executed. See [the local
> verification record](./phases/phase4/2026-08-26-local-verification.md).

### Phase 5 — Staging environment

Deliberately the simpler of the two environments — rolling deployments, one task. Its job is to fail fast, not to demonstrate blue/green.

- ALB with an HTTPS listener and an HTTP→HTTPS redirect, one target group.
- DynamoDB on-demand tables for staging.
- ECS cluster, task definition, service with the rolling deployment controller, one task.
- **`runtime_platform { cpu_architecture = "ARM64" }`** on the task definition, and **`BGD_IMAGE_DIGEST`** in its container environment — both inherited from Phase 2, and both are silent failures if missed: the first fails at task start, the second leaves `/version` reporting `unknown` in a live environment.
- Separate task execution role and task role; CloudWatch log group with retention.
- Route 53 record for `staging-api.carloscloudengineer.com`.

**Exit criteria:** `https://staging-api.carloscloudengineer.com/health`, `/ready` and `/version` all respond correctly over TLS, serving the seeded image.

> **Amended in Phase 5 (2026-08-28).** The layer built more than this task
> list names, all decided and recorded in [the Phase 5
> plan](./phases/phase5/2026-08-28-phase-05-implementation-plan.md)'s §0.1:
>
> - **A deployment circuit breaker, with rollback** (D8). Not named above. A
>   task that never reaches a healthy state rolls staging back to the previous
>   task definition instead of retrying forever — the mechanism for the
>   roadmap's stated job of failing fast, and it gives Phase 8's pipeline a
>   meaningful staging gate with no new code of its own.
> - **`containerInsights` explicitly disabled, not omitted** (D7). Written as
>   `setting { name = "containerInsights", value = "disabled" }` rather than
>   left out, so the choice is visible in the code and the plan diff instead
>   of being an absence someone has to notice. Phase 9 owns observability and
>   turning this on now would bill per custom metric on the layer whose whole
>   point is being cheap to leave running.
> - **`scripts/smoke.sh`** (D4). A shell script, not a pytest suite and not
>   runbook prose, so Phase 8's CodeBuild runs the identical command used
>   locally without installing a Python virtualenv just to smoke-test a
>   service. It asserts more than "200 OK": `/version`'s `image_digest` must
>   equal the digest Terraform recorded, which is what makes it a deployment
>   check rather than a liveness check.
> - **The image pinned by digest, resolved from a tag through
>   `data.aws_ecr_image`** (D3). Not two hand-maintained variables that could
>   silently disagree — `var.image_tag` names a tag, the data source resolves
>   it to a digest, and the task definition and `BGD_IMAGE_DIGEST` both read
>   the same resolved value, so `/version` cannot report something that was
>   never deployed.
>
> **The exit criterion above is not met by the branch alone.** The branch's
> own gate is `make tf-check`; the criterion is met when [the
> runbook](./runbooks/phase-05-staging.md) is executed. Same note Phases 3 and
> 4 carry. See [the local verification
> record](./phases/phase5/2026-08-28-local-verification.md).
>
> §2's branch table needed no amendment: row 5 already reads
> `feat/Phase5_Staging`, and that is the branch used. Same as Phase 3's note.

### Phase 6 — Production environment with native blue/green

The technical centre of the project.

- ALB with a `:443` production listener and a `:8443` **test listener**, plus two target groups.
- ECS service with `deployment_configuration { strategy = "BLUE_GREEN" }` and the required `load_balancer.advanced_configuration`.
- **`runtime_platform { cpu_architecture = "ARM64" }`** and **`BGD_IMAGE_DIGEST`** on this task definition too (Phase 2). The second matters more here than in staging: `/version` is the blue/green evidence surface, and the image digest is what ECS actually deploys.
- Three lifecycle hook Lambdas: `PRE_SCALE_UP`, `POST_TEST_TRAFFIC_SHIFT` (the dark canary gate — this is where a bad build dies before any user sees it), and `POST_PRODUCTION_TRAFFIC_SHIFT`.
- Five-minute bake period with CloudWatch alarms attached for automatic rollback: ALB 5xx rate, target response time p95, unhealthy host count.
- Route 53 record for `api.carloscloudengineer.com`.

Blue/green is exercised here by hand via the AWS CLI, before any pipeline exists. Debugging a blue/green deployment through a pipeline you are simultaneously debugging is a bad trade.

**Exit criteria:** a manual CLI blue/green deployment completes; `/version` returns different SHAs on `:443` and `:8443` mid-deployment, which is the direct proof of which colour serves whom; a deliberately failing hook aborts the deployment with zero production traffic shifted.

> **Amended in Phase 6 (2026-08-29).** The layer built more than this task list
> names, all decided and recorded in [the Phase 6
> plan](./phases/phase6/2026-08-28-phase-06-implementation-plan.md)'s §0.1:
>
> - **The two DynamoDB tables** (D13). Missing from the task list above but
>   present in §1's layer diagram, which lists `DynamoDB` under `envs/prod/`.
>   The diagram is right and the task list is incomplete: the application cannot
>   serve `/ready`, let alone a transaction, without its tables — and `/ready`
>   is the check the dark canary's whole value rests on. They are prod's own,
>   not shared with staging.
> - **`desired_count = 2`** (D13). From design §10, which prices "Fargate
>   (staging 1 task, prod 2 tasks)"; the task list does not state it. Two tasks
>   across two availability zones is also the minimum that makes the
>   `UnHealthyHostCount` bake alarm mean "one task is sick" rather than being a
>   synonym for "the service is down".
> - **Design §8.1's six roles are seven** (D4). Phase 0 found a sixth,
>   `load_balancer.advanced_configuration.role_arn`; inspecting the same schema
>   for this phase turned up a seventh that neither document named,
>   `deployment_configuration.lifecycle_hook.role_arn`. They are not
>   interchangeable — one needs `elasticloadbalancing` on listener rules, the
>   other `lambda:InvokeFunction` on three functions — and merging them would
>   give the rule-rewriter permission to invoke arbitrary Lambdas. This layer
>   creates five of the seven.
> - **Four listed alarms are four actual alarms, but not the ones implied**
>   (D8, F3). The list above names three signals. `UnHealthyHostCount` has no
>   LoadBalancer-only form — CloudWatch publishes it per target group — so it
>   takes two alarms, one per colour. The other two carry the `LoadBalancer`
>   dimension only, because per-group scoping would trip on the *old* group's
>   errors as it drains, which is not a reason to roll back a promotion that
>   already happened.
> - **Four decisions the task list does not name.** No deployment circuit
>   breaker, deliberately — the bake with alarms is this environment's rollback
>   mechanism, and how the two would interact is not in the schema (Task 8).
>   `wait_for_steady_state = true` (D11), so an apply cannot report success over
>   a deployment that rolled back. No ALB access logs (D7) — Phase 5's D5
>   deferred that decision to this phase, and the answer is still no, because
>   they arrive on a five-minute lag, longer than the deployment they would
>   document. No `alarm_actions` (D9) — Phase 9 owns notification and attaches
>   to these same alarms.
> - **"Exercised by hand via the AWS CLI" means observed, not initiated**
>   (D10). Terraform owns the task definition and the service shape, so a CLI
>   `update-service --task-definition` would register drift the next apply
>   reverts, mid-deployment. What starts a deployment is changing `image_tag`
>   and running `make apply-prod`; what the CLI does is watch the stage
>   transitions and abort one by hand. Design §1.5's argument for why the
>   CodePipeline ECS action's image-only limitation is a non-issue rests on
>   that ownership.
>
> **None of the three exit criteria is met by the branch alone.** All three need
> a running service, and the Phase 6 session created no AWS resource (D1). They
> are met by [the runbook](./runbooks/phase-06-prod-blue-green.md) — steps 12,
> 13 and 14 respectively.
>
> §2's branch table row 6 reads `feat/Phase6_ProdBlueGreen`, which is the branch
> used. **No amendment needed there** — recorded explicitly, as Phases 3 and 5
> did, so the absence reads as checked rather than overlooked.

### Phase 7 — Infrastructure pipeline

- CodePipeline v2 sourced from `carreque/bluegreenDeployment` via CodeConnections, filtered to `infra/**` on `main`.
- Stages: Source → Validate (`fmt`, `validate`, `tflint`, `checkov`) → per-layer plan, manual approval and apply.
- A `DEPLOY_SCOPE` execution variable (`foundation` | `network` | `staging` | `all`) so a run stops where you want it to. Out-of-scope stages skip cleanly and the execution still finishes green — declining an approval would mark the run Failed and corrupt the change-failure-rate metric in Phase 9.
- The plan output is surfaced in the approval message, so approval is an informed decision rather than a reflex.
- Handover: from this point the infra pipeline manages `foundation`, `network` and both environment layers.

**Exit criteria:** a change to an environment layer flows through the pipeline and applies; a `DEPLOY_SCOPE=network` run demonstrably leaves production untouched.

> **Amended in Phase 7 (2026-08-29).** The phase built more than this task list
> names, all decided and recorded in [the Phase 7
> plan](./phases/phase7/2026-08-29-phase-07-implementation-plan.md)'s §0.1:
>
> - **Two SSM parameters and a change to `scripts/seed-ecr.sh`** (D8). Not in
>   the task list, and the task list cannot work without them: it assumes the
>   pipeline can plan every layer, and two of the four declare `image_tag` with
>   no default whose value lives in a gitignored `terraform.tfvars` (F7). A
>   CodeBuild workspace therefore has no value at all and
>   `terraform plan -input=false` fails before it authenticates to anything.
>   `foundation` gains `/bgd/staging/image_tag` and `/bgd/prod/image_tag`, each
>   with `ignore_changes = [value]`, and `seed-ecr.sh` writes the tag it pushed.
>   The side effect is the property that matters most: an `infra/**` merge
>   plans with the tag already recorded, so the infra pipeline is
>   **image-preserving by construction** rather than by convention — design
>   §1.5's separation enforced by mechanism.
> - **Three CodeBuild projects and four IAM roles**, where design §8.1 names one
>   CodeBuild role and one CodePipeline role (D5, D6, F3). `action.role_arn` on
>   a CodePipeline action is the role CodePipeline assumes to *invoke* the
>   action; a build's own permissions come from `service_role` on the project,
>   which cannot be overridden per action. Three roles that differ in what a
>   build may do therefore means three projects — and the split is the whole
>   reason the plan role can be genuinely `ReadOnlyAccess` while the apply role
>   is `AdministratorAccess`. Which *layer* a build works on is not a property
>   of the project: it arrives per action as `LAYER`, so eight actions share two
>   projects.
> - **`DEPLOY_SCOPE`'s four values are cumulative, and `all` means "through
>   prod"** (D3). The phrasing above already implies it; stated as a table so it
>   cannot be read the other way:
>
>   | `DEPLOY_SCOPE` | Foundation | Network | Staging | Prod |
>   |---|---|---|---|---|
>   | `foundation` | apply | skip | skip | skip |
>   | `network` | apply | apply | skip | skip |
>   | `staging` | apply | apply | apply | skip |
>   | `all` | apply | apply | apply | apply |
>
>   Cumulative rather than exclusive because the layers are ordered by
>   dependency: `staging` reads `network`'s outputs through remote state, and
>   applying staging against a network that was never applied is the failure the
>   ordering exists to prevent. An unrecognised value applies nothing, loudly.
> - **The scope is enforced twice** (D4), and the second gate is not redundancy
>   for its own sake. `before_entry`'s `VariableCheck` rule takes an untyped
>   `map(string)` configuration, so whether `MATCHES` is an accepted operator is
>   not in the provider schema and cannot be confirmed without an AWS session
>   (F2). The failure modes are asymmetric: a condition wrong in the direction
>   of *entering* a stage costs an unwanted approval when the script refuses,
>   and would have applied production if the script were absent. The condition
>   is the optimisation; the script is the guarantee.
> - **One stage per layer with three actions, not three stages per layer** (D2).
>   `before_entry` is a stage-level condition, so one condition skips a layer's
>   plan, its approval and its apply together, atomically. Six stages, not
>   fourteen.
> - **`LINUX_CONTAINER`, not `ARM_CONTAINER`** (D7) — and the reason is the
>   *opposite* of Phase 2's amendment, which requires `ARM_CONTAINER` for Phase
>   8's app build. `scripts/lint-infra.sh` runs digest-pinned tflint and checkov
>   containers, and those digests passing locally does not prove they have
>   `linux/arm64` variants: Docker Desktop emulates amd64 transparently and
>   CodeBuild does not. Both choices are right; the divergence should read as
>   deliberate.
> - **The trigger watches four path patterns, not one** (D12): `infra/**`,
>   `pipelines/**`, `scripts/pipeline-*.sh` and `scripts/install-terraform.sh`
>   — the pipeline's own executable content, because a change to a buildspec
>   changes what every stage does. `scripts/**` as a whole is deliberately
>   excluded: it also holds Phase 8's build scripts, and watching the directory
>   would run a four-approval infra deployment on an application change.
>   `DetectChanges` is `"false"` on the source action so change detection has
>   one mechanism rather than two (D13).
> - **`execution_mode = "QUEUED"`** (D11), not the V2 `SUPERSEDED` default,
>   which would cancel a run whose approval someone is part-way through reading
>   — or one mid-apply — when a second merge lands.
> - **Apply applies the saved plan file** (D9), and does not re-plan. Otherwise
>   the approval approves a description and the apply computes something else.
>
> **Neither exit criterion is met by the branch alone.** Both need a pipeline
> that exists and a run that happened, and the Phase 7 session created no AWS
> resource (D1). They are met by [the
> runbook](./runbooks/phase-07-infra-pipeline.md) — steps 6 and 7 respectively.
>
> §2's branch table row 7 reads `feat/Phase7_InfraPipeline`, which is the branch
> used. **No amendment needed there** — recorded explicitly, as Phases 3, 5 and
> 6 did, so the absence reads as checked rather than overlooked.

> **Amended again in Phase 8 (2026-08-30) — the trigger narrows.** Two of the
> four path patterns above matched files Phase 8 creates, and this is recorded
> in *both* phases' sections so a reader checking Phase 7's file against Phase
> 7's amendment finds the change accounted for.
>
> - `pipelines/**` matched `pipelines/app-build.yml`; `scripts/pipeline-*.sh`
>   matched `scripts/pipeline-app-build.sh` and `scripts/pipeline-deploy.sh`.
>   Left alone, **every application-buildspec edit would have started a
>   four-approval infrastructure deployment** alongside the application
>   deployment it was meant to start. They narrow to `pipelines/infra-*.yml`
>   and `scripts/pipeline-terraform.sh`. The naming was chosen in Phase 7 to
>   make this a two-line fix, and it was.
> - **`scripts/tf.sh` and `scripts/lib/common.sh` join the list**, and that is a
>   pre-existing gap rather than a consequence of Phase 8. Every plan and every
>   apply in this pipeline runs both, so by D12's own argument they are the
>   pipeline's executable content and always were. Nobody noticed because
>   neither had changed since Phase 3.
>
> The list is now six patterns: `infra/**`, `pipelines/infra-*.yml`,
> `scripts/pipeline-terraform.sh`, `scripts/install-terraform.sh`,
> `scripts/tf.sh`, `scripts/lib/common.sh`. A test asserts the set exactly, so
> widening either of the first two back fails the offline gate.

> **Amended a third time in Phase 9 (2026-08-30) — `lambdas/**` joins the
> list.** Recorded here as well as in Phase 9's section, exactly as the
> amendment above was recorded in both Phase 7's and Phase 8's sections.
>
> `infra/environments/prod/hooks.tf` has packaged
> `lambdas/lifecycle_hook/handler.py` since Phase 6, and none of the six
> patterns above matches `lambdas/`. A commit that edited only a hook's
> handler changed no watched file: the infra pipeline would not run, and the
> fix would never reach the function deployed from it — no error, no failed
> run, nothing happens at all. The gap is three phases old, not something
> Phase 9 introduced; Phase 9 is only the first phase to add a second Lambda
> package under `lambdas/` and notice.
>
> The list is now seven patterns: the six above plus `lambdas/**`.
> `filePaths.includes`'s eight-pattern cap — the same limit Phase 8's
> amendment below hit at eleven — still has room for one more without
> splitting into two `push` blocks. `foundation/tests/pipeline_shape.tftest.hcl`'s
> pattern-set assertion is updated in the same commit as the trigger, and a
> second, duplicate copy of that same assertion in
> `foundation/tests/app_pipeline_shape.tftest.hcl` — added in Phase 8 to prove
> that phase's narrowing — needed the identical update or it would have failed
> the offline gate for a reason having nothing to do with what that file
> tests.

> **Amended in Phase 10 (2026-08-30) — the driver now clamps to a platform
> marker.** Recorded here as well as in Phase 10's section, following the
> precedent the trigger amendments above set for a cross-phase change.
>
> `scripts/pipeline-terraform.sh` reads `/bgd/platform/deployed_scope` and takes
> the smaller of it and `DEPLOY_SCOPE`. A layer above the result **skips green**,
> with a message that names the marker and `make rebuild` rather than blaming
> the scope — `"network is outside DEPLOY_SCOPE=all"` would be a lie, and an
> operator reading it would go looking for a bug in scope handling. The skip
> still writes `plan-vars.env`, so `pipelines/infra-plan.yml` sourcing it cannot
> turn a correct skip into a red stage.
>
> `foundation` is exempt from the read and must be: it is the layer that
> *creates* the parameter, so on a fresh account it does not exist when the
> layer is first planned. Every other layer treats an unreadable marker as
> **fatal** rather than assuming `all` — a gate that fails open is not a gate,
> and assuming `all` would let a lost `ssm:GetParameter` silently restore the
> behaviour the marker exists to remove.
>
> The two local `scope_rank`/`layer_rank` functions moved to `lib/common.sh` as
> `platform_scope_rank`/`platform_layer_rank`; the `platform_` prefix is not
> decoration, because `pipeline-deploy.sh` defines a `scope_rank` of its own over
> a different vocabulary and bash redefines a function silently.
>
> **The trigger's seven patterns are unchanged.** The three watched files this
> phase edits — `scripts/pipeline-terraform.sh`, `scripts/tf.sh`,
> `scripts/lib/common.sh` — are already matched, and the three operator scripts
> are not pipeline content: no stage runs them, so a change to one changes
> nothing about what a run does.

### Phase 8 — Application pipeline

- CodePipeline v2 filtered to `app/**` on `main`.
- Build stage: unit tests, coverage report, image build, SBOM, push to ECR, reports and SBOM written to the versioned artifact bucket.
- Deploy to staging via the standard ECS deploy action.
- Smoke tests against staging.
- Manual approval.
- Deploy to production, driving the ECS-native blue/green deployment.

Only images flow through this pipeline. Task definition and service shape stay owned by Terraform, which is what makes the ECS action's image-only limitation (§1.5) a non-issue.

**Exit criteria:** a commit under `app/` reaches production through the full path, with the blue/green deployment and its hooks firing as designed.

> **Amended in Phase 8 (2026-08-30).** The phase built more than this task list
> names, and departs from one of its bullets outright. Everything below is
> decided and argued in [the Phase 8
> plan](./phases/phase8/2026-08-30-phase-08-implementation-plan.md)'s §0.1.
>
> - **The standard ECS deploy action is not used, and cannot be.** The bullet
>   above says "deploy to staging via the standard ECS deploy action", and that
>   action takes an `imagedefinitions.json` and replaces **container image URIs
>   only**, copying every other field — the container `environment` included —
>   from the current task definition revision. Both of this project's task
>   definitions set `BGD_IMAGE_DIGEST` from `data.aws_ecr_image.api.image_digest`
>   in that environment, so a revision produced by the action would carry the
>   new image **alongside the previous image's digest**. Three things break at
>   once and none of them fails the deployment: `/version` reports a digest that
>   is not what is running (design §4's stated blue/green evidence surface, and
>   Phase 6's second exit criterion is read off it); `scripts/smoke.sh`'s fourth
>   assertion fails on every deploy; and the action registers a revision
>   Terraform does not know about, so `aws_ecs_service.task_definition` drifts
>   and the next `infra/**` merge reverts it — mid-deployment, on production.
>
>   So the deploy actions run **Terraform**: `terraform apply -var image_tag=…`,
>   letting `data.aws_ecr_image` resolve the tag to a digest **once**, feeding
>   both the container's `image` and `BGD_IMAGE_DIGEST` from the same
>   expression. There is one identifier for "what is running" and it cannot
>   disagree with itself.
>
>   **The paragraph above the exit criteria still holds, and by a better
>   mechanism than it claimed.** Only images flow through this pipeline: the
>   environment layers' Terraform is whatever is on `main`, and the single input
>   the pipeline supplies is a tag. An `app/**` merge cannot change the service
>   shape, because an `app/**` merge does not change `infra/`. What is lost is
>   the *use* of design §1.5's research finding, which is correct and unusable
>   here for a reason that has nothing to do with blue/green. §1.5 and §6 are
>   amended to say so rather than left describing a mechanism the project does
>   not use.
> - **Five CodeBuild projects and six IAM roles**, where the task list implies
>   neither and design §8.1 named two. Phase 7's F3 applied again: a build's
>   permissions come from `service_role` on the project, so roles that differ in
>   what a build may do mean projects that differ. Unlike Phase 7 there is no
>   shared deploy project — `app-deploy-staging` and `app-deploy-prod` differ in
>   their **role**, not only in a variable, and that is the point. Two
>   administrator roles cannot be told apart by policy, so the separation
>   between staging and production is **structural**: the staging deploy action
>   physically cannot act as the production principal.
> - **`APP_SCOPE`, which the task list does not mention.** Three values,
>   cumulative, naming where a run *stops*:
>
>   | `APP_SCOPE` | Build | DeployStaging | Prod |
>   |---|---|---|---|
>   | `build` | run | skip | skip |
>   | `staging` | run | run | skip |
>   | `all` | run | run | run |
>
>   Cumulative for the same reason `DEPLOY_SCOPE` is: the stages are ordered by
>   dependency, and deploying an image that was never built, or promoting one
>   that never passed staging smoke, are the two failures the ordering prevents.
>   Out-of-scope stages **skip** rather than fail, so a deliberately narrow run
>   finishes green and Phase 9's change-failure-rate does not count a deliberate
>   stop as a failure. `build` earns its place beyond symmetry: Phase 11 needs
>   to push a deliberately broken image *without* deploying it. Enforced twice,
>   for Phase 7 D4's asymmetry argument unchanged.
> - **`CODEBUILD_CLONE_REF`, not `CODE_ZIP`**, and the reproducibility
>   requirement is what forces it. `image_build_identity()` derives the tag,
>   `SOURCE_DATE_EPOCH` and `BUILT_AT` from `git rev-parse`, `git status` and
>   `git log`; a `CODE_ZIP` workspace has no `.git`, so all three fail. The
>   loud failure is fine — the quiet one is someone "fixing" it with a wall-clock
>   fallback, which compiles and silently ends the property design §4.1
>   *requires*. Two accepted costs: the source artifact can only be consumed by
>   CodeBuild actions, and the four roles whose builds take it need
>   `codeconnections:UseConnection`, because the build performs the clone.
> - **The SSM parameters are written *after* a successful apply, never before.**
>   Phase 7's D8 created them and named this phase as the writer; the decision
>   here is *when*. Writing them at build time would open a real hole: an
>   `infra/**` merge landing between Build and the production approval would
>   plan production against the new tag and deploy it — bypassing the approval,
>   with every stage of both runs green. Writing prod's parameter only in prod's
>   Apply action closes it. The corollary is that the tag reaching Terraform
>   comes from `#{Build.IMAGE_TAG}`, never from SSM: SSM is the record, not the
>   channel.
> - **The test suite runs in `python:3.14.6-slim`, not through `make test`.**
>   CodeBuild's ARM image ships Python 3.11 and 3.12; `.python-version` pins
>   3.14.6 and `scripts/create-venv.sh` refuses any other interpreter,
>   deliberately, per Phase 1's F1. Same suites, same interpreter, same
>   `--require-hashes` locks, same coverage gate — reached differently, and the
>   difference is the venv. Stated plainly because "the same command" would be
>   an overclaim.
> - **Staging applies directly; production is Plan → Approve → Apply.** Staging's
>   stated job is to fail fast, and a human gate in front of the environment
>   whose purpose is to be the gate would be a strange shape. Production takes
>   Phase 7's stage shape unchanged.
> - **Smoke is its own action** with its own project and its own role, and that
>   role makes **no AWS API call at all** — it is handed the URL and the digest
>   by the deploy action beside it. Folding it into the deploy buildspec would
>   have made "the apply failed" and "the deployment succeeded but the service
>   is wrong" indistinguishable in the pipeline view.
> - **The trigger's path filter is split across two `push` blocks**, because
>   `filePaths.includes` accepts a maximum of eight patterns and the list has
>   eleven. The two are OR'd, so it is exactly equivalent to one list — but each
>   must repeat the branch filter, since a filter that omits it matches every
>   branch.
> - **Phase 7's trigger narrowed**, recorded in that phase's section above as
>   well as here.
>
> **The exit criterion is not met by the branch alone.** It needs a pipeline
> that exists, a merge that happened and a deployment that ran, and the Phase 8
> session created no AWS resource. It is met by [the
> runbook](./runbooks/phase-08-app-pipeline.md), step 6.
>
> §2's branch table row 8 reads `feat/Phase8_AppPipeline`, which is the branch
> used. **No amendment needed there** — recorded explicitly, as Phases 3, 5, 6
> and 7 did, so the absence reads as checked rather than overlooked.

> **Amended in Phase 10 (2026-08-30) — the deploy driver clamps to the platform
> marker, and §11 of this phase's runbook is now wrong.** Recorded here as well
> as in Phase 10's section.
>
> `scripts/pipeline-deploy.sh` reads `/bgd/platform/deployed_scope` and skips an
> environment the marker says is torn down — green, writing `deploy-vars.env` or
> `plan-vars.env` as the mode requires, so a correct skip cannot become a red
> stage. The marker's four values are mapped onto `env_rank`'s scale rather than
> compared against it directly: `APP_SCOPE` ranks `build`/`staging`/`all` and
> this script ranks environments, and collapsing the two scales would put
> `build` and `network` on the same number, which is true of nothing. There is
> no exemption here — the Build stage, which legitimately runs while the
> platform is down and whose image is waiting when it comes back, is a different
> script that never reaches the gate.
>
> **[This phase's runbook §11](./runbooks/phase-08-app-pipeline.md) told you to
> disable both pipeline triggers in the console after a teardown** and re-enable
> them as the first step of the Phase 10 rebuild — a fourth manual step in a
> project whose documents claim there are exactly three. It is rewritten in the
> same commit: there is now nothing to disable, a merge while torn down is safe
> and creates nothing, and `make rebuild` raises the marker again as its last
> act on each layer.

### Phase 9 — Observability and release metrics

- EventBridge rules on ECS deployment state changes and CodePipeline execution state changes.
- A metrics Lambda writing custom metrics under a `ReleaseMetrics` namespace: deployment frequency, lead time from commit to production, change failure rate, MTTR.
- A single CloudWatch dashboard covering both pipeline health and application health.
- SNS email alerts on pipeline failure, deployment failure and rollback.

**Exit criteria:** a real deployment produces metrics on the dashboard; a deliberately failed deployment produces an email.

> **Amended in Phase 9 (2026-08-30).** Everything below is decided and argued
> in [the Phase 9
> plan](./phases/phase9/2026-08-30-phase-09-implementation-plan.md)'s §0.1.
>
> - **Everything but four alarm-action lines lives in `foundation`, and a
>   layer cycle forces it rather than a style preference** (D2, F1). The
>   tempting split — put the ECS rule and half the dashboard beside the
>   service they watch, in `prod` — cannot be done: `prod/locals.tf` already
>   reads `foundation`'s remote state, and a mirror the other way would make
>   each layer depend on the other. Terraform would not report that as a
>   cycle, because the two states are separate files read at plan time, not
>   nodes in one graph — the symptom would be `foundation`'s plan failing to
>   read a state file that `make teardown` had already emptied, in the layer
>   whose entire purpose is surviving teardown. A second, independent reason
>   would still apply if the first were solved: the metric history is the
>   deliverable, and a dashboard destroyed and recreated every session is one
>   nobody builds the habit of opening. `foundation` addresses `prod` by
>   **name** — the ECS service ARN is built from this layer's own convention
>   variables — not by ARN read through state. The one thing that can only be
>   set where the alarm is, and therefore stays in `prod`, is `alarm_actions`
>   on the four bake alarms.
> - **The collector decides what is alert-worthy; EventBridge does not**
>   (D3). An `input_transformer` on a direct EventBridge→SNS target would need
>   no Lambda at all, and was rejected because "what deserves an email" would
>   then live in a template string inside a Terraform resource, untestable by
>   anything. Routed through the collector, that decision is ordinary Python
>   with a pytest suite around it, and a broken collector is not a silent
>   single point of failure: its own `Errors` alarm (D13) watches it directly
>   and does not travel through the function it is watching. A second
>   EventBridge→SNS path was rejected too — two paths to one inbox means two
>   emails per failure, and a duplicate alert trains the recipient to filter
>   the topic faster than a missing one does.
> - **The ECS rule filters narrowly on the service ARN and deliberately not
>   at all on the event name** (D4). Which `detail.eventName` values ECS
>   emits for a *blue/green* deployment — and specifically what an
>   alarm-triggered rollback produces — is a runtime contract with no offline
>   source of truth. Guessing the vocabulary and filtering on it wrong would
>   make the rollback this whole project exists to demonstrate produce no
>   metric and no email, with the rule looking correct in the console the
>   entire time. Filtering on nothing costs one Lambda invocation and one log
>   line for an event the handler does not recognize, and is how the real
>   vocabulary gets discovered — the runbook's step 8 reads it back.
> - **Seven metric streams, six metric names, and the two DORA ratios are
>   computed on the dashboard rather than stored** (D5). `DeploymentSucceeded`,
>   `DeploymentFailed`, `DeploymentRolledBack`, `LeadTimeSeconds`,
>   `RecoveryTimeSeconds` and `PipelineFailed` — six names, seven streams
>   because `PipelineFailed` carries a two-value dimension and CloudWatch
>   bills per unique combination (about $2.10/month while active, F10).
>   Change failure rate and deployment frequency are not among them: a ratio
>   stored as a metric can only ever be computed over whatever window the
>   writer chose, never the window the reader is looking at. As dashboard
>   metric math — `100 * failed / (failed + succeeded)`, `SUM(succeeded)` —
>   both recompute for whatever range is dragged.
> - **MTTR with no state store, and the ordering of two calls is what makes
>   that true** (D7). On a success, the handler asks CloudWatch what it
>   already wrote: one `GetMetricData` call over the last 30 days, scanned
>   newest-first, across `DeploymentFailed` and `DeploymentSucceeded`. If the
>   most recent failure has no success after it, this success is the
>   recovery. That call **must** run before `DeploymentSucceeded` is written
>   for this event, or the success just written is the one it finds and every
>   recovery measures zero — the ordering is one line apart in the code and a
>   test asserts it by recording call order against a fake client. No
>   DynamoDB table, no S3 marker: the metric store is the state store, which
>   it already had to be for the dashboard.
> - **Three decisions earlier phases deferred by name, settled here.**
>   Container Insights on both ECS clusters **stays disabled** (D14) — `AWS/ECS`
>   already publishes `CPUUtilization`, `MemoryUtilization` and
>   `RunningTaskCount` at service level for free, which is every ECS signal
>   this dashboard shows, and Container Insights bills per metric per hour per
>   task for per-container detail nothing here asks for. The four production
>   bake alarms gain `alarm_actions` pointing at the alert topic (D12), which
>   is the reason Phase 6's own test asserting their absence has to be
>   inverted rather than deleted — Phase 6 created those alarms with no
>   actions for the express purpose of letting this phase attach to them
>   rather than creating parallel ones. And the Lambda module needs no
>   dependency-bearing variant (D10, F2): `infra/modules/lambda/README.md`
>   predicted one, but boto3 and botocore ship in the Lambda managed Python
>   runtime, so `archive_file` over the collector's single `handler.py` still
>   expresses the whole package and `terraform test` still really builds the
>   zip against a mocked provider.
> - **Phase 7's trigger gains a seventh pattern**, recorded in that phase's
>   section above as well as here.
>
> **Neither exit criterion is met by the branch alone.** Both need a pipeline
> execution against a running production service, and the Phase 9 session
> created no AWS resource (D1). They are met by [the
> runbook](./runbooks/phase-09-observability.md): the second — a deliberately
> failed deployment produces an email — at step 5, which declines the
> production approval rather than relying on an unverified `APP_SCOPE` value
> to fail loudly; the first — a real deployment produces metrics on the
> dashboard — at step 10, which is the one check an apply cannot perform for
> itself, because `PutDashboard` validates a widget's structure and nothing
> about whether a `SEARCH()` expression it contains matches anything (F8).
>
> §2's branch table row 9 reads `feat/Phase9_Observability`, which is the
> branch used. **No amendment needed there** — recorded explicitly, as Phases
> 3, 5, 6, 7 and 8 did, so the absence reads as checked rather than
> overlooked.
>
> **Eleven decisions were taken during execution rather than before it**, and
> they are recorded in [the local verification
> record](./phases/phase9/2026-08-30-local-verification.md)'s §9, each with
> what it costs if it turns out to be wrong. Six of the eleven were forced by a
> defect in this project's own documents rather than by anything an
> implementer did — including a matcher this roadmap's own plan specified that
> could not pass the plan's own test (§9.3), and a runbook step that would have
> tested nothing (§9.6). That ratio is the honest headline of the phase, and it
> is recorded where a reader looking for what went wrong will find it rather
> than only in the commit that fixed it.

### Phase 10 — Teardown and rebuild automation

- `make teardown` — destroys `prod` → `staging` → `network` in order, leaving `foundation` and `bootstrap` intact.
- `make rebuild` — applies `network` → `staging` → `prod`.
- A runbook stating exactly what survives a teardown, what does not, and what a rebuild costs in time.
- **A full teardown and rebuild cycle executed and verified**, not merely written. This is the honest test of whether the infrastructure as code is complete.

**Exit criteria:** after a teardown-and-rebuild cycle, both environments serve traffic again with no manual step other than waiting.

> **Amended in Phase 10 (2026-08-30).** The four bullets above describe two
> commands and a runbook. The branch delivers those and five things the list
> does not name, each of which turned out to be load-bearing rather than
> optional.
>
> - **A marker, and both pipelines clamp to it.**
>   `/bgd/platform/deployed_scope` is an SSM `String` in `foundation` holding
>   one of `foundation | network | staging | all` — the same four values
>   `DEPLOY_SCOPE` already uses, deliberately, since `pipeline-terraform.sh`
>   already ranks them and `foundation/locals.tf` already orders them. It lives
>   in `foundation` because it has to survive what it describes: anywhere else
>   and the record of "the platform is torn down" is destroyed by the teardown
>   (plan D2). Both pipeline drivers take the smaller of their own scope and the
>   marker, and a layer above that **skips green rather than failing** — since
>   Phase 9 a failed run emails you and counts in change-failure-rate, so a run
>   that correctly declined to deploy into a torn-down account must not look
>   like a bad deployment (D5).
>
> - **`SCOPE` on both operator scripts**, cumulative, naming where the run
>   stops, and refusing an unrecognised value by name rather than falling back
>   to the safe end — a `SCOPE=staginng` typo that silently tore down everything
>   would be a bad surprise, and one that silently tore down nothing while
>   printing success would be worse (D7). **No `SCOPE` value and no flag reaches
>   `foundation` or `bootstrap`** (D16); that is what §1's five-layer split is
>   for, and it is now enforced rather than described.
>
> - **`make verify-idle`**, which the task list does not mention at all and
>   which is the answer to "did the teardown actually work". It reads AWS
>   directly and **opens no state file**, because the three cases it exists for
>   — a resource created by hand and never in state, a state file that drifted,
>   and a destroy that failed part-way — are exactly the cases where Terraform
>   agrees with itself and is wrong (D9). A Cost Explorer check was considered
>   and rejected: its data lags roughly a day, so run after a teardown it
>   reports the day the platform was up and reports it as though it were the
>   answer (D15).
>
> - **A dependency-free shell suite**, and `make test-scripts` joins the offline
>   gate and the pipeline's Validate stage. This phase adds roughly six hundred
>   lines of shell whose failure mode is destroying the wrong thing, plus rank
>   arithmetic that decides whether production is deployed into; Phase 8's
>   `bash -n` plus a transcript in a verification document is honest evidence
>   but is not a regression test, because nothing re-runs it (D12, D14).
>
> - **`layer_dir()` moved into `lib/common.sh`.** `tf.sh`'s own comment asked
>   for it — the map existed in three places and `rebuild.sh` would have been
>   the fourth. `lint-infra.sh` is deliberately not converted, because its
>   `layer_path` returns a path relative to `infra/` and must pass an
>   already-relative path through unchanged (D13, F6).
>
> **The gap [Phase 8's runbook §11](./runbooks/phase-08-app-pipeline.md) handed
> to this phase by name is closed.** That section told you to disable both
> pipeline triggers in the console after a teardown and re-enable them as the
> first step of the rebuild — a fourth manual step in a project whose documents
> claim there are exactly three. There is now nothing to disable. The corollary
> the task list does not state, and which will surprise someone eventually:
> **a merge to `main` can no longer rebuild a torn-down layer.** That is
> deliberate, and it is the cheap direction — the alternative is a $99/month
> surprise from a merge nobody thought of as a deployment. `make rebuild` is the
> only thing that raises the marker, and [the Phase 10
> runbook](./runbooks/phase-10-teardown-and-rebuild.md) §9 gives the one-line
> `aws ssm put-parameter` escape hatch for the day you want the pipeline to do
> it instead.
>
> **The fourth bullet is not met by this branch**, and neither is the exit
> criterion. The bullet asks for *a full teardown and rebuild cycle executed and
> verified, not merely written*, and it is right to. This session created no AWS
> resource and made no AWS API call (D1). The cycle is [the
> runbook](./runbooks/phase-10-teardown-and-rebuild.md)'s steps 3 through 6,
> ending with `make rebuild` exiting 0 — which by D11 means both environments
> were smoke-tested and served the digest Terraform deployed, not merely that
> three applies returned 0. Said plainly here rather than letting a green gate
> imply a proven cycle, as Phases 3 through 9 did.
>
> What the branch's gate does prove is that every guard, every rank comparison
> and every refusal path behaves as written: 116 shell checks across three test
> files, plus the marker's shape, default and output asserted in
> `infra/foundation/tests/pipeline_shape.tftest.hcl`. That is what makes the
> runbook worth following rather than debugging.
>
> §2's branch table row 10 reads `feat/Phase10_TeardownRebuild`, which is the
> branch used. **No amendment needed there** — recorded explicitly, as Phases
> 3, 5, 6, 7, 8 and 9 did, so the absence reads as checked rather than
> overlooked.

### Phase 11 — Rollback evidence and documentation

You drive this phase; Claude writes the runbooks and prepares the broken build.

- A **genuinely broken commit** on a dedicated branch — not a simulated failure toggle. The evidence is only worth something if the failure is real.
- Three demo runbooks with exact commands and expected output:
  1. **Hook rejection** — the bad build never receives production traffic.
  2. **Alarm-triggered rollback during bake** — the 5xx rate breaches and ECS reverts automatically.
  3. **Manual rollback** — redeploy the previous image digest.
- You execute each and capture console screenshots; Claude collects the CloudWatch logs and CLI output alongside them under `/docs/evidence/`.
- Architecture diagram, ADRs for the significant deviations (ECS-native over CodeDeploy, NAT over VPC endpoints, five layers over four), operational runbook, and a README that makes the project legible to someone arriving cold.

**Exit criteria:** three demonstrations captured with evidence; documentation complete.

---

## 4. Risks carried forward

The design document's risk table (§11) still stands. These are added or changed by this roadmap.

| Risk | Handling |
|---|---|
| **Lambda may not offer a Python 3.14 managed runtime** | Verified in Phase 0 before anything depends on it. Falls back to the newest available runtime, documented as a deliberate divergence from the container's 3.14. |
| **Hosted zone may already exist from Route 53 registration** | Verified in Phase 0. If it exists, Terraform adopts it and the two-phase apply never occurs. If Terraform creates it, the registrar's name servers must be updated to the new zone's before ACM validation can succeed. |
| **The infra pipeline manages the layer containing itself** | Expected. A broken pipeline definition is repaired by a local `terraform apply`; the runbook documents this. |
| **Repeated teardown and rebuild cycles surface latent IaC gaps** | This is the point of Phase 10 rather than a risk to avoid. Gaps found there are bugs in the IaC, and fixing them is in scope. |
| **ACM certificate is in `foundation`, ALBs are in the environment layers** | The certificate outlives teardown, so listeners reference it through remote state. No re-issuance on rebuild. |

---

## 5. What happens next

On approval of this roadmap, the detailed implementation plan expands each phase into specific, ordered, individually verifiable tasks with explicit exit criteria.

Nothing is committed automatically. Commits are proposed for your approval as the work divides, and each phase ends with a pull request you review and merge.
