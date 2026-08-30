# Phase 8 — Application pipeline: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-30
**Status:** Implemented 2026-08-30. The branch's gate is green; the exit criterion is met by [the runbook](../../runbooks/phase-08-app-pipeline.md), not by the branch (D1).
**Branch:** `feat/Phase8_AppPipeline`
**AWS cost incurred by this phase as planned:** **$0.** Every deliverable is written and verified locally, against mocked providers and with no AWS session. The apply that creates the pipeline, and the exit-criteria demonstration, are handed to you as a runbook — see §0.1 D1.
**Companion documents:**
[design research](../../2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 2 plan](../phase2/2026-08-12-phase-02-implementation-plan.md) ·
[Phase 5 plan](../phase5/2026-08-28-phase-05-implementation-plan.md) ·
[Phase 6 plan](../phase6/2026-08-28-phase-06-implementation-plan.md) ·
[Phase 7 plan](../phase7/2026-08-29-phase-07-implementation-plan.md) ·
[Phase 7 runbook](../../runbooks/phase-07-infra-pipeline.md) ·
[naming and tagging convention](../../naming-and-tagging-convention.md)

**Goal:** Build the application pipeline — a CodePipeline v2 sourced from `carreque/bluegreenDeployment` through the existing CodeConnections link, filtered to `app/**` on `main`, that runs the test suite, builds the reproducible image, generates its SBOM, pushes it to ECR, deploys it to staging, smoke-tests staging, and then plans, seeks approval for, and applies the production blue/green deployment — and prove it correct offline before a single resource is created.

This is the phase that closes the loop the project was built to demonstrate: a commit under `app/` becomes a production blue/green deployment, with the dark canary hook and the bake alarms Phase 6 built standing between it and the users.

**Architecture:** Files added to the existing `infra/foundation/` root module, beside the infra pipeline — not a new layer, and not a new pipeline file that duplicates the one Phase 7 wrote. Five CodeBuild projects with five separate service roles carry the work; buildspecs under `pipelines/` stay short and delegate to shell under `scripts/`, matching the convention the makefile already states. Correctness is asserted by Terraform's native test framework against `mock_provider`; the whole gate stays offline.

**Tech stack:** Terraform 1.15.7, AWS provider 6.61.0, CodePipeline **V2**, CodeBuild on `aws/codebuild/amazonlinux-aarch64-standard:3.0` for the image build and `aws/codebuild/amazonlinux-x86_64-standard:5.0` for everything else, `python:3.14.6-slim` and `amazon/dynamodb-local` from the digest pins the Dockerfile and `docker-compose.yml` already carry, syft 1.51.0 and skopeo 1.20.0 from the digest pins `scripts/generate-sbom.sh` and `scripts/seed-ecr.sh` already carry.

