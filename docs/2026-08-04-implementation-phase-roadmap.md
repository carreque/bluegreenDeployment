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

### Phase 7 — Infrastructure pipeline

- CodePipeline v2 sourced from `carreque/bluegreenDeployment` via CodeConnections, filtered to `infra/**` on `main`.
- Stages: Source → Validate (`fmt`, `validate`, `tflint`, `checkov`) → per-layer plan, manual approval and apply.
- A `DEPLOY_SCOPE` execution variable (`foundation` | `network` | `staging` | `all`) so a run stops where you want it to. Out-of-scope stages skip cleanly and the execution still finishes green — declining an approval would mark the run Failed and corrupt the change-failure-rate metric in Phase 9.
- The plan output is surfaced in the approval message, so approval is an informed decision rather than a reflex.
- Handover: from this point the infra pipeline manages `foundation`, `network` and both environment layers.

**Exit criteria:** a change to an environment layer flows through the pipeline and applies; a `DEPLOY_SCOPE=network` run demonstrably leaves production untouched.

### Phase 8 — Application pipeline

- CodePipeline v2 filtered to `app/**` on `main`.
- Build stage: unit tests, coverage report, image build, SBOM, push to ECR, reports and SBOM written to the versioned artifact bucket.
- Deploy to staging via the standard ECS deploy action.
- Smoke tests against staging.
- Manual approval.
- Deploy to production, driving the ECS-native blue/green deployment.

Only images flow through this pipeline. Task definition and service shape stay owned by Terraform, which is what makes the ECS action's image-only limitation (§1.5) a non-issue.

**Exit criteria:** a commit under `app/` reaches production through the full path, with the blue/green deployment and its hooks firing as designed.

### Phase 9 — Observability and release metrics

- EventBridge rules on ECS deployment state changes and CodePipeline execution state changes.
- A metrics Lambda writing custom metrics under a `ReleaseMetrics` namespace: deployment frequency, lead time from commit to production, change failure rate, MTTR.
- A single CloudWatch dashboard covering both pipeline health and application health.
- SNS email alerts on pipeline failure, deployment failure and rollback.

**Exit criteria:** a real deployment produces metrics on the dashboard; a deliberately failed deployment produces an email.

### Phase 10 — Teardown and rebuild automation

- `make teardown` — destroys `prod` → `staging` → `network` in order, leaving `foundation` and `bootstrap` intact.
- `make rebuild` — applies `network` → `staging` → `prod`.
- A runbook stating exactly what survives a teardown, what does not, and what a rebuild costs in time.
- **A full teardown and rebuild cycle executed and verified**, not merely written. This is the honest test of whether the infrastructure as code is complete.

**Exit criteria:** after a teardown-and-rebuild cycle, both environments serve traffic again with no manual step other than waiting.

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