**Spec:** [phase roadmap §3, Phase 8](../../2026-08-04-implementation-phase-roadmap.md#phase-8--application-pipeline), elaborated by [design research §6](../../2026-08-04-blue-green-deployment-platform-design-research.md#6-pipelines), and **departing from** [§1.5's premise about the standard ECS deploy action](../../2026-08-04-blue-green-deployment-platform-design-research.md#15-codepipeline-can-trigger-native-bluegreen-directly) for the reason recorded in F1 and D2.

---

## Global Constraints

Project-wide requirements. Every task's requirements implicitly include this section.

- **Naming:** `bgd-us-east-1-<resource>`, all lowercase, hyphen-separated. These are project-wide resources, so they take **no `<env>` segment** — convention §2 — even where the resource name contains the word `staging` or `prod`, which here names *what the build acts on*, not which environment owns it. See the [convention](../../naming-and-tagging-convention.md).
- **Tagging:** exactly four keys — `environment`, `projectName`, `region`, `owner` — applied through the provider's `default_tags`. This layer's `environment` is `shared`; this phase adds no tag and changes no tag.
- **Terraform:** `required_version >= 1.10`, AWS provider `~> 6.61`, S3 backend with `use_lockfile = true`. Unchanged from Phase 3; this phase adds no provider.
- **`pipeline_type = "V2"`** is mandatory, for the same reasons as Phase 7: `variable`, `trigger` and `stage.before_entry` are all V2-only.
- **The offline gate:** `make tf-check` must pass on a machine that has never run `aws sso login`.
- **Every checkov finding is either fixed or skipped with a written reason.** A bare skip is not acceptable; the reason names the trade-off.
- **Nothing under `infra/environments/` changes.** Both environment layers are already shaped for this phase — `var.image_tag`, `data.aws_ecr_image`, `BGD_IMAGE_DIGEST`, the outputs `scripts/smoke.sh` reads. If this phase needs to edit either layer, something in the design has been misread; stop and re-read D2 before editing.

---

## 0. Purpose and non-goals

Phase 7 gave `infra/` a pipeline. `app/` still has none: an application change is built on a laptop with `make build`, pushed with `make seed-ecr`, and deployed by editing a gitignored `terraform.tfvars` and running `make apply-prod`. Every claim the project makes about deployment frequency, lead time and change failure rate (Phase 9) describes a process that does not exist yet.

This phase builds it. Its job is not automation for its own sake — it is that **the image that reaches production is the image that was tested**, provably, by digest, at every hop.

**This phase deliberately does not:**

- create any AWS resource, or make any AWS API call, in this session (D1)
- change the task definition or the service shape in either environment layer. Only images flow through this pipeline — that separation is design §1.5's, and D2 keeps it while changing the mechanism that enforces it
- use the standard CodePipeline ECS deploy action (D2, F1)
- notify anyone of a pipeline failure or a deployment failure — Phase 9 owns notification and attaches to this pipeline's events, exactly as it attaches to Phase 6's alarms and Phase 7's pipeline
- add or change an application endpoint, a test, or a line of `app/src/`
- produce the rollback evidence — Phase 11 owns that, and needs this pipeline to exist first
- change `infra/bootstrap`, `infra/network`, `infra/environments/staging` or `infra/environments/prod`

### 0.1 Decisions taken before this plan was written

#### D1 — This session writes and verifies; you apply

Same as Phases 3 through 7, and for the same reason. Everything that can be built and proved without an AWS session is; the applies and the exit-criteria demonstration are handed over as [a runbook](../../runbooks/phase-08-app-pipeline.md).

The branch's own gate is `make tf-check`. **The exit criterion in §5 is not met by the branch alone** and this plan says so in the roadmap amendment rather than letting a green branch imply a green pipeline.

#### D2 — Terraform drives the deployment; the standard ECS deploy action is not used

This is the phase's central decision and it departs from the roadmap's task list, which says "Deploy to staging via the standard ECS deploy action."

The forcing fact is F1: the CodePipeline **ECS** deploy action takes `imagedefinitions.json` and replaces **container image URIs only**, copying every other field from the current task definition revision. Both of this project's task definitions set

```hcl
{ name = "BGD_IMAGE_DIGEST", value = data.aws_ecr_image.api.image_digest }
```

in the container environment (`infra/environments/staging/ecs.tf`, `infra/environments/prod/ecs.tf`). A revision produced by the ECS action would therefore carry **the new image alongside the previous image's digest in that variable**. Three things break at once, and none of them fails the deployment:

1. `/version` reports a digest that is not what is running. That endpoint is design §4's stated blue/green evidence surface and Phase 6's second exit criterion is read directly off it.
2. `scripts/smoke.sh`'s fourth assertion — `/version`'s `image_digest` equals the digest Terraform recorded — fails on every single deploy. That assertion is what Phase 5's D4 called "what makes this a deployment check rather than a liveness check", and it is the staging gate this phase is supposed to install.
3. The ECS action registers a revision Terraform does not know about, so `aws_ecs_service.task_definition` drifts and the next `infra/**` merge reverts it — mid-deployment, on production. Phase 6's D10 refused to introduce exactly this drift by CLI, and it would be odd to introduce it by pipeline instead.

So the deploy actions run **Terraform**: write nothing, plan or apply the environment layer with `-var image_tag=<the tag just built>`, and let `data.aws_ecr_image` resolve that tag to a digest **once**, feeding both the container's `image` field and `BGD_IMAGE_DIGEST` from the same expression. There is one identifier for "what is running" and it cannot disagree with itself.

What is preserved is the property design §1.5 actually cares about: **only images flow through this pipeline.** The environment layers' Terraform is whatever is on `main`; the single input this pipeline supplies is a tag. An `app/**` merge cannot change the service shape, because an `app/**` merge does not change `infra/`.

What is lost is the use of design §1.5's research finding. That finding is correct — the ECS action *can* drive a native blue/green deployment — and it is unusable here for a reason that has nothing to do with blue/green. Task 12 amends §1.5 and §6 to say that plainly rather than leaving the document describing a mechanism the project does not use.

#### D3 — `APP_SCOPE` is cumulative — it names where a run *stops*

Three values, defaulting to `all`, mirroring Phase 7's `DEPLOY_SCOPE`:

| `APP_SCOPE` | Build | DeployStaging | Prod |
|---|---|---|---|
| `build` | run | skip | skip |
| `staging` | run | run | skip |
| `all` | run | run | run |

Cumulative rather than exclusive for the same reason Phase 7's is: the stages are ordered by dependency. Deploying to production an image that was never built, or promoting one that never passed staging smoke, are the two failures the ordering exists to prevent. An unrecognised value runs nothing past Build, loudly.

Out-of-scope stages **skip**; they do not fail. A declined approval marks a run `Failed`, which would make Phase 9's change-failure-rate count a deliberate stop as a failure — the roadmap's stated reason for the mechanism in the first place.

`build` earns its place beyond symmetry: Phase 11 needs to push a deliberately broken image to ECR *without* deploying it, so the demonstration can be started by hand at the moment the screenshots are being taken.

#### D4 — The scope is enforced twice, and the redundancy is deliberate

Same structure and the same asymmetry argument as Phase 7's D4. `before_entry`'s `VariableCheck` rule skips the stage; `scripts/pipeline-deploy.sh` checks `APP_SCOPE` again and refuses.

The reason is F2 of the Phase 7 plan, unchanged and still unresolved offline: the rule's `configuration` is an untyped `map(string)`, so whether `MATCHES` is an accepted operator is not in the provider schema. The failure modes are asymmetric. A condition wrong in the direction of *entering* a stage costs an unwanted approval when the script refuses; without the script it would deploy to production a build the operator asked to stop at staging.

The smoke action is inside the staging stage and makes no AWS call, so an unwanted run of it is harmless; it gets the stage condition and no script gate, and that asymmetry is stated rather than left as an inconsistency.

#### D5 — Five CodeBuild projects, because the service role is a property of the project

Phase 7's F3, applied again: a build's permissions come from `service_role` on `aws_codebuild_project`. `action.role_arn` on a CodePipeline action is the role CodePipeline assumes to *invoke* the action, and it cannot substitute. Five roles that differ in what a build may do therefore means five projects.

| Project | Compute | What it does | What it may do |
|---|---|---|---|
| `app-image` | `ARM_CONTAINER`, privileged | test, build, SBOM, push, publish reports | ECR push to one repository, write the artifact bucket, its own log group |
| `app-deploy-staging` | `LINUX_CONTAINER` | `terraform apply` on staging, then record the tag | `AdministratorAccess` |
| `app-smoke` | `LINUX_CONTAINER` | `scripts/smoke.sh` against a URL passed in | **nothing** |
| `app-plan-prod` | `LINUX_CONTAINER` | `terraform plan` on prod, export the summary | `ReadOnlyAccess`, plus its log group, the artifact bucket, the `*.tflock` lock file and the connection |
| `app-deploy-prod` | `LINUX_CONTAINER` | apply the saved plan, then record the tag | `AdministratorAccess` |

Unlike Phase 7, the layer a build acts on is **not** passed per action — `app-deploy-staging` and `app-deploy-prod` differ in their role, not only in a variable, which is the whole point of the separation. So there is no shared deploy project.

#### D6 — Per-environment deploy roles, and a smoke role that touches no AWS

Two decisions in one, at opposite ends of the privilege range.

**Both deploy roles attach `AdministratorAccess`,** for Phase 7 D6's argument unchanged: a `terraform apply` on a layer that creates IAM roles cannot be meaningfully narrowed, because a principal that can create a role and attach a policy to it can already grant itself anything. A narrower policy would describe a boundary that does not exist while failing at apply time in whichever resource it forgot.

**They are two roles, not one,** which is where this phase goes further than Phase 7 did. The staging deploy action physically cannot reach production: its role's trust policy is its own, and the `Prod` stage's actions run as a different principal. That is a structural separation rather than a policy one, and it is the only kind available given the paragraph above. The compensating control between a merge and production remains the manual approval on a plan a human read.

**The smoke role makes no AWS API call at all** — `scripts/smoke.sh` needs `curl` and `jq`, and this phase passes it `BGD_SMOKE_URL` and `BGD_SMOKE_DIGEST` as action-level environment variables precisely so it does not need to read Terraform state. Its policy grants its log group and the artifact bucket and nothing else, and a test asserts that no action outside `logs:` and `s3:` appears in it. That property erodes the first time someone adds a step needing "just one read", and nothing fails when they do — the same argument, and the same test shape, as Phase 7's `infra-validate`.

#### D7 — `ARM_CONTAINER` for the image build, `LINUX_CONTAINER` for the other four

Phase 2's amendment requires it: the image is `linux/arm64` only, and an x86 build would have to emulate — which measures the emulator as much as the Dockerfile, and produces a manifest for the wrong architecture. `aws/codebuild/amazonlinux-aarch64-standard:3.0`.

The other four run Terraform, `curl` and `jq`, all architecture-agnostic, and Phase 7's D7 already argued for x86 there: `scripts/lint-infra.sh`'s digest-pinned containers are not proven to have arm64 variants. They stay on `aws/codebuild/amazonlinux-x86_64-standard:5.0`, which is also the image `scripts/install-terraform.sh`'s `linux_amd64` checksum pins.

**This divergence is deliberate in both directions and it is the same fact seen twice:** what decides the compute type is the architecture of the artifacts a build handles, not a project-wide preference.

#### D8 — `CODEBUILD_CLONE_REF`, not `CODE_ZIP`

F2. `image_build_identity()` in `scripts/lib/common.sh` derives the tag, `SOURCE_DATE_EPOCH` and `BUILT_AT` from `git rev-parse`, `git status --porcelain` and `git log -1`. A CodePipeline `CODE_ZIP` source artifact has no `.git` directory, so all three fail — and the build reproducibility that Phase 2 measured, which is a *stated requirement* (design §4.1), would silently stop holding in the one place it most needs to.

`OutputArtifactFormat = "CODEBUILD_CLONE_REF"` hands CodeBuild a git reference instead of a zip, and CodeBuild clones. The costs, both accepted:

- the source artifact can only be consumed by **CodeBuild** actions. Every action in this pipeline that consumes an artifact is a CodeBuild action, and the manual approval consumes none.
- the `app-image` role needs `codeconnections:UseConnection` on the connection, because the clone is performed by the build rather than by CodePipeline. Granted to the four roles that take the source artifact as input, scoped to the one connection ARN.

Phase 7's infra pipeline keeps `CODE_ZIP`. Nothing in it reads git, and a zip is the cheaper artifact.

#### D9 — The SSM parameter is written *after* a successful apply, not before

Phase 7's D8 created `/bgd/staging/image_tag` and `/bgd/prod/image_tag` with `ignore_changes = [value]`, and named this phase as the writer. The decision here is *when*.

**After the apply succeeds**, so the parameter records what **is** deployed rather than what someone intended to deploy. Two consequences, and the first is a genuine hole that the other ordering opens:

- If the Build stage wrote both parameters up front, an `infra/**` merge landing between Build and the production approval would plan production against the new tag and deploy it. The approval that is supposed to stand between a merge and production would have been bypassed by a *different* pipeline, and every stage of both runs would be green. Writing prod's parameter only in prod's Apply action closes it: until production has the image, nothing says it does.
- A production deployment that bakes badly and rolls back fails the apply. The parameter is not written, and it still names the image that is actually serving — so the next `infra/**` plan is a no-op rather than a re-attempt of the deployment that just rolled back.

The corollary for the Prod stage is that the tag reaching `terraform plan` comes from `#{Build.IMAGE_TAG}`, not from SSM. No stage reads SSM to discover what it is deploying; SSM is the record, not the channel.

#### D10 — The test suite runs in the digest-pinned `python:3.14.6-slim` container

F3: CodeBuild's `amazonlinux-aarch64-standard:3.0` image ships Python 3.11 and 3.12, not the 3.14.6 that `.python-version` pins, and `scripts/create-venv.sh` refuses any interpreter that is not exactly the pin. So `make test` cannot run verbatim in this build, and the two ways to make it run — building CPython 3.14.6 from source, or installing a third-party version manager — are both several minutes and a new dependency for a problem the project has already solved four times.

The build runs pytest inside `python:3.14.6-slim@sha256:7bec…`, **the same digest `app/Dockerfile` pins**, networked to `amazon/dynamodb-local@sha256:ff89…`, **the same digest `app/docker-compose.yml` and `.github/workflows/pr-validate.yml` both pin**. Same interpreter, same `--require-hashes` locks, same three suites, same coverage gate.

Stated plainly because the alternative is to overclaim: this is **not literally the `make test` command**. It is the same test run, reached differently, and the difference is the venv. Running tools from digest-pinned containers rather than installing them is this project's established habit — tflint, checkov, syft and skopeo all work that way — so the mechanism is familiar rather than novel; but the honest sentence is "the same suites on the same interpreter", not "the same command".

#### D11 — Staging applies directly; production is Plan → Approve → Apply

The two environments get different shapes because their jobs are different, exactly as Phases 5 and 6 made them different.

**Staging** is one action: `terraform apply -auto-approve` with the new tag. Its stated job is to fail fast (roadmap §Phase 5), its circuit breaker reverts a task that never becomes healthy, and there is nobody to approve anything at that point in the run. A plan-then-approve on staging would put a human gate in front of the environment whose purpose is to be the gate.

**Production** is Phase 7's stage shape: a Plan action that exports `PLAN_SUMMARY` and `PLAN_URL`, a manual approval that displays them, and an Apply action that applies **the saved plan file** and does not re-plan. The approval then approves a specific change — this digest, this task definition revision — rather than a description of one, and the apply cannot compute something different from what was read. Phase 7's D9, unchanged.

#### D12 — Smoke is its own action, and it is the staging gate

Roadmap §Phase 8 lists "Smoke tests against staging" as a step, and it is one: a separate action with `run_order = 2` inside the `DeployStaging` stage.

Folding it into the deploy buildspec would save a project and a role and make two different failures — "the apply failed" and "the deployment succeeded but the service is wrong" — indistinguishable in the pipeline view. It would also lose D6's property that the thing checking production-shaped behaviour holds no credentials.

It runs `scripts/smoke.sh staging` unchanged, through the `BGD_SMOKE_URL`/`BGD_SMOKE_DIGEST` overrides that script has carried since Phase 5 for this exact caller. Phase 5's D4 wrote it as a shell script rather than a pytest suite so that this phase could run the identical command; this phase does.

#### D13 — `push-image.sh` is factored out of `seed-ecr.sh`

The build needs to push the OCI archive to ECR and assert the digest survived. `scripts/seed-ecr.sh` already does exactly that, correctly, with a measured argument for using skopeo over `docker push` and a measured argument for passing the ECR token by name rather than by value. It also writes **both** SSM parameters, which D9 says this phase must not do at build time.

So the skopeo copy, the already-seeded check and the digest assertion move to **`scripts/push-image.sh`**, which takes the repository URL from `$BGD_ECR_REPOSITORY_URL` when set and from `terraform output` otherwise — the same override shape `scripts/smoke.sh` has carried since Phase 5, and it is what lets the build push without needing the state backend. `seed-ecr.sh` becomes: call `push-image.sh`, then record both parameters. `make seed-ecr` behaves identically.

The alternative — a second copy of the skopeo invocation in a build script — would put the two measured arguments in two places, where one can be fixed and the other forgotten.

Three helpers `pipeline-terraform.sh` already has and `pipeline-deploy.sh` needs identically — `build_url`, `write_vars` and the plan-summary formatting — move to `scripts/lib/common.sh` for the same reason `image_build_identity` lives there: two scripts that must not derive the same value differently.

#### D14 — The trigger watches `app/**` plus this pipeline's own executable content, and Phase 7's narrows

Phase 7's D12 argued that a pipeline should redeploy when its own buildspecs change, and excluded `scripts/**` as a whole because the directory also holds this phase's build scripts. The same rule applied here gives:

```
app/**
pipelines/app-*.yml
scripts/build-image.sh
scripts/generate-sbom.sh
scripts/push-image.sh
scripts/pipeline-app-build.sh
scripts/pipeline-deploy.sh
scripts/smoke.sh
scripts/install-terraform.sh
scripts/tf.sh
scripts/lib/common.sh
```

And it forces **two** changes to Phase 7's trigger, both one-liners:

- **`pipelines/**` narrows to `pipelines/infra-*.yml`, and `scripts/pipeline-*.sh` to `scripts/pipeline-terraform.sh`.** F4 — as written, both globs match files this phase creates, so every application-buildspec edit would fire a four-approval infrastructure deployment. The naming was chosen to make this a two-line fix.
- **`scripts/tf.sh` joins it.** A gap in Phase 7 rather than a consequence of this phase: `tf.sh` is run by every plan and every apply in that pipeline, so by D12's own argument it is the pipeline's executable content and always was. Found while writing this list, fixed here, and recorded as a Phase 7 amendment rather than folded in silently.

`scripts/install-terraform.sh`, `scripts/tf.sh` and `scripts/lib/common.sh` appear in **both** pipelines' filters, deliberately. Each is run by both, and a change to `die()` or to the pinned Terraform version changes what every stage of both does.

`DetectChanges = "false"` on the source action, for Phase 7 D13's reason unchanged: `true` creates a second, unfiltered webhook that would run this pipeline on an `infra/`-only commit while the trigger block sat beside it looking as though it were working.

#### D15 — `execution_mode = "QUEUED"`

Phase 7's D11, and it matters more here. This pipeline's executions wait on a human approval and then run an apply that blocks through a five-minute bake. `SUPERSEDED` — the V2 default — would cancel a run mid-bake when a second `app/**` merge lands, leaving production in a half-shifted state that nothing is watching. `PARALLEL` is worse: two applies of the prod layer contend on one state lock.

#### D16 — Build outputs are kept; CodePipeline's own artifacts are expired

Design §4.2 wants the SBOM and the test reports kept as history — "an SBOM for the image running in production three deployments ago". CodePipeline's own artifacts are a clone reference and one saved plan per execution, and they are worth nothing the day after the run.

Two prefixes, two fates:

- `app-builds/<tag>/` — SBOM, coverage XML, JUnit XML, `build-metadata.json`. Written by the build, covered only by the bucket-wide *noncurrent* version rule, so current versions live indefinitely. This is the design's requirement.
- `bgd-us-east-1-app-pipeline/` — CodePipeline's store. Gets its own prefix-scoped expiry rule, exactly like the one Phase 7 added for the infra pipeline and for the same reason: every execution writes under a fresh key, so those objects are all current versions forever and the existing noncurrent-only rule matches none of them.

#### D17 — No notification, and no `on_failure` conditions

Phase 7's D16, unchanged. Phase 9 owns notification and attaches to this pipeline's execution state changes through EventBridge, exactly as it attaches to Phase 6's alarms and Phase 7's pipeline. Adding an SNS action here would put notification in two places for Phase 9 to reconcile.

---

## 1. Findings recorded before this plan was written

### F1 — The standard ECS deploy action replaces image URIs and nothing else

The CodePipeline **ECS** deploy action (`owner = "AWS"`, `provider = "ECS"`) consumes an `imagedefinitions.json` of the form `[{"name": "<container>", "imageUri": "<uri>"}]`. It reads the service's **current** task definition revision, substitutes the image URI of each named container, registers the result as a new revision, and updates the service.

Every other field of the container definition — including `environment` — is copied from the previous revision. There is no mechanism on this action to set an environment variable. (`CodeDeployToECS` takes a full `taskdef.json` and can; it is the CodeDeploy path, which design §1.2 and roadmap §0 both discarded, and which the ECS-native blue/green strategy replaces.)

Consequence, and the whole of D2: this project's task definitions carry `BGD_IMAGE_DIGEST` in that environment, so the action would produce a revision whose image and whose self-reported digest disagree. `scripts/smoke.sh` would fail its fourth check on every deployment, and `/version` — the blue/green evidence surface — would be wrong in production.

**The finding is not that the action cannot drive blue/green.** It can; design §1.5 is right about that. The finding is that it cannot deploy *this* application, for a reason that predates blue/green and comes from Phase 2's discovery that an image cannot contain its own digest.

### F2 — A `CODE_ZIP` source artifact has no `.git`, and three build inputs come from git

`scripts/lib/common.sh:156`, `image_build_identity()`:

```bash
GIT_SHA="$(git -C "$root" rev-parse --short=7 HEAD)"
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then GIT_SHA="${GIT_SHA}-dirty"; fi
SOURCE_DATE_EPOCH="$(git -C "$root" log -1 --format=%ct)"
BUILT_AT="$(TZ=UTC git -C "$root" log -1 --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format=%cd)"
```

In a `CODE_ZIP` workspace `git rev-parse` fails, `set -euo pipefail` aborts the script, and the build fails — loudly, which is the good case. The bad case is someone "fixing" it with a fallback to `CODEBUILD_RESOLVED_SOURCE_VERSION` and the wall clock, which would compile and would silently end the reproducibility property Phase 2 measured: `SOURCE_DATE_EPOCH` from the clock means two builds of one commit produce two digests.

`CODEBUILD_CLONE_REF` (D8) gives the build a real clone. Only `HEAD` is read, so even a depth-1 clone satisfies all four lines.

### F3 — CodeBuild's ARM standard image has no Python 3.14

`aws/codebuild/amazonlinux-aarch64-standard:3.0` provides Python 3.11 and 3.12 as managed runtimes. `.python-version` pins `3.14.6`, and `scripts/create-venv.sh` accepts a PATH interpreter **only** when `extract_version` matches the pin exactly — deliberately, per Phase 1's F1. So `make deps`, and therefore `make test`, cannot run in this build container. D10 is the answer.

This is worth stating rather than working around quietly, because the same fact will reach Phase 9: a metrics Lambda written in Python cannot assume 3.14 either, and Phase 0 already recorded that Lambda's newest managed runtime lags the container's.

### F4 — Phase 7's trigger would fire on an application buildspec change

`infra/foundation/codepipeline.tf:65` filters on `["infra/**", "pipelines/**", "scripts/pipeline-*.sh", "scripts/install-terraform.sh"]`.

Two of those four match files this phase creates. `pipelines/**` matches `pipelines/app-build.yml`; `scripts/pipeline-*.sh` matches `scripts/pipeline-app-build.sh` and `scripts/pipeline-deploy.sh`. Left alone, every application-pipeline edit would start a four-approval infrastructure deployment alongside the application deployment it was meant to start.

The fix is two lines in Phase 7's trigger — `pipelines/infra-*.yml` and `scripts/pipeline-terraform.sh` in place of the two globs.

A third line joins them, and it is a pre-existing gap rather than something this phase caused: **`scripts/tf.sh` is absent from that list and should not be.** Every plan and every apply in the infra pipeline runs it, so by the same D12 argument that put `install-terraform.sh` there, it is the pipeline's executable content. Nobody noticed because `tf.sh` has not changed since Phase 3. All three lines are Phase 7 amendments, recorded as such in Task 12 rather than folded into this phase's file silently.

### F5 — `CODEBUILD_BUILD_NUMBER` is per project, which makes the tag monotonic

`image_build_identity` builds `APP_VERSION` as `<VERSION file>.${CODEBUILD_BUILD_NUMBER:-0}` and the tag as `<APP_VERSION>-<short sha>`. CodeBuild's build number is a per-project counter starting at 1, so with `app-image` as the only project that builds images, tags increase monotonically across the project's life: `0.1.7-a3f9c21`, `0.1.8-…`.

Locally the variable is unset and the fallback is `0`, so a laptop artifact is `0.1.0-<sha>` — and `-dirty` on an unclean tree. A local build can therefore never be mistaken for a pipeline build, which is Phase 2's stated intent and is now load-bearing: it is what stops a hand-built image being pushed under a tag the pipeline would later want.

### F6 — Two runs on the same commit produce two tags and one digest, and ECR accepts that

ECR tag immutability prevents **moving** an existing tag; it does not prevent adding a new tag to a manifest already in the repository. Two pipeline runs on the same commit differ only in `CODEBUILD_BUILD_NUMBER`, so they produce different tags and — by Phase 2's measurement — the identical manifest digest. The second push adds a tag and uploads no layers.

`push-image.sh` inherits `seed-ecr.sh`'s already-pushed check, which queries by tag, finds nothing for the new tag, and pushes. The `-dirty` refusal is inherited too, and in the pipeline it is unreachable — a clone of a commit is never dirty — which is the correct place for a guard that costs nothing.

### F7 — The makefile's `AWS_PROFILE` guard already covers these builds

Phase 7's F6 made the export conditional on `CODEBUILD_BUILD_ID`. Every build in this phase sets that variable, so any `make` target these buildspecs run falls back to the service role rather than failing with `The config profile could not be found`. Nothing to do; recorded because this phase is the first whose builds actually *do* call AWS through `make`-adjacent paths, which is the situation Phase 7's note said was coming.

### F8 — `tf.sh` passes arguments through, so no new Terraform driver is needed

`scripts/tf.sh` ends with `terraform -chdir="$dir" "$command" ${@+"$@"}` and selects a real backend for `plan`, `apply` and `destroy`. So `pipeline-deploy.sh` can drive it exactly as `pipeline-terraform.sh` does:

```bash
scripts/tf.sh apply staging -input=false -auto-approve -lock-timeout=5m -var "image_tag=$IMAGE_TAG"
scripts/tf.sh plan  prod    -input=false -lock-timeout=5m -detailed-exitcode -out=pipeline.tfplan -var "image_tag=$IMAGE_TAG"
scripts/tf.sh apply prod    -input=false -lock-timeout=5m pipeline.tfplan
```

The layer-name-to-directory map stays in `tf.sh` and is not copied a fifth time.

### F9 — Every name fits

| Resource | Name | Length | Limit |
|---|---|---|---|
| CodePipeline | `bgd-us-east-1-app-pipeline` | 26 | 100 |
| CodeBuild project | `bgd-us-east-1-app-deploy-staging-build` | 38 | 255 |
| IAM role | `bgd-us-east-1-app-deploy-staging-role` | 37 | 64 |
| Log group | `/bgd/us-east-1/shared/app-deploy-staging` | 40 | 512 |

The longest of each kind is shown. Convention §2 gives project-wide resources no `<env>` segment; `staging` and `prod` appear here as part of the *purpose* — which environment the build acts on — not as the environment segment, and Task 12 records that reading in the convention so a later reviewer does not "fix" it.

### F10 — checkov will fail this layer again, and the reasons are the same three

Four findings, each already argued once in Phase 3 or Phase 7, each skipped with the argument attached:

- `CKV_AWS_147` on all five projects — SSE-S3 rather than a customer-managed key, Phase 3 §D4.
- `CKV_AWS_338` and `CKV_AWS_158` on all five log groups — 30-day retention and AES256, Phase 7's argument unchanged.
- `CKV_AWS_316` on `app-image` — privileged mode. Required twice over here: `docker buildx` with the `docker-container` driver, which Phase 2 §F1 proved is the only driver that honours `rewrite-timestamp`, and the two containers D10 runs the tests in.
- `CKV_AWS_274` on both deploy roles — `AdministratorAccess`, argued in D6.

A bare skip is not acceptable and none of these is one.

### Findings discovered during implementation

Numbered from F11, recorded in full with their evidence in
[the verification record](./2026-08-30-local-verification.md) §6. Summarised
here so this document is not left describing a plan the implementation departed
from.

- **F11 — `file_paths.includes` accepts eight patterns, and D14's list has
  eleven.** Attribute-level provider validation that runs at plan, not a
  `max_items` in the schema, so `terraform validate` misses it. Every available
  glob consolidation over-matches into the other pipeline's files, re-creating
  F4 in reverse. The trigger allows **three** `push` filters and ORs them, so
  the list is split across two — with the trap that each must repeat the branch
  filter, since one that omits `branches` matches every branch.
- **F12 — `ARM_CONTAINER` offers SMALL and LARGE, not MEDIUM.** Which sizes a
  region accepts is not in the provider schema. `var.app_build_compute_type`
  defaults to `SMALL` with a validation block refusing anything else; `LARGE` is
  the escalation.
- **F13 — the smoke role cannot satisfy D6 and D8 in one policy.** D6 asserts
  nothing outside `logs:` and `s3:`; D8 requires
  `codeconnections:UseConnection`, because the smoke build clones too. Split
  into two policy resources rather than relaxing the assertion — the honest
  restatement of D6 is that the smoke build reads no account state and describes
  no resource, and makes exactly one API call, to clone.
- **F14 — `seed-ecr.sh`'s `--profile` default would have failed every call in
  CodeBuild.** `AWS_PROFILE` is unset there by Phase 7 §F6's own design, and no
  such profile exists. `push-image.sh` mirrors the makefile's
  `CODEBUILD_BUILD_ID` rule rather than re-deciding it.
- **F15 — the test container needs two different DynamoDB endpoint variables.**
  `BGD_TEST_DYNAMODB_ENDPOINT` container-wide for the contract suite;
  `BGD_DYNAMODB_ENDPOINT_URL` scoped to `create_tables` alone, because
  `test_config.py` asserts the *default* is null. Setting one for both costs 28
  failures that all look like an unreachable database. The split
  `.github/workflows/pr-validate.yml` already makes.
- **F16 — Phase 7's two test files need `override_resource` for this phase's six
  roles.** `command = apply` applies the whole module, so the new projects
  validate `service_role` there too. Phase 9 will need the same three lines.

---

## 2. Global constraints

Restating the ones this phase breaks if it gets them wrong, with the symptom attached.

| Constraint | Symptom if missed |
|---|---|
| `OutputArtifactFormat = "CODEBUILD_CLONE_REF"` | `image_build_identity` aborts on `git rev-parse`. Loud — or, if "fixed" with a clock fallback, silent, and reproducibility ends (F2, D8). |
| `codeconnections:UseConnection` on every role taking the source artifact | The clone fails with an access-denied message naming the connection, not the role. |
| `ARM_CONTAINER` on `app-image` only | An x86 build produces an amd64 manifest. It pushes cleanly and the ECS task fails at start with an exec format error (Phase 2 amendment, Phase 5 §ecs.tf). |
| The SSM write happens **after** the apply | An `infra/**` merge landing mid-run deploys the new image to production with no approval, all stages green (D9). |
| Prod's `input_artifacts` on Apply is the Plan action's `output_artifacts` | Apply re-plans and the approval approved something else. No error at any point (Phase 7 D9). |
| `terraform apply <planfile>` gets no `-var` | `Can't set variables when applying a saved plan`. Loud and immediate. |
| `-auto-approve` on the staging apply, and only there | Without it the apply blocks on a prompt until the 60-minute timeout. With it on prod, D11's approval becomes decorative. |
| `DetectChanges = "false"` | A second unfiltered webhook: every `infra/`-only commit runs the app pipeline. `terraform plan` stays clean forever (Phase 7 D13). |
| Phase 7's trigger narrowed to `pipelines/infra-*.yml` | Every app buildspec edit fires a four-approval infra deployment (F4). |
| `execution_mode = "QUEUED"` | A second merge cancels the first run, possibly mid-bake, leaving a half-shifted production service (D15). |
| The scope check runs before the saved-plan check in `apply` mode | An out-of-scope apply dies with `no saved plan` instead of reporting `skipped`, turning a correct skip into a red stage. Phase 7's ordering, repeated. |
| Policies built with `jsonencode`, never `aws_iam_policy_document` | `mock_provider` mocks the policy-document data source too. The policy becomes a random string under test and every assertion on it is vacuous. Phase 5 §F1. |
| The five log groups exist before the projects reference them | CodeBuild creates them itself without retention, and F10's skip applies to nothing. |
| `app-builds/` is **not** covered by the pipeline-prefix expiry rule | The SBOMs design §4.2 requires as history are deleted after 30 days (D16). |

**`on_failure`, `on_success` and `pull_request` triggers are deliberately unused,** for Phase 7's reason unchanged. A `pull_request` trigger here is more tempting than it was there and worse: it would build and push an image from an unmerged branch into the registry production deploys from.

---

## 3. File structure

```
infra/foundation/
  variables.tf              MODIFIED  four new variables
  locals.tf                 MODIFIED  the app scope table, the app exported-variable names
  iam-app-pipeline.tf       NEW       six roles: pipeline, image, deploy-staging,
                                      smoke, plan-prod, deploy-prod
  codebuild-app.tf          NEW       five projects and their five log groups
  codepipeline-app.tf       NEW       the pipeline: five stages, the variable, the trigger
  codepipeline.tf           MODIFIED  the trigger narrows to pipelines/infra-*.yml (F4)
  artifacts.tf              MODIFIED  a prefix-scoped lifecycle rule for app pipeline artifacts
  outputs.tf                MODIFIED  app pipeline name and ARN, the two deploy role ARNs
  README.md                 MODIFIED  the layer now owns two pipelines
  tests/
    app_pipeline_shape.tftest.hcl  NEW  stages, order, artifacts, trigger, variable, conditions
    app_pipeline_iam.tftest.hcl    NEW  what each of the six roles can and cannot do
    pipeline_shape.tftest.hcl      MODIFIED  the infra trigger's narrowed patterns

pipelines/
  app-build.yml             NEW       install nothing; run the build script
  app-deploy.yml            NEW       install terraform; deploy one environment
  app-smoke.yml             NEW       run smoke.sh against the URL passed in
  app-plan.yml              NEW       install terraform; plan prod; source the vars
  app-apply.yml             NEW       install terraform; apply the saved plan
  README.md                 MODIFIED  the app buildspecs exist now

scripts/
  lib/common.sh             MODIFIED  build_url, write_vars, plan_summary move here (D13)
  push-image.sh             NEW       the skopeo push and the digest assertion, factored out
  seed-ecr.sh               MODIFIED  calls push-image.sh; still records both parameters
  pipeline-app-build.sh     NEW       tests, image, SBOM, push, reports, exported variables
  pipeline-deploy.sh        NEW       scope gate, plan/apply an environment, record the tag
  pipeline-terraform.sh     MODIFIED  uses the helpers now in lib/common.sh
  README.md                 MODIFIED  the three new scripts

makefile                    MODIFIED  a push-image target (Task 4)

docs/
  runbooks/phase-08-app-pipeline.md              NEW
  runbooks/README.md                             MODIFIED  the row that says "planned"
  phases/phase8/
    2026-08-30-phase-08-implementation-plan.md   this document
    2026-08-30-local-verification.md             NEW  the evidence record
  naming-and-tagging-convention.md               MODIFIED  F9's reading of §2 recorded
  2026-08-04-implementation-phase-roadmap.md     MODIFIED  the Phase 8 amendment,
                                                           and a note on Phase 7's trigger
  2026-08-04-blue-green-deployment-platform-design-research.md
                                                 MODIFIED  §1.5 and §6: the ECS action is not
                                                           used, and why. §8.1: nine roles are
                                                           fifteen.
```

**Why these boundaries.** `codepipeline-app.tf` beside `codepipeline.tf` rather than inside it: the two pipelines share a connection, a bucket and a layer, and nothing else — not a stage, not a role, not a buildspec. A reader asking "what happens when I merge an app change" should find one file that answers it.

`iam-app-pipeline.tf` beside `iam-pipeline.tf` for the reason Phase 7 gave for the first name: these are the *app* pipeline's roles, and Phase 9 will add a third set.

The two test files split the way the risk does, as Phase 7's do. `app_pipeline_shape.tftest.hcl` protects wiring that a plan review cannot see — stage order, `run_order` inside a stage, which artifact feeds which action, whether the buildspec still exports the variable name the approval interpolates. `app_pipeline_iam.tftest.hcl` protects D6's two boundaries, and it is the file that has to say no when someone gives the smoke build "just one read" or merges the two deploy roles.

`push-image.sh` is separate from `pipeline-app-build.sh` because `seed-ecr.sh` needs it too and a pipeline script is the wrong home for something a laptop runs.

---

## 4. Tasks

Twelve tasks. Tests precede implementation throughout, which for Terraform means the `.tftest.hcl` file is written and **seen to fail** before the resources it asserts on exist.

Every task ends with its suite passing and a commit **proposed for approval, never made automatically**. The full gate — `make tf-check` — runs at Task 9 and again at Task 12.

---

### Task 1: Variables, locals and the app scope table

First, because every later task reads them: the roles interpolate the log group ARNs, the pipeline iterates the scope table, and both test files compare against the exported-variable names.

**Files:**
- Modify: `infra/foundation/variables.tf`
- Modify: `infra/foundation/locals.tf`
- Test: `infra/foundation/tests/app_pipeline_shape.tftest.hcl`

**Interfaces:**
- Produces: `var.app_scope_default`, `var.app_build_compute_type`, `var.app_artifact_prefix`, `var.app_pipeline_artifact_retention_days`; `local.app_scope_conditions` (a map keyed by stage), `local.app_plan_exported_variables`, `local.app_build_exported_variables`.
- Consumed by: Tasks 2, 3, 6, 7, 8, 9.

- [x] **Step 1: Write the failing assertions first**

Create `infra/foundation/tests/app_pipeline_shape.tftest.hcl` with a `mock_provider "aws"` block matching the one in `tests/pipeline_shape.tftest.hcl`, and a first `run` block asserting `local.app_scope_conditions` has exactly the keys `staging` and `prod` with the operators below, and that `local.app_build_exported_variables` contains `IMAGE_TAG` and `IMAGE_DIGEST`.

Run `./scripts/tf.sh test foundation` and **see it fail** on the undefined locals.

- [x] **Step 2: Add the four variables**

Append to `infra/foundation/variables.tf`. `app_scope_default` takes the same validation shape as `deploy_scope_default`, listing `build`, `staging`, `all`, and its description states the cumulative reading and F4 of Phase 7 — a git-triggered run supplies no variables, so every merge takes this default.

- [x] **Step 3: Add the locals**

Append to `infra/foundation/locals.tf`.

**A map here, where `pipeline_layers` is a list, and the difference is not an inconsistency.** `pipeline_layers` is *iterated* to build four structurally identical stages, so its order is the pipeline's order and a map would have put `prod` before `staging`. This one is only ever **looked up** by two stages that Task 9 writes out explicitly, because they are not structurally identical — staging holds Deploy and Smoke, production holds Plan, Approve and Apply. Nothing iterates it, so nothing can be reordered by it. The comment in the file says exactly this, because "the file next door used a list" is the first objection a reviewer will raise.

```hcl
locals {
  # Looked up by the two deploy stages, never iterated — see the note above.
  # staging runs under two of the three scopes and prod under one, which is why
  # staging takes a regex and prod an equality: a condition's rules are ANDed,
  # and there is no arrangement of EQ and NE that expresses "two of three".
  # The same reasoning pipeline_layers records for `network`.
  app_scope_conditions = {
    staging = { operator = "MATCHES", value = "^(staging|all)$" }
    prod    = { operator = "EQ", value = "all" }
  }

  # The names pipelines/app-build.yml exports and the later stages interpolate
  # as #{Build.IMAGE_TAG}. Declared here so a test can assert the buildspec
  # still exports them — a renamed variable does not fail anything, it makes
  # every downstream action receive the literal string "#{Build.IMAGE_TAG}"
  # and try to deploy it as a tag.
  # tflint-ignore: terraform_unused_declarations
  app_build_exported_variables = ["IMAGE_TAG", "IMAGE_DIGEST"]

  # tflint-ignore: terraform_unused_declarations
  app_plan_exported_variables = ["PLAN_STATUS", "PLAN_SUMMARY", "PLAN_URL"]
}
```

- [x] **Step 4: See the test pass**

`./scripts/tf.sh test foundation`, then `terraform fmt`.

**Verification:** `./scripts/tf.sh test foundation` green; `make tf-fmt-check` green.

---

### Task 2: The six IAM roles

Before the projects, because `service_role` interpolates these ARNs. Written test-first, and the test is the point: D6's two boundaries are exactly the kind that erode without one.

**Files:**
- Create: `infra/foundation/iam-app-pipeline.tf`
- Test: `infra/foundation/tests/app_pipeline_iam.tftest.hcl`

**Interfaces:**
- Produces: `aws_iam_role.app_pipeline`, `.app_image`, `.app_deploy_staging`, `.app_smoke`, `.app_plan_prod`, `.app_deploy_prod`, and their policies.
- Consumed by: Tasks 3 and 6.

- [x] **Step 1: Write `app_pipeline_iam.tftest.hcl` and see it fail**

The assertions, each protecting a decision rather than a line:

| Assertion | Protects |
|---|---|
| The smoke role's policy contains no `Action` outside the `logs:` and `s3:` prefixes | D6's no-credentials property |
| `app_deploy_staging` and `app_deploy_prod` are two distinct role ARNs | D6's structural separation |
| The image role's policy contains no `ssm:PutParameter` | D9 — the build must not record a tag |
| The image role's ECR grant names `aws_ecr_repository.api.arn`, not `*` | least privilege where it is achievable |
| The four roles whose projects consume the source artifact — image, deploy-staging, smoke, plan-prod — grant `codeconnections:UseConnection` on the connection ARN, and `app_deploy_prod` does not | D8's clone requirement, and that the one action consuming a plain S3 artifact needs no repository access |
| The pipeline role's `codebuild:StartBuild` names the five project ARNs, not `*` | it cannot start Phase 7's builds |
| `app_plan_prod` has `ReadOnlyAccess` attached and **not** `AdministratorAccess` | D11's approval means something |
| Both deploy roles' trust policies carry the `aws:SourceAccount` condition | the only narrowing on an administrator role |

- [x] **Step 2: Write the roles**

Header comment states D5's forcing fact, D6's two ends, and the `jsonencode`-not-`aws_iam_policy_document` rule with its Phase 5 §F1 reference. Reuse `local.codebuild_assume_role_policy` and `local.codepipeline_assume_role_policy` from `iam-pipeline.tf` — they are already in the layer and already carry the account condition.

Every `Action` and `Resource` written as a **list** even when it holds one element, matching `iam-pipeline.tf`, so the tests can use `contains()` without a type check.

- [x] **Step 3: See the suite pass**

**Verification:** `./scripts/tf.sh test foundation` green, both new files' runs included.

---

### Task 3: The five CodeBuild projects and their log groups

**Files:**
- Create: `infra/foundation/codebuild-app.tf`
- Test: `infra/foundation/tests/app_pipeline_shape.tftest.hcl` (extend)

**Interfaces:**
- Produces: five `aws_codebuild_project` and five `aws_cloudwatch_log_group`.
- Consumed by: Task 6.

- [x] **Step 1: Extend the shape suite and see it fail**

Assert: `app_image` is `ARM_CONTAINER` with `privileged_mode = true`; the other four are `LINUX_CONTAINER` with `privileged_mode` unset or false; `app_deploy_prod.build_timeout` is 60; each project's `source.buildspec` names the file Task 8 creates; each project's `logs_config` names its own group.

The `ARM_CONTAINER` assertion is worth its line: an x86 build pushes cleanly and fails at task start, minutes later, with a message about exec format (Phase 2's amendment).

- [x] **Step 2: Write the projects**

Five log groups first — `/bgd/${var.region}/shared/app-<purpose>` — with the two checkov skips F10 lists, then the five projects. `build_timeout`: 30 for `app-image` (a cold ARM build plus two container pulls), 20 for `app-smoke`, 30 for `app-deploy-staging` and `app-plan-prod`, **60 for `app-deploy-prod`** with the comment Phase 6 §D11 earned — `wait_for_steady_state` means the apply blocks through provisioning, three hooks, the shift and a five-minute bake, and this timeout should not be what decides the deployment went badly.

- [x] **Step 3: See the suite pass**

**Verification:** `./scripts/tf.sh test foundation` green.

---

### Task 4: `push-image.sh`, and `seed-ecr.sh` reduced to its caller

The first script task, and it is a refactor with no behaviour change — done before the new scripts so `pipeline-app-build.sh` is written against the final interface.

**Files:**
- Create: `scripts/push-image.sh`
- Modify: `scripts/seed-ecr.sh`
- Modify: `scripts/README.md`
- Modify: `makefile`

**Interfaces:**
- Produces: `scripts/push-image.sh`, reading `$BGD_ECR_REPOSITORY_URL` when set; `make push-image`.
- Consumed by: `seed-ecr.sh`, Task 5's build script.

- [x] **Step 1: Move the push into `push-image.sh`**

Everything from `seed-ecr.sh` between the `dist/` preconditions and `record_image_tag_parameters`, unchanged: the `-dirty` refusal, the already-pushed check, the exported-then-passed-by-name `DEST_PASSWORD` with its measured `ps` comment, the skopeo invocation with its escaped `\$DEST_PASSWORD`, and the digest assertion.

The one change is where the repository URL comes from:

```bash
# Terraform is required only where it is used, not unconditionally — the same
# placement, and the same reason, as scripts/smoke.sh. A CodeBuild build that
# supplies this value directly has no state backend to read and legitimately no
# terraform binary; requiring one would fail that caller for nothing.
REPO_URL="${BGD_ECR_REPOSITORY_URL:-}"
if [[ -z "$REPO_URL" ]]; then
  require_cmd terraform
  REPO_URL="$(terraform -chdir="$ROOT/infra/foundation" output -raw ecr_repository_url 2>/dev/null)" ||
    die "cannot read the foundation outputs — apply the foundation layer first, or set BGD_ECR_REPOSITORY_URL"
fi
```

It writes `TAG` and the pushed digest to stdout in a form the caller can read, and exits 0 on the already-seeded path exactly as before.

- [x] **Step 2: Reduce `seed-ecr.sh`**

It becomes: call `push-image.sh`, then `record_image_tag_parameters`. The function stays in `seed-ecr.sh` — it is the local seeding path's business and D9 says the pipeline must not do it. The header comment gains a sentence saying where the push went and why.

- [x] **Step 3: Add `make push-image`**

Under the Phase 8 heading, with a comment saying it is `seed-ecr` without the SSM writes, for the case where you want an image in the registry that nothing is yet deploying.

- [x] **Step 4: Verify no behaviour changed**

`bash -n` on both. `shellcheck` if present. Then, without an AWS session, run `./scripts/seed-ecr.sh` and confirm it fails at the same point with the same message as before the refactor — which for a machine with no `app/dist` is the `no image archive` precondition, and the record goes in the verification document either way.

**Verification:** `bash -n scripts/push-image.sh scripts/seed-ecr.sh`; `make help` lists `push-image`.

---

### Task 5: The shared helpers move to `lib/common.sh`

**Files:**
- Modify: `scripts/lib/common.sh`
- Modify: `scripts/pipeline-terraform.sh`

**Interfaces:**
- Produces: `build_url`, `write_vars`, `plan_summary` in `lib/common.sh`.
- Consumed by: `pipeline-terraform.sh` (existing behaviour preserved), Task 7's `pipeline-deploy.sh`.

- [x] **Step 1: Move the three helpers**

`build_url` and `write_vars` move verbatim, comments included. The plan-summary formatting — `terraform show` filtered to `Plan:` and `  # ` lines, then the newline squeeze and the 900-character truncation — becomes `plan_summary <dir> <planfile>`, because Phase 7's version is inline in two places in one script and this phase needs a third.

A header comment above them states why they are here: the same rule `image_build_identity` already carries — two scripts that must not derive the same value differently.

- [x] **Step 2: Rewrite `pipeline-terraform.sh` to call them**

No behaviour change. The file gets shorter and the `Phase 8 uses these too` note replaces the local definitions.

- [x] **Step 3: Re-run Phase 7's scope-gate matrix**

The nine cases from the Phase 7 verification record, re-executed against the refactored script, and the output copied into this phase's verification document. A refactor of the file that holds the second of two safety gates is not verified by reading it.

**Verification:** `bash -n` on both; the nine-case matrix reproduces Phase 7's recorded output exactly.

---

### Task 6: `pipeline-app-build.sh` — test, build, SBOM, push, publish

The longest script in the phase, and the one where D10 lives.

**Files:**
- Create: `scripts/pipeline-app-build.sh`
- Modify: `scripts/README.md`

**Interfaces:**
- Produces: an image in ECR, an SBOM and two reports in `s3://<artifacts>/app-builds/<tag>/`, and `build-vars.env` holding `IMAGE_TAG` and `IMAGE_DIGEST`.
- Consumed by: `pipelines/app-build.yml`, and through the exported variables, every later stage.

- [x] **Step 1: The test run**

```bash
NETWORK="bgd-build-$$"
docker network create "$NETWORK" >/dev/null
docker run -d --name "dynamodb-$$" --network "$NETWORK" "$DYNAMODB_LOCAL" \
  -jar DynamoDBLocal.jar -sharedDb -inMemory >/dev/null
```

`$DYNAMODB_LOCAL` and `$PYTHON_IMAGE` are digest pins recorded at the top of the file with the same "re-record with" comment `generate-sbom.sh` and `seed-ecr.sh` carry, and both are copied from files already in the repository — `app/docker-compose.yml` and `app/Dockerfile` — with a comment saying so, because a third pin that can drift from the other two is worse than no pin.

Then one container run that installs the locks, creates the tables and runs pytest with the report flags this phase adds:

```bash
docker run --rm --network "$NETWORK" \
  --volume "$ROOT:/src" --workdir /src/app \
  --env PYTHONPATH=src \
  --env "BGD_DYNAMODB_ENDPOINT_URL=http://dynamodb-$$:8000" \
  "$PYTHON_IMAGE" sh -c '
    pip install --quiet --require-hashes -r requirements-dev.txt &&
    python -m bgd.cli.create_tables &&
    python -m pytest --cov-report=xml:dist/coverage.xml --junitxml=dist/junit.xml'
```

A `trap` removes the container and the network on every exit path, including the failing one — a leaked container is invisible in CodeBuild and a real annoyance in a local debugging run.

- [x] **Step 2: The image, the SBOM and the push**

`./scripts/build-image.sh`, `./scripts/generate-sbom.sh`, `./scripts/push-image.sh` in that order, each already written and already the command the laptop runs. The script's own contribution is only the environment: `BGD_ECR_REPOSITORY_URL` from an action-level variable, so no Terraform state is read.

- [x] **Step 3: Publish the reports**

`aws s3 cp` of `sbom.spdx.json`, `coverage.xml`, `junit.xml` and a generated `build-metadata.json` to `s3://$BGD_ARTIFACT_BUCKET/app-builds/$TAG/`. The metadata file holds the tag, the digest, the git SHA, the build number and the build URL — the four things you want when asking, months later, what produced the image production is running.

- [x] **Step 4: Export the two variables**

`IMAGE_TAG` and `IMAGE_DIGEST` written to `build-vars.env` for the buildspec to source, in the `printf '%q'` form Phase 7's `write_vars` uses. Add `build-vars.env` to `.gitignore` beside `plan-vars.env`, with the same comment.

**Verification:** `bash -n`; the script run locally end-to-end with `BGD_ECR_REPOSITORY_URL` pointed at nothing and the push step stubbed, confirming the test and build phases produce both reports and the two variables.

---

### Task 7: `pipeline-deploy.sh` — the scope gate, the deploy, and the record

**Files:**
- Create: `scripts/pipeline-deploy.sh`
- Modify: `scripts/README.md`

**Interfaces:**
- Produces: three modes — `deploy <env>`, `plan <env>`, `apply <env>`.
- Consumed by: `pipelines/app-deploy.yml`, `app-plan.yml`, `app-apply.yml`.

- [x] **Step 1: The scope gate**

`scope_rank` over `build|staging|all` and `env_rank` over `staging|prod`, the same shape as `pipeline-terraform.sh`'s and for the same reason — the scope names where a run stops, so a rank comparison is the whole rule. An unrecognised scope ranks 0 and is rejected by name rather than behaving like a silent `build`.

The gate runs **before** the saved-plan check in `apply` mode. Phase 7's ordering comment applies verbatim and is repeated here rather than referenced, because getting it backwards turns a correct skip into a red stage.

- [x] **Step 2: `deploy` — staging**

Requires `IMAGE_TAG`, refuses an empty or `unset` value by name, then:

```bash
"$ROOT/scripts/tf.sh" apply "$env" -input=false -auto-approve -lock-timeout=5m -var "image_tag=$IMAGE_TAG"
```

Then, **and only after that returns 0**, `aws ssm put-parameter --overwrite` on `/bgd/$env/image_tag`. D9's whole point, and the script says so in a comment at the call rather than only in this document.

Then export `SMOKE_URL` and `SMOKE_DIGEST` from `terraform output -raw api_url` and `image_digest`, so the smoke action needs no AWS access (D6).

- [x] **Step 3: `plan` — prod**

`-detailed-exitcode -out=pipeline.tfplan` with the new tag, the exit-code 0/2/other handling Phase 7 wrote, and `write_vars` with `plan_summary` from `lib/common.sh`. The skip path writes `PLAN_STATUS=skipped` with a summary naming the scope, so the approval message cannot show the previous execution's plan.

- [x] **Step 4: `apply` — prod**

The saved plan, no `-var`, then the SSM write on success. The stale-plan failure mode gets the comment Phase 7's has: it means the layer's state moved between plan and apply, almost always a local `make apply-prod` racing the pipeline, and failing is correct.

**Verification:** `bash -n`; the full scope matrix executed and recorded — three scopes × two environments × three modes, with `DEPLOY_SCOPE` unset and with a junk value, confirming every skip reports `skipped` and every rejection names the variable.

---

### Task 8: The five buildspecs

**Files:**
- Create: `pipelines/app-build.yml`, `app-deploy.yml`, `app-smoke.yml`, `app-plan.yml`, `app-apply.yml`
- Modify: `pipelines/README.md`

- [x] **Step 1: Write them**

Each stays short and delegates, matching the convention the makefile states and Phase 7's D17 repeats. `app-build.yml` installs nothing — Docker is in the image and the two containers carry everything else — and sources `build-vars.env` under `set -a` exactly as `infra-plan.yml` sources `plan-vars.env`, with the same comment explaining that the script is a child process whose exports do not reach the shell.

`app-build.yml`, `app-deploy.yml` and `app-plan.yml` declare `exported-variables`. `app-plan.yml` publishes the workspace as its artifact with `.terraform/` excluded and the re-init comment `infra-plan.yml` carries.

- [x] **Step 2: Assert the exported names in the shape suite**

Extend `app_pipeline_shape.tftest.hcl` to read each buildspec with `yamldecode(file(...))` and assert its `env.exported-variables` still equals `local.app_build_exported_variables` / `local.app_plan_exported_variables`. A renamed variable fails nothing at apply — it makes the approval show a literal `#{PlanProd.PLAN_SUMMARY}` and the deploy receive the literal `#{Build.IMAGE_TAG}` as a tag. This test is the only thing that catches it offline.

**Verification:** `python3 -c 'import yaml,sys;[yaml.safe_load(open(f)) for f in sys.argv[1:]]' pipelines/app-*.yml`; `./scripts/tf.sh test foundation` green.

---

### Task 9: The pipeline

**Files:**
- Create: `infra/foundation/codepipeline-app.tf`
- Modify: `infra/foundation/codepipeline.tf` (F4)
- Modify: `infra/foundation/tests/pipeline_shape.tftest.hcl`
- Test: `infra/foundation/tests/app_pipeline_shape.tftest.hcl` (extend)

- [x] **Step 1: Extend both shape suites and see them fail**

For the app pipeline: five stages in order; `Build` takes `source` and outputs nothing; `DeployStaging` holds `Deploy` at `run_order = 1` and `Smoke` at `2`; `Prod` holds `Plan`/`Approve`/`Apply` at 1/2/3; `Apply`'s `input_artifacts` is `Plan`'s `output_artifacts`; the trigger's `file_paths.includes` is exactly D14's list; `DetectChanges` is `"false"`; `OutputArtifactFormat` is `"CODEBUILD_CLONE_REF"`; `execution_mode` is `"QUEUED"`.

For the infra pipeline: its `file_paths.includes` no longer contains `pipelines/**` and does contain `pipelines/infra-*.yml`. That assertion is the durable form of F4 — it fails if someone widens it back.

- [x] **Step 2: Write the pipeline**

**Four stages written out explicitly, not a `dynamic "stage"` block.** `codepipeline.tf` iterates `local.pipeline_layers` because its four stages are structurally identical — Plan, Approve, Apply, differing only in a name. These are not: `DeployStaging` holds Deploy and Smoke, `Prod` holds Plan, Approve and Apply. A `dynamic` block over two shapes would need a conditional inside it for every action, which is a worse way to say "these two stages are different" than writing two different stages.

Each of the two deploy stages gets a `before_entry` condition built by looking its operator and value up in `local.app_scope_conditions`, so the scope table stays in one place even though the stages do not share a body.

Two `namespace` attributes are load-bearing and neither defaults: `namespace = "Build"` on the build action, without which `#{Build.IMAGE_TAG}` resolves to nothing, and `namespace = "PlanProd"` on the production plan action. The approval's `CustomData` interpolates `#{PlanProd.PLAN_SUMMARY}` and its `ExternalEntityLink` `#{PlanProd.PLAN_URL}`, with the 1000-character cap comment Phase 7's carries.

Header comment covers: what the pipeline is, D2 in two sentences with a pointer here, why this file's stages are explicit where the file next door's are generated, and the sentence that matters operationally — an `app/**` merge now reaches production behind one approval.

- [x] **Step 3: Narrow the infra trigger**

Two lines in `codepipeline.tf`, and an amendment to its comment saying that `pipelines/**` was narrowed when the app buildspecs arrived, with the reason.

- [x] **Step 4: `make tf-check`**

The full gate, first run. Fix every tflint and checkov finding or skip it with F10's written reason.

**Verification:** `make tf-check` green on a machine with no AWS session.

---

### Task 10: Artifact lifecycle and outputs

**Files:**
- Modify: `infra/foundation/artifacts.tf`
- Modify: `infra/foundation/outputs.tf`
- Modify: `infra/foundation/README.md`

- [x] **Step 1: The lifecycle rule**

A third rule, prefix-scoped to `${local.name_prefix}-app-pipeline/`, mirroring the infra one. The comment states D16's split explicitly: this rule covers CodePipeline's store and **not** `app-builds/`, which design §4.2 wants kept.

Assert in the shape suite that no rule's prefix matches `app-builds/`. That is the assertion that stops a later tidying-up from deleting the SBOM history.

- [x] **Step 2: The outputs**

`app_pipeline_name` and `app_pipeline_arn` (Phase 9's EventBridge rule filters on the name), `app_deploy_staging_role_arn` and `app_deploy_prod_role_arn` — "who changed this" is the first question about any resource, and Phase 7's `infra_apply_role_arn` set that precedent.

**Verification:** `./scripts/tf.sh test foundation` green.

---

### Task 11: The runbook

**Files:**
- Create: `docs/runbooks/phase-08-app-pipeline.md`
- Modify: `docs/runbooks/README.md`

- [x] **Step 1: Write it**

Same shape as the Phase 7 runbook. Steps, in order:

1. Prerequisites — Phases 3 to 7's runbooks executed, the connection authorised, an image already seeded.
2. `make plan-foundation` and read the diff — six roles, five projects, five log groups, one pipeline, one lifecycle rule.
3. `make apply-foundation`.
4. Confirm the pipeline exists and has five stages, and that the **infra** pipeline's trigger narrowed as intended.
5. **The exit criterion:** make a real change under `app/`, merge it, and watch the run — build, staging deploy, smoke, approval, production blue/green. What to look at while the bake runs: `/version` on `:443` and `:8443`, and the three hook log groups.
6. `APP_SCOPE=build` and `APP_SCOPE=staging` runs started from the console, each confirmed to leave the later stages `Skipped` rather than `Failed`.
7. Confirm `/bgd/prod/image_tag` holds the new tag **after** the apply, and confirm an `infra/**` run then plans clean — the direct check on D9.
8. Recovery: what to do when the saved plan goes stale, and the local-apply-races-the-pipeline case.
9. What this phase does not cover — notification is Phase 9, rollback evidence is Phase 11.

Each step gets the command, the expected output, and what a failure means.

**Verification:** every command in the runbook is either already verified locally or explicitly marked as needing the session.

---

### Task 12: Amendments and the local verification record

**Files:**
- Modify: `docs/2026-08-04-implementation-phase-roadmap.md`
- Modify: `docs/2026-08-04-blue-green-deployment-platform-design-research.md`
- Modify: `docs/naming-and-tagging-convention.md`
- Create: `docs/phases/phase8/2026-08-30-local-verification.md`

- [x] **Step 1: The roadmap amendment**

Under §3's Phase 8 section, in the established form. It must say plainly:

- **D2**, at length. The task list's "standard ECS deploy action" bullet is not what was built, and F1 is why.
- The five projects and six roles, where the task list implies neither.
- `APP_SCOPE`, which the task list does not mention, and its cumulative table.
- `CODEBUILD_CLONE_REF`, and that the reproducibility requirement is what forces it.
- **Phase 7's trigger narrowed** — recorded in the Phase 7 section as well as this one, because a reader checking Phase 7's file against Phase 7's amendment should find the change accounted for.
- That §2's branch table row 8 reads `feat/Phase8_AppPipeline`, which is the branch used, so **no amendment is needed there** — recorded explicitly, as Phases 3, 5, 6 and 7 did.
- That the exit criterion is not met by the branch alone.

- [x] **Step 2: The design document amendments**

- **§1.5** — the finding stands and is not used here. State the limitation that actually bites: image URIs only, so `BGD_IMAGE_DIGEST` cannot be set, so `/version` and `smoke.sh` would both be wrong. Point at D2.
- **§6** — the app pipeline's diagram gains the plan/approve/apply shape on prod and the smoke action, and loses "Deploy staging" as an ECS action.
- **§8.1** — nine roles become fifteen. The paragraph should make the same point Phase 7's made: the split is what makes the section's stated premise true rather than aspirational, and here the new thing is that two of the six are separated **structurally** rather than by policy, because D6 argues a policy separation between two Terraform-applying roles would be fiction.

- [x] **Step 3: The convention amendment**

F9's reading of §2 — `staging` and `prod` inside these names are part of the purpose, not the `<env>` segment — with the four names as the example.

- [x] **Step 4: The verification record**

`docs/phases/phase8/2026-08-30-local-verification.md`, following Phase 7's. It carries the actual command output for: `make tf-check`, the scope matrix from Task 7, the re-run Phase 7 matrix from Task 5, the buildspec YAML parse, the `bash -n` runs, and the Task 6 local build run. Findings discovered during implementation are numbered `F11` onward and back-referenced from this plan.

- [x] **Step 5: `make tf-check` one final time, and open the pull request**

Description is §5's exit criterion and how each gate was verified, per roadmap §2 step 4.

**Verification:** `make tf-check` green; every claim in the verification record has output beneath it.

---

## 5. Exit criteria

From the roadmap, verbatim:

1. **A commit under `app/` reaches production through the full path, with the blue/green deployment and its hooks firing as designed.**

**It is not met by this branch.** It needs a pipeline that exists, a merge that happened and a deployment that ran, and this session creates no AWS resource (D1). It is met by [the runbook](../../runbooks/phase-08-app-pipeline.md), step 5.

What the branch does gate itself on:

| Check | Command | Covers |
|---|---|---|
| Terraform validity | `make tf-validate` | all five layers parse and typecheck |
| Static analysis | `make tf-lint` | tflint and checkov, every finding fixed or skipped with a reason |
| Behaviour | `make tf-test` | the foundation layer's seven test files; the app pipeline's shape, order, artifact hand-off, trigger, conditions, the six roles' boundaries, and the infra trigger's narrowing |
| Formatting | `make tf-fmt-check` | the check the infra pipeline's Validate stage runs |
| Shell | `bash -n` on five scripts, plus two scope matrices executed | D4's second gate refuses, and Task 5's refactor changed nothing |
| Buildspecs | `yaml.safe_load` on all five | they parse as CodeBuild expects, and their `exported-variables` match the locals |
| Application | `make test`, `make lint`, `make image-verify` | unchanged by this phase, and proved unchanged |

---

## 6. Risks this phase adds

| Risk | Handling |
|---|---|
| **The ECS deploy action is the documented path and this project does not use it** | D2 and F1, argued at length and amended into design §1.5 and §6 rather than left as an undocumented divergence. The property design §1.5 cares about — only images flow — is preserved by mechanism. |
| **`MATCHES` may not be a `VariableCheck` operator** | Phase 7's F2, unresolved offline and now load-bearing in a second pipeline. The script gate (D4) makes being wrong cost an unwanted approval rather than an unwanted production deploy. Runbook step 6 confirms it live, and the fallback is the same ordinal-and-`LTE` change. |
| **`AdministratorAccess` on two more roles** | Accepted, argued in D6, skipped in checkov with the argument attached. The structural separation between staging and prod is the new mitigation; the manual approval is still the real one. |
| **An `app/**` merge now reaches production behind one approval, not four** | Intended — that is the phase. Worth stating because it is a real reduction in friction from Phase 7's shape, and the compensating controls are Phase 6's: the dark canary hook, the bake alarms, and `wait_for_steady_state` making a rollback fail the build. |
| **The build depends on three public registries** | `python:3.14.6-slim`, `amazon/dynamodb-local`, plus syft and skopeo. All digest-pinned, none rate-limit-proof. If the build starts failing on pulls rather than on tests, the fix is an ECR pull-through cache — noted, not built, because it is a cost for a problem that has not happened. Same disposition as Phase 7's note about tflint and checkov. |
| **A production apply blocking for ten minutes inside CodeBuild** | Intended (Phase 6 §D11) and the 60-minute timeout accommodates it. The risk is the operator's: an approval given and then forgotten leaves a stage that looks hung. Runbook step 5 says what to watch while it runs. |
| **`app-builds/` grows without bound** | Deliberate — design §4.2 wants the history, and an SBOM is tens of kilobytes. Revisit if it ever matters; do not add an expiry rule that quietly discards the thing the design asked for. |
| **Phase 9 must not duplicate notification** | D17. This pipeline emits execution state changes and attaches to nothing. Recorded here so Phase 9 inherits it as a requirement rather than discovering two notification paths. |
| **Phase 11 needs a broken image in ECR that nothing deploys** | `APP_SCOPE=build` (D3) is the mechanism, built now rather than improvised then. |
