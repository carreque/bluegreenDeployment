# Phase 7 — Infrastructure pipeline: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-29
**Status:** Proposed, awaiting approval
**Branch:** `feat/Phase7_InfraPipeline`
**AWS cost incurred by this phase as planned:** **$0.** Every deliverable is written and verified locally, against mocked providers and with no AWS session. The apply that creates the pipeline, and both exit-criteria demonstrations, are handed to you as a runbook — see §0.1 D1.
**Companion documents:**
[design research](../../2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 0 findings](../phase0/2026-08-04-phase-00-verification-findings.md) ·
[Phase 3 plan](../phase3/2026-08-24-phase-03-implementation-plan.md) ·
[Phase 6 plan](../phase6/2026-08-28-phase-06-implementation-plan.md) ·
[Phase 3 runbook](../../runbooks/phase-03-bootstrap-and-foundation.md) ·
[naming and tagging convention](../../naming-and-tagging-convention.md)

**Goal:** Build the infrastructure pipeline — a CodePipeline v2 sourced from `carreque/bluegreenDeployment` through the existing CodeConnections link, filtered to `infra/**` on `main`, that validates every layer and then plans, seeks approval for, and applies `foundation`, `network`, `staging` and `prod` in order, with a `DEPLOY_SCOPE` execution variable that stops a run wherever you want it stopped — and prove it correct offline before a single resource is created.

From this phase on, **merging a phase branch is what fires a deployment** (roadmap §2.1). The merge button becomes the release control, and the four manual approvals are what stand between a merge and production.

**Architecture:** Files added to the existing `infra/foundation/` root module — not a new layer. The pipeline therefore manages the layer that contains it, which is intentional and documented (roadmap §1). Three CodeBuild projects with three separate service roles carry the work; the buildspecs under `pipelines/` stay three lines each and delegate to shell under `scripts/`, matching the convention the makefile already states. Correctness is asserted by Terraform's native test framework against `mock_provider`; the whole gate stays offline.

**Tech stack:** Terraform 1.15.7, AWS provider 6.61.0, CodePipeline **V2** (required for execution variables, git triggers and stage conditions), CodeBuild on `aws/codebuild/amazonlinux-x86_64-standard:5.0`, tflint 0.60.0 and checkov 3.3.13 from the digest-pinned containers `scripts/lint-infra.sh` already uses.

**Spec:** [phase roadmap §3, Phase 7](../../2026-08-04-implementation-phase-roadmap.md#phase-7--infrastructure-pipeline), elaborated by [design research §6](../../2026-08-04-blue-green-deployment-platform-design-research.md#6-pipelines) and constrained by [§1.5's image-only limitation](../../2026-08-04-blue-green-deployment-platform-design-research.md#15-codepipeline-can-trigger-native-bluegreen-directly).

---

## Global Constraints

Project-wide requirements. Every task's requirements implicitly include this section.

- **Naming:** `bgd-us-east-1-<resource>`, all lowercase, hyphen-separated. The convention already names two of this phase's resources: `bgd-us-east-1-infra-pipeline` for the pipeline and `bgd-us-east-1-<purpose>-build` for CodeBuild projects. These are project-wide resources, so they take **no `<env>` segment** — convention §2. See the [convention](../../naming-and-tagging-convention.md).
- **Tagging:** exactly four keys — `environment`, `projectName`, `region`, `owner` — applied through the provider's `default_tags`. This layer's `environment` is `shared`, and it already is; this phase adds no tag and changes no tag.
- **Terraform:** `required_version >= 1.10`, AWS provider `~> 6.61`, S3 backend with `use_lockfile = true`, no DynamoDB lock table. Unchanged from Phase 3; this phase adds no provider.
- **`pipeline_type = "V2"`** is mandatory. `variable`, `trigger` and `stage.before_entry` are all V2-only, and a V1 pipeline silently rejects none of them at plan time.
- **The offline gate:** `make tf-check` must pass on a machine that has never run `aws sso login`.
- **Every checkov finding is either fixed or skipped with a written reason.** A bare skip is not acceptable; the reason names the trade-off.
- **`terraform.tfvars` is gitignored and does not exist in CodeBuild.** Any layer with a required variable that has no default cannot be planned by the pipeline until this phase supplies the value another way (F7, D8).

---

## 0. Purpose and non-goals

Phases 3 to 6 built four layers and handed each one to you as a runbook. That was the right trade while the layers were being debugged, but it does not scale: `foundation`, `network`, `staging` and `prod` are now four `terraform apply` invocations in a fixed order, run from one laptop, with no record of what was applied or who approved it.

This phase replaces that with a pipeline. Its job is not automation for its own sake — it is that **the plan a human approves is the plan that runs**, and that the run is recorded.

**This phase deliberately does not:**

- create any AWS resource, or make any AWS API call, in this session (D1)
- manage `infra/bootstrap` — the layer that holds the state backend the pipeline reads (D15)
- build, test or push the container image, or deploy an image change — Phase 8. Only Terraform flows through this pipeline
- notify anyone of a pipeline failure — Phase 9 owns notification and attaches to this pipeline's events, exactly as it attaches to Phase 6's alarms (D16)
- add a `terraform destroy` path. Teardown stays local and stays ordered — `make teardown` (Phase 4, hardened in Phase 10)
- change anything under `app/`, `lambdas/`, `infra/bootstrap/`, `infra/network/`, `infra/environments/staging/` or `infra/environments/prod/`

### 0.1 Decisions taken before this plan was written

#### D1 — This session writes and verifies; you apply

The same split Phases 3, 4, 5 and 6 took, for the same reason: no AWS session is available, and the project's working practice is to write and verify every phase offline and execute at the end.

Everything in §4 is verifiable with no AWS credentials. The apply that creates the pipeline, and both exit-criteria demonstrations, are handed over as [the runbook](../../runbooks/phase-07-infra-pipeline.md).

**Neither exit criterion in §5 is met by the branch alone.** The plan says so explicitly rather than letting the pull request blur it.

There is one asymmetry this phase has that its predecessors did not. Phase 7's first apply is the last one that has to be local: `make apply-foundation` creates the pipeline, and from the next merge onward the pipeline applies itself. The runbook calls this the handover and gives it its own step.

#### D2 — One stage per layer with three actions, not three stages per layer

The roadmap describes "per-layer plan, manual approval and apply". That could be twelve stages plus Source and Validate, or four stages plus two.

Four, with `Plan`, `Approve` and `Apply` as actions at `run_order` 1, 2 and 3 inside each layer's stage.

The reason is the skip mechanism. `before_entry` is a **stage-level** condition (F1) — one condition on the `Staging` stage skips its plan, its approval and its apply together, atomically. Three stages per layer would need three conditions each, evaluated independently, and a condition set that disagreed with itself would strand a manual approval nobody wants to answer in a pipeline that cannot finish. Twelve conditions have four times as many ways to be wrong as three do, and they express one idea.

It is also how the artifact hand-off gets short: `Plan` writes `plan_<layer>`, `Apply` reads it, and both live in the same stage where a reader can see the pairing without scrolling.

#### D3 — `DEPLOY_SCOPE` is cumulative — it names where a run *stops*

Values are `foundation`, `network`, `staging`, `all`, exactly as the roadmap fixes them. Each names the last layer the run applies:

| `DEPLOY_SCOPE` | Foundation | Network | Staging | Prod |
|---|---|---|---|---|
| `foundation` | apply | skip | skip | skip |
| `network` | apply | apply | skip | skip |
| `staging` | apply | apply | apply | skip |
| `all` | apply | apply | apply | apply |

Cumulative rather than exclusive, because the layers are ordered by dependency: `staging` reads `network`'s outputs through remote state, and applying staging against a network that was never applied is the failure the ordering exists to prevent. A run that reaches staging has necessarily satisfied foundation and network, and their plans are empty when nothing changed — which costs one approval click each and buys the guarantee.

`all` rather than `prod` is the roadmap's wording and it stays. It is worth reading as "all four layers", not as "everything the pipeline could conceivably do" — there is nothing beyond prod.

An unrecognised value applies **nothing**, loudly. `scripts/pipeline-terraform.sh` ranks it 0, which is below every layer, and dies with a message naming the four accepted values rather than silently treating the run as `foundation`.

#### D4 — The scope is enforced twice, and the redundancy is deliberate

The pipeline skips out-of-scope stages with a `before_entry` condition. **And** every plan and apply re-reads `DEPLOY_SCOPE` inside `scripts/pipeline-terraform.sh` and exits 0 without touching Terraform when the layer is out of scope.

That looks like belt and braces because it is, and the reason is F2: `before_entry` exists in the provider schema, but the `VariableCheck` rule's `configuration` is an untyped `map(string)`, so the operator set — specifically whether `MATCHES` is accepted — cannot be confirmed without an AWS session.

Guessing wrong is not symmetric, and the shape of the argument is Phase 6's D3 again:

- If the condition is wrong in the direction of **entering a stage it should have skipped**, the script refuses and the stage passes without applying anything. The cost is a manual approval that appears when you did not want it.
- If the condition were the only gate and it were wrong in that direction, a `DEPLOY_SCOPE=network` run would **apply production**. That is the exact failure the second exit criterion exists to disprove.

So the condition is an optimisation — it saves the approval click — and the script is the guarantee. If `MATCHES` turns out not to exist, only the Terraform changes, and the fallback is in F2.

#### D5 — Three CodeBuild projects, because the service role is a property of the project

`action.role_arn` on a CodePipeline action is the role **CodePipeline assumes to invoke the action**, used for cross-account actions. It is not the CodeBuild service role, which is `service_role` on `aws_codebuild_project` and is what the build's own AWS calls are made with.

That single fact forces the project count. Three roles that differ in what a build may do means three projects:

| Project | Buildspec | Service role |
|---|---|---|
| `bgd-us-east-1-infra-validate-build` | `pipelines/infra-validate.yml` | `bgd-us-east-1-infra-validate-role` |
| `bgd-us-east-1-infra-plan-build` | `pipelines/infra-plan.yml` | `bgd-us-east-1-infra-plan-role` |
| `bgd-us-east-1-infra-apply-build` | `pipelines/infra-apply.yml` | `bgd-us-east-1-infra-apply-role` |

Which **layer** a build works on is not a property of the project — it is passed per action through the CodeBuild action's `EnvironmentVariables` override as `LAYER`. Eight actions (four plans, four applies) share two projects.

#### D6 — The plan role is read-only; the apply role is administrator

Two roles, and only one of them is a compromise.

**Plan — `ReadOnlyAccess`, plus four narrow additions.** A `terraform plan` reads the world and writes nothing except a lock. This is the one role in the project where least privilege is both achievable and worth the effort, and the payoff is real: a plan build that is compromised, or a buildspec edited to run something else, cannot mutate the account. The additions are the state lock file, the two SSM parameters (D8), the CodeConnections read APIs, and the build's own log group — each because `ReadOnlyAccess` either does not cover it or cannot be relied on to cover it (F5).

The lock grant is scoped to `arn:aws:s3:::bgd-us-east-1-tfstate-590184028094/*.tflock`, not to the bucket. A plan can create and delete its own lock and still cannot write state.

**Apply — `AdministratorAccess`, with the argument written down.** This role creates IAM roles in four layers. A principal that can create an IAM role and attach a policy to it can grant itself anything; a narrower policy on such a role describes a boundary that does not exist. Enumerating actions here would produce a document that reads as least privilege, fails at apply time in whichever layer was missed, and has to be extended by every future phase — while providing no security property the admin policy does not.

This is the same reasoning Phase 6's D5 used to reach the opposite-looking conclusion for the blue/green controller, and it is worth stating that the two agree: **write the policy that is honest about the boundary, not the one that looks strict.**

The control that actually stands between a merge and a production change is not this role. It is the manual approval on a plan a human read, and the fact that the apply applies that plan file rather than re-deciding (D9).

**Validate — neither.** `scripts/tf.sh validate` and `terraform test` both init with `-backend=false`, and tflint and checkov read files. The validate build makes **no AWS API call at all**, so its role grants only its log group and the artifact bucket. That the validate stage cannot see the account is asserted in a test (Task 2), because it is the kind of property that erodes the first time someone adds a step that needs "just one read".

#### D7 — `LINUX_CONTAINER` on x86_64, not `ARM_CONTAINER`

`scripts/lint-infra.sh` runs tflint and checkov from digest-pinned containers, and its header already anticipated this stage reusing the identical command. That command passing on the development machine does **not** prove those digests have `linux/arm64` variants: Docker Desktop on Apple silicon runs `linux/amd64` images transparently under emulation, so a single-architecture amd64 image is indistinguishable from a multi-architecture one locally.

CodeBuild has no such emulation. An `ARM_CONTAINER` project pulling an amd64-only digest fails with an exec format error inside `docker run`, which surfaces as a lint failure with a confusing message.

`amd64` is the side that is certainly safe for both pins, and Terraform itself is architecture-agnostic. Phase 8 still needs `ARM_CONTAINER` for the application image, because that image *is* arm64 — different projects, no conflict, and the divergence is deliberate rather than accidental.

`privileged_mode = true` on the validate project only. Plan and apply run no containers and do not get it.

#### D8 — `image_tag` comes from SSM Parameter Store

`infra/environments/staging` and `infra/environments/prod` each declare `image_tag` with **no default**, deliberately — a stale default would silently deploy an old image (Phase 5 D3, Phase 6 D10). The value lives in `terraform.tfvars`, which `.gitignore` excludes. A CodeBuild workspace therefore has no value at all, and `terraform plan -input=false` fails with `No value for required variable` (F7).

`foundation` gains two SSM `String` parameters, `/bgd/staging/image_tag` and `/bgd/prod/image_tag`, each with `lifecycle { ignore_changes = [value] }`. `scripts/pipeline-terraform.sh` reads the one matching its layer and passes `-var image_tag=<value>` to `plan`.

Three properties make this the right source rather than the merely convenient one:

- **The infra pipeline becomes image-preserving by construction.** An `infra/**` merge cannot change the running image, because the tag it plans with is the tag already recorded. That is design §1.5's separation — Terraform owns the service shape, the app pipeline owns images — enforced by mechanism instead of by convention.
- **It survives teardown.** Parameter Store is in `foundation`, which `make teardown` does not touch, so a Phase 10 rebuild plans against the tag that was deployed before the teardown.
- **Phase 8 inherits the handoff unchanged.** The app pipeline pushes an image and writes the parameter; nothing about the infra pipeline needs to know that happened.

The initial value is the literal string `unset`. `scripts/seed-ecr.sh` overwrites it with the tag it actually pushed (Task 8), so the parameter is populated before the pipeline ever runs. If a plan finds `unset`, it dies naming `make seed-ecr` rather than passing a nonsense tag to `data.aws_ecr_image` and failing one layer deeper.

`ignore_changes = [value]` is what stops the next `foundation` apply reverting a tag the app pipeline set — the same drift problem Phase 6's D10 solved by keeping the CLI out of ECS service updates, in the other direction.

#### D9 — Apply applies the saved plan file

`Plan` runs `terraform plan -out=pipeline.tfplan` and publishes the whole workspace as the output artifact. `Apply` consumes that artifact and runs `terraform apply pipeline.tfplan`. It does not re-plan.

Otherwise the approval approves a description of a plan and the apply computes a new one, and between the two the account may have changed. A re-planning apply is a pipeline that asks for consent to one thing and does another — quietly, and only sometimes.

The saved plan is bound to the state serial it was made against, so a local `make apply-foundation` racing the pipeline makes the apply fail with a stale-plan error rather than overwriting. That is the correct behaviour and the runbook says so.

Two consequences the tasks account for. `terraform apply <planfile>` rejects `-var`, so the SSM lookup happens on the plan side only. And the plan file is bound to the provider versions that produced it, which the committed `.terraform.lock.hcl` guarantees across the re-`init` the apply build does.

#### D10 — An empty plan still requires an approval

CodePipeline cannot conditionally skip one action inside a stage — conditions are stage-level (F1). So a `DEPLOY_SCOPE=all` run where only `prod` changed still asks for four approvals, three of them on empty plans.

The alternative would be a second `before_entry` condition per stage reading an exported `HAS_CHANGES` variable, which trades three clicks for four more conditions whose semantics are the thing F2 says cannot be confirmed offline. Not worth it.

What the plan does instead is make the empty case unmistakable: when `terraform plan -detailed-exitcode` returns 0, the exported summary is the literal `No changes. <layer> is up to date.` and that is the whole approval message. A one-second decision, and — more importantly — a *visibly* one-second decision, so the click that matters does not look like the three that did not.

#### D11 — `execution_mode = "QUEUED"`

The V2 default is `SUPERSEDED`: a newer execution cancels an older one still in flight. For a pipeline whose executions sit waiting on human approvals and then run applies that take minutes, that is wrong in both halves. A second merge would cancel the run whose plan someone is part-way through reading, and could cancel a run mid-apply.

`QUEUED` runs executions one at a time in arrival order. Two merges in quick succession produce two runs, both of which happen, in order.

`PARALLEL` is the third option and is plainly wrong here: two concurrent applies of the same layer would contend on the same state lock, and the loser fails on a lock timeout.

#### D12 — The trigger watches `infra/**`, `pipelines/**` and the pipeline's own scripts

```
infra/**
pipelines/**
scripts/pipeline-*.sh
scripts/install-terraform.sh
```

The roadmap says `infra/**`. The other three are the pipeline's own executable content: a change to a buildspec or to `pipeline-terraform.sh` changes what every stage does, and it would be strange for that to reach production only when someone next happens to edit a `.tf` file.

`scripts/**` as a whole is deliberately **not** included. `scripts/` also holds `build-image.sh`, `smoke.sh` and `generate-sbom.sh`, which belong to Phase 8's pipeline; watching the directory would cross-trigger a full four-approval infra run on an application change.

The cost of the narrower filter is real and worth naming: editing `scripts/tf.sh` or `scripts/lint-infra.sh` alone does not re-run validation. Both are covered by `make tf-check` locally, and the next `infra/**` change picks them up.

#### D13 — `DetectChanges = "false"` on the source action

The `CodeStarSourceConnection` action creates its own webhook when `DetectChanges` is true, and that webhook fires on **every** push to the branch, with no path filter. Left at its default it would run the whole infra pipeline on an `app/`-only commit — the exact thing D12 is arranged to prevent — and the `trigger` block's filter would be dead configuration sitting beside it, apparently working.

In a V2 pipeline the `trigger` block owns change detection. `DetectChanges` is switched off so there is one mechanism, not two.

#### D14 — Terraform is installed by a pinned script, not by a CodeBuild runtime

CodeBuild's standard images ship language runtimes, not Terraform. `scripts/install-terraform.sh` downloads the release named by `.terraform-version` — the same file tfenv reads locally, so the pipeline and the development machine cannot drift — and verifies it against a checksum pinned in the script.

The alternative, a `hashicorp/terraform` container image, would put the version in a second place and lose the `.terraform-version` link that makes the two environments provably the same.

#### D15 — The pipeline does not manage `bootstrap`

`infra/bootstrap` creates the S3 bucket every other layer stores state in, including `foundation`, whose state the pipeline's own definition lives in. A pipeline that applied it would be reconfiguring the ground it stands on mid-run.

It is also the one layer that genuinely never changes, holds local state that is gitignored, and is documented as trivially recreatable (roadmap, Phase 3). `make tf-validate` and `make tf-test` still cover it in the Validate stage, because linting it costs nothing and catches a syntax error before someone needs it.

#### D16 — No notification, and no `on_failure` conditions

Phase 9 owns EventBridge rules on CodePipeline execution state changes, the SNS alerts, and the dashboard. This phase creates the pipeline those rules will observe and stops there — the same boundary Phase 6 drew when it created four alarms with no `alarm_actions` (Phase 6 D9).

`on_failure` and `on_success` stage conditions exist in the schema (F1) and are deliberately unused. `on_failure` with `retry_configuration` is tempting for a flaky apply, but an infrastructure apply that failed half-way should be looked at, not retried; and an automatic retry would double-count in Phase 9's change-failure-rate metric.

#### D17 — Buildspecs stay three lines; the logic is in `scripts/`

The makefile states the convention for this repository: *make is the discoverable front door, scripts hold the logic; any recipe longer than three lines, or needing a conditional or a loop, becomes a script.* The same rule applies to buildspecs, and for a stronger reason — a buildspec cannot be run locally, so logic that lives in one is logic nobody can test before merging it.

So `pipelines/infra-validate.yml` calls `make`, and the two Terraform buildspecs call `scripts/pipeline-terraform.sh`. The validate stage in particular runs the *identical* `make` targets you run on your laptop, which is what makes a green pipeline and a green laptop mean the same thing.

---

## 1. Findings recorded before this plan was written

### F1 — The V2 surface is present in the installed provider, confirmed against the binary

Not read from a changelog. `terraform providers schema -json` against `hashicorp/aws` 6.61.0 — the version every layer's `.terraform.lock.hcl` pins — gives `aws_codepipeline`:

```
root attrs: arn, execution_mode, id, name, pipeline_type, region, role_arn, tags, tags_all, trigger_all
  block artifact_store (set): location, region, type
  block stage (list): name
    block action (list): category, commands, configuration, input_artifacts, name,
                         namespace, output_artifacts, output_variables, owner,
                         provider, region, role_arn, run_order, timeout_in_minutes, version
    block before_entry (list)
      block condition (list): result
        block rule (list): commands, configuration, input_artifacts, name, region,
                           role_arn, timeout_in_minutes
          block rule_type_id (list): category, owner, provider, version
    block on_failure (list): result
    block on_success (list)
  block trigger (list): provider_type
    block git_configuration (list): source_action_name
      block push (list)
        block branches (list): excludes, includes
        block file_paths (list): excludes, includes
        block tags (list): excludes, includes
      block pull_request (list): events
  block variable (list): default_value, description, name
```

Every attribute this plan uses is in that tree: `variable` for `DEPLOY_SCOPE`, `trigger.git_configuration.push.file_paths` for D12, `stage.before_entry.condition.rule` for the skip, `action.namespace` for the exported plan variables, and `execution_mode` for D11.

`on_success` has no `result` attribute while `on_failure` does — visible above, and consistent with a success condition having nothing to decide. Neither is used (D16).

### F2 — The `VariableCheck` operator set is not in the schema and cannot be confirmed offline

`rule.configuration` is `map(string)`. The provider validates nothing inside it; the service does, at execution time. So the schema proves that a rule can be attached and proves nothing about whether `Operator = "MATCHES"` is accepted, or whether `Variable` takes `#{variables.DEPLOY_SCOPE}` rather than a bare name.

Three of the four stages need only equality, and one of those needs none at all:

| Stage | Needs | Risk |
|---|---|---|
| Foundation | no condition | none |
| Network | `MATCHES ^(network\|staging\|all)$` | unconfirmed |
| Staging | `MATCHES ^(staging\|all)$` | unconfirmed |
| Prod | `EQ all` | low — equality is the one operator a variable check certainly has |

Set membership is what forces a regex: a condition's rules are evaluated together, which expresses AND, and `network` runs under three of the four scopes. There is no arrangement of `EQ` and `NE` rules that expresses an OR of two values in one condition.

**The runbook confirms it** (step 7) by starting a `DEPLOY_SCOPE=network` run and reading whether the Staging stage reports `Skipped`. **The fallback, if `MATCHES` is rejected**, is to change `DEPLOY_SCOPE`'s accepted values to the ordinals `1`, `2`, `3`, `4` and every rule to `LTE <n>` — one operator, no set membership, no regex. It is worse to read and it is a Terraform-only change: `scripts/pipeline-terraform.sh` already ranks the scope numerically, so only `scope_rank`'s `case` and the four `scope_value`s move.

Until that is confirmed, D4's second gate is what makes being wrong here cheap.

### F3 — `action.role_arn` is not the CodeBuild service role

Worth recording because the plan presented before this document said "two CodeBuild projects, role chosen per action", and that does not work.

`action.role_arn` is the role CodePipeline assumes **to invoke the action** — its documented use is cross-account actions. The permissions a CodeBuild build runs with come from `service_role` on `aws_codebuild_project`, which is a property of the project and cannot be overridden per action. `EnvironmentVariables` can be overridden per action; the service role cannot.

Hence D5's three projects. The cost is one extra project and one extra buildspec; the alternative was a plan role that quietly had administrator permissions.

### F4 — A git-triggered run cannot set pipeline variables

Execution variables are supplied by `StartPipelineExecution`. A run started by the source trigger supplies none, so every merge-triggered run takes `DEPLOY_SCOPE`'s `default_value`.

That is what makes the default a policy decision rather than a convenience, and it is settled: `all`. Every infra merge flows to production, gated by four approvals it cannot pass without a human. A narrower default would mean the common case — an infra change you want in production — takes two runs, and the second one's plan is not the plan anyone reviewed.

It also means `DEPLOY_SCOPE` is only ever *exercised* by a manually started run, which is what the runbook's step 7 does and what the second exit criterion measures.

### F5 — `ReadOnlyAccess` cannot be assumed to cover everything a plan reads

`ReadOnlyAccess` is an AWS-managed policy that lags new services and new API prefixes. Two of this project's reads are exactly the kind that lag:

- **`codeconnections:GetConnection`.** The service was renamed from CodeStar Connections, the provider keeps the old spelling for compatibility (Phase 3 §F1), and a managed policy may carry one prefix and not the other. `foundation`'s plan reads the connection.
- **`ssm:GetParameter`** on the two D8 parameters. Almost certainly covered, granted explicitly anyway because a plan that cannot read the image tag fails in `data.aws_ecr_image` with a message about a missing image rather than about a missing permission.

Both prefixes are granted explicitly in the plan role's supplement, alongside the `.tflock` write and the log group. Granting something twice costs nothing; discovering the gap costs a failed production plan.

### F6 — The makefile's `AWS_PROFILE` export breaks inside CodeBuild

`makefile` sets `AWS_PROFILE := bootcamp-administrator-access` and exports it, deliberately and load-bearingly: `:=` overrides an inherited environment variable so a shell exported for another account cannot silently redirect an apply (Phase 3 §F7).

In CodeBuild there is no shared config file and no such profile. Credentials come from the project's service role. Any AWS SDK call made under an exported `AWS_PROFILE` naming a profile that does not exist fails with `The config profile (bootcamp-administrator-access) could not be found` — **instead of** falling back to the role.

The Validate stage runs `make`, and today nothing it runs calls AWS. That is a property of the current target list, not a guarantee, and the failure it would produce reads like a credentials problem rather than a makefile problem.

The fix is four lines in the makefile (Task 8): set and export `AWS_PROFILE` only when `CODEBUILD_BUILD_ID` is unset. It preserves the Phase 3 reasoning exactly — a local shell still cannot override it — and removes the trap for the environment where a profile name is meaningless.

### F7 — `image_tag` has no default, and the plan fails before it reaches AWS

Verified by reading the two layers. `infra/environments/prod/variables.tf` declares `image_tag` with a description and no `default`; `infra/environments/prod/terraform.tfvars.example` documents copying it to `terraform.tfvars`; `.gitignore` excludes `*.tfvars` while committing `*.tfvars.example`.

`terraform plan -input=false` on either environment layer, in a workspace built from a source zip, therefore fails with `No value for required variable` before it authenticates to anything. Two of the pipeline's four layers would never plan.

This is the finding D8 exists to answer, and it is the only change this phase makes that reaches outside `infra/foundation/`, `pipelines/` and `scripts/`.

### F8 — Every name fits, with room to spare

| Resource | Name | Length | Cap |
|---|---|---|---|
| CodePipeline | `bgd-us-east-1-infra-pipeline` | 28 | 100 |
| CodeBuild project | `bgd-us-east-1-infra-validate-build` | 34 | 255 |
| IAM role | `bgd-us-east-1-infra-validate-role` | 33 | 64 |
| SSM parameter | `/bgd/staging/image_tag` | 22 | 2048 |
| Log group | `/bgd/us-east-1/shared/infra-validate` | 36 | 512 |

The 64-character IAM role cap is the tightest and the longest role name uses half of it. Nothing here approaches the 32-character ALB cap that constrains the environment layers, because nothing here is a load balancer.

### F9 — checkov will fail this layer, and two of the reasons are decisions

Predicted, from the check catalogue and this layer's new resources. The precise identifiers are confirmed when `make tf-lint` runs in Task 7, and the [local verification record](./2026-08-29-local-verification.md) carries the real list — including whichever of these predictions turns out to be wrong, which is how Phase 6's F7 was handled.

| Likely check | Resource | Response |
|---|---|---|
| Privileged mode enabled | `aws_codebuild_project.infra_validate` | **Skip.** Docker-in-docker is how `scripts/lint-infra.sh` runs its digest-pinned tflint and checkov containers — the identical command used locally, installing nothing on the host. Removing it means installing both tools into the build image at floating versions. |
| Role with `AdministratorAccess` | `aws_iam_role_policy_attachment.infra_apply` | **Skip.** D6's argument in full: this role creates IAM roles in four layers, and a principal that can create a role and attach a policy can already grant itself anything. |
| CodeBuild not encrypted with a CMK | all three projects | **Skip.** Same decision as Phase 3 §D4, applied consistently to every encrypted-at-rest resource in this project: SSE-S3 and AWS-owned keys, no customer-managed key and no monthly charge, for artifacts that are reproducible from the commit that produced them. |
| Log group without retention | three new groups | **Fix.** They take `var.pipeline_log_retention_days`, default 30. |
| SSM parameter not a `SecureString` | both `image_tag` parameters | **Skip.** The value is a container image tag that is printed in every build log, every task definition and every `/version` response. Encrypting it would imply it is a secret. |

---

## 2. Global constraints

Restating the ones this phase breaks if it gets them wrong, with the symptom attached.

| Constraint | Symptom if missed |
|---|---|
| `pipeline_type = "V2"` | `variable`, `trigger` and `before_entry` are rejected at apply, not at plan. The message names the attribute, not the pipeline type. |
| `DetectChanges = "false"` on the source action | A second, unfiltered webhook. Every `app/` commit runs the whole infra pipeline and asks for four approvals. `terraform plan` stays clean forever (D13). |
| The apply action's `input_artifacts` is the plan action's `output_artifacts` | Apply re-plans, and the approval approved something else. No error at any point (D9). |
| `terraform apply <planfile>` gets no `-var` | Apply fails with `Can't set variables when applying a saved plan`. Loud and immediate — the harmless one on this list. |
| `lifecycle { ignore_changes = [value] }` on both SSM parameters | The next `foundation` apply reverts the image tag Phase 8 set, and the following `prod` apply deploys the old image. Both applies succeed. |
| `execution_mode = "QUEUED"` | A second merge cancels the first run — possibly mid-apply, possibly while its approval is open (D11). |
| The scope check runs before the saved-plan check in `apply` mode | An out-of-scope apply dies with `no saved plan` instead of reporting `skipped`, turning a correct skip into a red stage. |
| Policies built with `jsonencode`, never `aws_iam_policy_document` | `mock_provider` mocks every data source the AWS provider owns, that generator included. The policy becomes a random string under test, `aws_iam_role` rejects it client-side, and any assertion that survives asserts nothing. The rule and its reason are already in `infra/environments/prod/iam.tf`; Phase 5 §F1. |
| `AWS_PROFILE` unset inside CodeBuild | Any AWS call made through `make` fails with `config profile could not be found` rather than using the service role (F6). |
| The three log groups exist before the projects reference them | CodeBuild creates them itself, without retention, and the checkov fix in F9 silently applies to nothing. |
| Artifact bucket lifecycle rule scoped by prefix | Every execution's source zip and four plan artifacts accumulate as **current** versions forever. The existing rule expires only *noncurrent* versions, so it matches none of them. |

**`on_failure`, `on_success` and `pull_request` triggers are deliberately unused.** All three are in the schema (F1) and all three are tempting. A `pull_request` trigger in particular looks like it would fix the gap roadmap §2.1 names — that pull requests do not validate — but it would run a pipeline whose later stages apply to production from an unmerged branch. Recorded here so the omissions read as decisions.

---

## 3. File structure

```
infra/foundation/
  variables.tf              MODIFIED  five new variables
  locals.tf                 MODIFIED  the ordered layer list, the exported-variable names
  ssm.tf                    NEW       the two image_tag parameters (D8)
  iam-pipeline.tf           NEW       four roles: pipeline, validate, plan, apply
  codebuild.tf              NEW       three projects and their three log groups
  codepipeline.tf           NEW       the pipeline: six stages, the variable, the trigger
  artifacts.tf              MODIFIED  a prefix-scoped lifecycle rule for pipeline artifacts
  outputs.tf                MODIFIED  pipeline name, role ARNs, both parameter names
  README.md                 MODIFIED  the layer now owns a pipeline
  tests/
    pipeline_shape.tftest.hcl   NEW   stages, order, artifacts, trigger, variable, conditions
    pipeline_iam.tftest.hcl     NEW   what each of the four roles can and cannot do

pipelines/
  infra-validate.yml        NEW       three lines: install terraform, run make
  infra-plan.yml            NEW       three lines: install terraform, plan, source the vars
  infra-apply.yml           NEW       two lines: install terraform, apply the saved plan
  README.md                 MODIFIED  the infra buildspecs exist now

scripts/
  install-terraform.sh      NEW       the pinned install, shared by all three buildspecs
  pipeline-terraform.sh     NEW       scope gate, image tag, plan, summary, apply
  seed-ecr.sh               MODIFIED  writes the tag it pushed to both SSM parameters

makefile                    MODIFIED  tf-fmt-check; AWS_PROFILE conditional (F6)

docs/
  runbooks/phase-07-infra-pipeline.md            NEW
  runbooks/README.md                             MODIFIED  the row that says "planned"
  phases/phase7/
    2026-08-29-phase-07-implementation-plan.md   this document
    2026-08-29-local-verification.md             NEW  the evidence record
  naming-and-tagging-convention.md               MODIFIED  an SSM row, and §2 confirmed
  2026-08-04-implementation-phase-roadmap.md     MODIFIED  the Phase 7 amendment
  2026-08-04-blue-green-deployment-platform-design-research.md
                                                 MODIFIED  §8.1: one CodeBuild role is three
```

**Why these boundaries.** `foundation` was six files describing six unrelated durable things; this phase adds a seventh concern that is four files rather than one, because the pipeline, the projects that execute it, the roles those run as, and the parameters they read are the four pieces a reviewer needs to be able to find separately. `iam-pipeline.tf` rather than `iam.tf` because the name should say that these are the pipeline's roles and not the layer's — Phases 8 and 9 will add more.

The two test files split the same way the risk does. `pipeline_shape.tftest.hcl` protects the wiring: stage order, which artifact feeds which action, whether the trigger filters what D12 says it filters. `pipeline_iam.tftest.hcl` protects the boundary that D6 argues for, and it is the file that has to say no when someone adds one read to the validate role.

`install-terraform.sh` is separate from `pipeline-terraform.sh` because all three buildspecs need it and only two need the other — and because the version pin belongs in one file with the checksum next to it.

---

## 4. Tasks

Ten tasks. Tests precede implementation throughout, which for Terraform means the `.tftest.hcl` file is written and **seen to fail** before the resources it asserts on exist.

Every task ends with its suite passing and a commit **proposed for approval, never made automatically**. The full gate — `make tf-check` — runs at Task 7 and again at Task 10.

---

### Task 1: Variables, locals and the two SSM parameters

The parameters come first because the plan role's policy interpolates their ARNs, and the ordered layer list comes first because both the pipeline and its tests read it.

**Files:**
- Modify: `infra/foundation/variables.tf`
- Modify: `infra/foundation/locals.tf`
- Create: `infra/foundation/ssm.tf`
- Test: `infra/foundation/tests/pipeline_shape.tftest.hcl`

**Interfaces:**
- Produces: `var.github_repository_id`, `var.github_branch`, `var.deploy_scope_default`, `var.pipeline_log_retention_days`, `var.pipeline_artifact_retention_days`; `local.pipeline_layers` (ordered list of four objects with `name`, `title`, `scope_operator`, `scope_value`), `local.plan_exported_variables`; `aws_ssm_parameter.image_tag` (a `for_each` map keyed `staging` and `prod`).
- Consumed by: every later task in this phase.

- [ ] **Step 1: Add the five variables**

Append to `infra/foundation/variables.tf`:

```hcl
variable "github_repository_id" {
  description = "owner/name of the repository CodePipeline sources from, through the CodeConnections link."
  type        = string
  default     = "carreque/bluegreenDeployment"

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository_id))
    error_message = "github_repository_id must be owner/name, not a URL."
  }
}

variable "github_branch" {
  description = "Branch the infra pipeline watches. Merging to it is what fires a deployment (roadmap §2.1)."
  type        = string
  default     = "main"
}

variable "deploy_scope_default" {
  description = <<-EOT
    DEPLOY_SCOPE for a run nobody chose a scope for.

    A run started by the git trigger cannot supply execution variables, so every
    merge to main takes this value (plan §F4). It is `all` deliberately: an infra
    change is normally a change you want in production, and the four manual
    approvals — not this default — are what stand between the merge and prod.

    Cumulative. `staging` also applies foundation and network; `all` reaches prod.
  EOT
  type        = string
  default     = "all"

  validation {
    condition     = contains(["foundation", "network", "staging", "all"], var.deploy_scope_default)
    error_message = "deploy_scope_default must be one of foundation, network, staging, all."
  }
}

variable "pipeline_log_retention_days" {
  description = "Retention on the three CodeBuild log groups. A pipeline log is worth keeping only until the next deployment is understood."
  type        = number
  default     = 30
}

variable "pipeline_artifact_retention_days" {
  description = "How long CodePipeline's own artifacts — the source zip and the four saved plans, one set per execution — are kept before the lifecycle rule expires them."
  type        = number
  default     = 30
}
```

- [ ] **Step 2: Add the ordered layer list to `locals.tf`**

Append to `infra/foundation/locals.tf`:

```hcl
locals {
  # A LIST, not a map, and that is load-bearing. Terraform iterates a map in
  # lexical key order, which for these four names is foundation, network, prod,
  # staging — so a map would build a pipeline that applies production before
  # staging. A list preserves the order written here, which is the dependency
  # order the layers actually have.
  #
  # scope_operator/scope_value are the VariableCheck rule that decides whether
  # the stage runs at all (plan §D3). foundation has none because every scope
  # includes it, so a rule there could only ever evaluate true.
  #
  # The regexes exist because a condition's rules are ANDed and `network` runs
  # under three of the four scopes; there is no arrangement of EQ and NE that
  # expresses that. Plan §F2 records what to change if MATCHES is unavailable.
  pipeline_layers = [
    {
      name           = "foundation"
      title          = "Foundation"
      scope_operator = null
      scope_value    = null
    },
    {
      name           = "network"
      title          = "Network"
      scope_operator = "MATCHES"
      scope_value    = "^(network|staging|all)$"
    },
    {
      name           = "staging"
      title          = "Staging"
      scope_operator = "MATCHES"
      scope_value    = "^(staging|all)$"
    },
    {
      name           = "prod"
      title          = "Prod"
      scope_operator = "EQ"
      scope_value    = "all"
    },
  ]

  # The names pipelines/infra-plan.yml exports and the approval action
  # interpolates. Declared once so a test can assert the buildspec still
  # exports them — a renamed variable does not fail anything, it just makes
  # every approval message read `#{PlanProd.PLAN_SUMMARY}` literally.
  plan_exported_variables = ["PLAN_STATUS", "PLAN_SUMMARY", "PLAN_URL"]

  # Only the two environment layers take an image tag. foundation and network
  # have no container in them.
  image_tag_environments = ["staging", "prod"]
}
```

- [ ] **Step 3: Write the failing assertions**

Create `infra/foundation/tests/pipeline_shape.tftest.hcl` with the mock block and the first three runs. Nothing it asserts on exists yet:

```hcl
# The pipeline's wiring: what runs, in what order, fed by which artifact.
#
# These are the assertions a plan review cannot make. Stage order is a list
# position, artifact hand-off is a string that has to match another string in a
# different block, and the trigger's path filter is invisible until the wrong
# commit starts a run.

mock_provider "aws" {}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
  domain_name  = "carloscloudengineer.com"
}

run "the_layer_list_is_in_dependency_order_not_lexical_order" {
  command = plan

  assert {
    condition     = [for l in local.pipeline_layers : l.name] == ["foundation", "network", "staging", "prod"]
    error_message = "the layers must be ordered foundation, network, staging, prod — a map would sort prod before staging and apply production first"
  }
}

run "every_environment_layer_has_an_image_tag_parameter" {
  command = plan

  assert {
    condition     = toset(keys(aws_ssm_parameter.image_tag)) == toset(["staging", "prod"])
    error_message = "staging and prod each need /bgd/<env>/image_tag; terraform.tfvars does not exist in CodeBuild (plan §F7)"
  }

  assert {
    condition     = aws_ssm_parameter.image_tag["prod"].name == "/bgd/prod/image_tag"
    error_message = "the parameter name is what scripts/pipeline-terraform.sh looks up; it is derived, not typed twice"
  }

  assert {
    condition     = alltrue([for p in aws_ssm_parameter.image_tag : p.type == "String"])
    error_message = "an image tag is printed in every build log and every /version response; SecureString would imply it is a secret"
  }
}
```

- [ ] **Step 4: Run the suite and see it fail**

```bash
./scripts/tf.sh test foundation
```

Expected: failures naming `local.pipeline_layers` and `aws_ssm_parameter.image_tag` as unknown. If the first run passes at this point, Step 2 was already committed — check `git status` before continuing.

- [ ] **Step 5: Write `ssm.tf`**

```hcl
# Which image tag each environment layer deploys.
#
# The two environment layers declare image_tag with no default, deliberately —
# a stale default would silently deploy an old image (Phase 5 §D3). Locally the
# value comes from terraform.tfvars, which .gitignore excludes, so a CodeBuild
# workspace has no value at all and `terraform plan -input=false` fails before
# it authenticates to anything. Plan §F7.
#
# Keeping it here rather than in the environment layers is what makes the infra
# pipeline image-preserving: an infra/** merge plans with the tag already
# recorded, so it cannot change what is running. Design §1.5's separation —
# Terraform owns the service shape, the app pipeline owns images — enforced by
# mechanism rather than by convention. Plan §D8.
#
# In foundation rather than in an environment layer for the second reason too:
# `make teardown` destroys prod, staging and network, and a Phase 10 rebuild has
# to plan against the tag that was deployed before the teardown.

resource "aws_ssm_parameter" "image_tag" {
  # checkov:skip=CKV_AWS_337:SecureString needs a KMS key for a value that is printed in every build log, every task definition and every /version response. Encrypting it would imply it is a secret. Plan §F9.
  for_each = toset(local.image_tag_environments)

  name = "/bgd/${each.key}/image_tag"
  type = "String"

  # `unset` rather than a plausible-looking tag. scripts/pipeline-terraform.sh
  # refuses this value by name and says to run `make seed-ecr`, which is a
  # better failure than passing a tag that was never pushed to
  # data.aws_ecr_image and failing one layer deeper.
  value = "unset"

  description = "ECR tag the ${each.key} layer deploys. Written by scripts/seed-ecr.sh and, from Phase 8, by the application pipeline."

  lifecycle {
    # The whole point. seed-ecr.sh and Phase 8 write this value; without
    # ignore_changes the next foundation apply reverts it to "unset" and the
    # following environment apply deploys whatever that resolves to. Both
    # applies succeed, which is what makes it worth a lifecycle block rather
    # than a comment.
    ignore_changes = [value]
  }
}
```

- [ ] **Step 6: Run the suite and see it pass**

```bash
./scripts/tf.sh test foundation
```

Expected: PASS, including the three pre-existing Phase 3 test files.

- [ ] **Step 7: Commit**

```bash
git add infra/foundation/variables.tf infra/foundation/locals.tf \
        infra/foundation/ssm.tf infra/foundation/tests/pipeline_shape.tftest.hcl
git commit -m "feat(infra): pipeline variables, the ordered layer list and the image-tag parameters"
```

---

### Task 2: The four IAM roles

Written before the projects and the pipeline that reference them, because a role's policy interpolates the ARNs of what it acts on and because D6's boundary is the claim this phase most needs to be able to defend.

**Files:**
- Create: `infra/foundation/iam-pipeline.tf`
- Test: `infra/foundation/tests/pipeline_iam.tftest.hcl`

**Interfaces:**
- Consumes: `aws_s3_bucket.artifacts`, `aws_codeconnections_connection.github`, `aws_ssm_parameter.image_tag`, `local.name_prefix`.
- Produces: `aws_iam_role.pipeline`, `aws_iam_role.infra_validate`, `aws_iam_role.infra_plan`, `aws_iam_role.infra_apply`.

- [ ] **Step 1: Write the failing IAM assertions**

Create `infra/foundation/tests/pipeline_iam.tftest.hcl`:

```hcl
# What each of the four roles can do, and — for two of them — what they cannot.
#
# Plan §D6 argues that the plan role is the one place in this pipeline where
# least privilege is both achievable and worth having, and that the validate
# role should never touch AWS at all. Both of those erode quietly: someone adds
# "just one read" to validate, or swaps ReadOnlyAccess for something broader to
# unblock a plan, and nothing fails. These assertions are what says no.
#
# Every policy asserted here is built with jsonencode rather than
# aws_iam_policy_document, for the reason the prod layer's iam.tf records:
# mock_provider mocks every data source the AWS provider owns, the policy
# document generator among them, so a policy built through it is a random
# string under test and these assertions would be vacuous. Phase 5 §F1.

mock_provider "aws" {}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
  domain_name  = "carloscloudengineer.com"
}

run "plan_and_apply_are_different_roles_with_different_reach" {
  command = plan

  assert {
    condition     = aws_iam_role.infra_plan.name != aws_iam_role.infra_apply.name
    error_message = "a single role for both means the plan build runs as administrator, which is the thing D6 buys by splitting them"
  }

  assert {
    condition     = aws_iam_role_policy_attachment.infra_plan_readonly.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "the plan role must be read-only; a plan writes nothing but its own lock file"
  }

  assert {
    condition     = aws_iam_role_policy_attachment.infra_apply_admin.policy_arn == "arn:aws:iam::aws:policy/AdministratorAccess"
    error_message = "the apply role is deliberately administrator (D6); if this changed, the reasoning changed and the plan document has to change with it"
  }
}

run "every_pipeline_role_trusts_the_right_service_and_only_this_account" {
  command = plan

  assert {
    condition = alltrue([
      for r in [aws_iam_role.infra_validate, aws_iam_role.infra_plan, aws_iam_role.infra_apply] :
      jsondecode(r.assume_role_policy).Statement[0].Principal.Service == "codebuild.amazonaws.com"
    ])
    error_message = "the three build roles are assumed by CodeBuild; a wrong principal fails at apply with a message about the policy rather than the principal"
  }

  assert {
    condition     = jsondecode(aws_iam_role.pipeline.assume_role_policy).Statement[0].Principal.Service == "codepipeline.amazonaws.com"
    error_message = "the pipeline role is assumed by CodePipeline, not by CodeBuild"
  }

  assert {
    condition = alltrue([
      for r in [aws_iam_role.pipeline, aws_iam_role.infra_validate, aws_iam_role.infra_plan, aws_iam_role.infra_apply] :
      jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "590184028094"
    ])
    error_message = "without the account condition these trust policies are confused-deputy shaped — the same guard the prod roles carry, and it matters most on the role holding AdministratorAccess"
  }
}

run "the_plan_role_can_lock_state_but_cannot_write_it" {
  command = plan

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.infra_plan.policy).Statement :
      s if s.Sid == "StateLockOnly"
    ]).Resource == ["arn:aws:s3:::bgd-us-east-1-tfstate-590184028094/*.tflock"]
    error_message = "the state grant must be scoped to *.tflock — a plan creates and deletes its own lock and must not be able to write state"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.infra_plan.policy).Statement :
      !contains(s.Resource, "arn:aws:s3:::bgd-us-east-1-tfstate-590184028094/*")
    ])
    error_message = "granting the whole state bucket prefix would let a plan overwrite state, which is exactly what the narrow grant avoids"
  }
}

run "the_validate_role_makes_no_aws_call_at_all" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.infra_validate.policy).Statement :
      alltrue([for a in s.Action : startswith(a, "logs:") || startswith(a, "s3:")])
    ])
    error_message = "validate runs terraform with -backend=false, tflint and checkov — it needs its log group and the artifact bucket and nothing else. A new prefix here means a step was added that reads the account."
  }
}

run "the_pipeline_role_names_everything_it_may_touch" {
  command = plan

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.pipeline.policy).Statement :
      s if s.Sid == "UseTheGitHubConnection"
    ]).Resource == [aws_codeconnections_connection.github.arn]
    error_message = "UseConnection must name this connection, not *; the pipeline role should not be able to read every repository the account ever connects"
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.pipeline.policy).Statement :
      s if s.Sid == "RunTheBuilds"
    ]).Resource == [
      aws_codebuild_project.infra_validate.arn,
      aws_codebuild_project.infra_plan.arn,
      aws_codebuild_project.infra_apply.arn,
    ]
    error_message = "StartBuild on * would let this role run any build project in the account, including Phase 8's, on a trigger it does not own"
  }
}
```

- [ ] **Step 2: Run the suite and see it fail**

```bash
./scripts/tf.sh test foundation
```

Expected: FAIL, naming `aws_iam_role.infra_plan` and the three policy resources as unknown.

- [ ] **Step 3: Write the two trust policies and the pipeline role**

Create `infra/foundation/iam-pipeline.tf`, starting with the shared pieces and the pipeline's own role:

```hcl
# The pipeline's four roles.
#
# Named iam-pipeline.tf rather than iam.tf because these belong to the pipeline
# rather than to the layer, and Phases 8 and 9 add more of them. Phase 3's
# amendment to the roadmap is the rule being followed: each of the design's IAM
# roles is created by the phase that creates the resource it acts on, because a
# policy cannot be scoped to resources that do not exist yet.
#
# Three service roles rather than one, because a CodeBuild build's permissions
# come from `service_role` on the project — action.role_arn is the role
# CodePipeline assumes to *invoke* an action, which is a different thing.
# Plan §F3.
#
# Policies are built with jsonencode rather than aws_iam_policy_document, the
# same rule infra/environments/prod/iam.tf follows and for the same reason:
# mock_provider mocks every data source the AWS provider owns, the policy
# document generator among them despite being a pure local computation. Under
# test it returns a random string, so a policy built through it asserts nothing
# and aws_iam_role rejects it client-side. Phase 5 §F1.
#
# Every Action and Resource is written as a LIST even when it holds one element.
# aws_iam_policy_document collapses singletons to a bare string, which is valid
# IAM and awkward to assert on; writing the JSON by hand means the tests can use
# contains() and == without a type check first.

locals {
  # Shared by the three build roles. The account condition is what stops these
  # being confused-deputy shaped — without it, any CodeBuild project anywhere
  # could assume them given the ARN. It matters most on the apply role, which
  # holds AdministratorAccess.
  codebuild_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codebuild.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })

  codepipeline_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}

# ---------------------------------------------------------------------------
# The pipeline itself. It starts builds and moves artifacts; it never calls
# Terraform and never touches the resources being deployed.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "pipeline" {
  name               = "${local.name_prefix}-infra-pipeline-role"
  assume_role_policy = local.codepipeline_assume_role_policy
}

resource "aws_iam_role_policy" "pipeline" {
  name = "${local.name_prefix}-infra-pipeline-policy"
  role = aws_iam_role.pipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ArtifactStore"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:GetBucketVersioning",
        ]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
      },
      {
        # Named, not wildcarded. This role's whole GitHub reach is one
        # repository through one link; a wildcard would let it read anything
        # else the account ever connects.
        Sid      = "UseTheGitHubConnection"
        Effect   = "Allow"
        Action   = ["codeconnections:UseConnection"]
        Resource = [aws_codeconnections_connection.github.arn]
      },
      {
        # The three projects by ARN, in the order the pipeline uses them.
        # StartBuild on * would let this role run any project in the account,
        # including Phase 8's, on a trigger it does not own.
        Sid    = "RunTheBuilds"
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
          "codebuild:StopBuild",
        ]
        Resource = [
          aws_codebuild_project.infra_validate.arn,
          aws_codebuild_project.infra_plan.arn,
          aws_codebuild_project.infra_apply.arn,
        ]
      },
    ]
  })
}
```

Note the forward reference to `aws_codebuild_project` — Task 3 creates them, and until it does `terraform validate` fails on this file. That is expected and is why the two tasks are adjacent.

- [ ] **Step 4: Write the validate role**

Append:

```hcl
# ---------------------------------------------------------------------------
# Validate. The only role in this project that reads nothing.
#
# `scripts/tf.sh validate` and `terraform test` both init with -backend=false,
# and tflint and checkov read files. So this build makes no AWS API call, and
# the policy below says so — asserted in tests/pipeline_iam.tftest.hcl, because
# the property erodes the first time someone adds a step that needs "just one
# read" and nothing fails when they do. Plan §D6.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "infra_validate" {
  name               = "${local.name_prefix}-infra-validate-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy" "infra_validate" {
  name = "${local.name_prefix}-infra-validate-policy"
  role = aws_iam_role.infra_validate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CreateLogGroup is granted even though Terraform creates the group,
        # because CodeBuild attempts it on every build and an AccessDenied
        # there surfaces as a build failure rather than as a permissions
        # problem.
        Sid    = "OwnLogGroup"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          aws_cloudwatch_log_group.infra_validate.arn,
          "${aws_cloudwatch_log_group.infra_validate.arn}:*",
        ]
      },
      {
        Sid      = "PipelineArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.artifacts.arn}/*"]
      },
    ]
  })
}
```

- [ ] **Step 5: Write the plan role**

Append:

```hcl
# ---------------------------------------------------------------------------
# Plan. ReadOnlyAccess, plus four things it does not reliably cover.
#
# This is the role least privilege is actually worth spending effort on: a plan
# reads the world and writes nothing but a lock, so the restriction costs
# nothing and means a compromised plan build — or an edited buildspec — cannot
# mutate the account. Plan §D6.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "infra_plan" {
  name               = "${local.name_prefix}-infra-plan-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy_attachment" "infra_plan_readonly" {
  role       = aws_iam_role.infra_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "infra_plan" {
  name = "${local.name_prefix}-infra-plan-supplement"
  role = aws_iam_role.infra_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OwnLogGroup"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          aws_cloudwatch_log_group.infra_plan.arn,
          "${aws_cloudwatch_log_group.infra_plan.arn}:*",
        ]
      },
      {
        Sid      = "PipelineArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.artifacts.arn}/*"]
      },
      {
        # Scoped to the lock file, not to the bucket prefix. Terraform's native
        # S3 locking writes <key>.tflock beside the state; this lets a plan
        # create and delete its own lock and still leaves it unable to write
        # state at all. Asserted both ways in tests/pipeline_iam.tftest.hcl —
        # once that the narrow grant is present, and once that the broad one is
        # not.
        Sid      = "StateLockOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${local.name_prefix}-tfstate-${var.account_id}/*.tflock"]
      },
      {
        # ReadOnlyAccess is an AWS-managed policy and lags new services and
        # renamed API prefixes. Both spellings of the connection API are
        # granted because the service was renamed and the provider keeps the
        # old one for compatibility (Phase 3 §F1) — a managed policy may carry
        # one and not the other. Plan §F5.
        Sid    = "ReadTheGitHubConnection"
        Effect = "Allow"
        Action = [
          "codeconnections:GetConnection",
          "codeconnections:ListTagsForResource",
          "codestar-connections:GetConnection",
          "codestar-connections:ListTagsForResource",
        ]
        Resource = [aws_codeconnections_connection.github.arn]
      },
      {
        # Granted explicitly although ReadOnlyAccess almost certainly covers
        # it: a plan that cannot read the image tag fails inside
        # data.aws_ecr_image with a message about a missing image rather than
        # about a missing permission, which is a slow way to find a fast
        # problem.
        Sid      = "ReadTheImageTags"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [for env in local.image_tag_environments : aws_ssm_parameter.image_tag[env].arn]
      },
    ]
  })
}
```

The `for` over `local.image_tag_environments` rather than over the resource map is deliberate: it fixes the order of the two ARNs, so the rendered JSON is stable across plans and a diff on this policy means the policy changed.

- [ ] **Step 6: Write the apply role**

Append:

```hcl
# ---------------------------------------------------------------------------
# Apply. AdministratorAccess, and the reason is written down rather than
# implied.
#
# This role creates IAM roles in four layers. A principal that can create a
# role and attach a policy to it can grant itself anything, so a narrower
# policy here would describe a boundary that does not exist — while failing at
# apply time in whichever layer it forgot and needing an extension from every
# future phase.
#
# Phase 6's D5 reached an opposite-looking conclusion for the blue/green
# controller by the same rule: write the policy that is honest about the
# boundary, not the one that looks strict.
#
# The control that stands between a merge and a production change is not this
# role. It is the manual approval on a plan a human read, and the fact that the
# apply applies that plan file rather than deciding again. Plan §D6 and §D9.
#
# The account condition on the trust policy therefore does more work here than
# anywhere else in the project: it is the only thing narrowing who can assume
# a role that can do anything.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "infra_apply" {
  name               = "${local.name_prefix}-infra-apply-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy_attachment" "infra_apply_admin" {
  # checkov:skip=CKV_AWS_274:Deliberate, and argued in the plan's §D6. This role creates IAM roles in four layers; a principal that can create a role and attach a policy can already grant itself anything, so a narrower policy would describe a boundary that does not exist. The real control is the manual approval on a plan a human read.
  role       = aws_iam_role.infra_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
```

The apply role gets no inline policy: `AdministratorAccess` already covers its log group and the artifact bucket, and adding a redundant one would suggest the managed policy was somehow scoped.


- [ ] **Step 7: Run the suite**

```bash
./scripts/tf.sh test foundation
```

Expected: still FAIL, now only on the three `aws_codebuild_project` and three `aws_cloudwatch_log_group` references Task 3 creates. Read the failure and confirm it names exactly those six and nothing else — if it names an IAM resource, Steps 3 to 6 have a typo.

- [ ] **Step 8: Commit**

```bash
git add infra/foundation/iam-pipeline.tf infra/foundation/tests/pipeline_iam.tftest.hcl
git commit -m "feat(infra): four pipeline roles, with plan read-only and apply administrator"
```

---

### Task 3: The three CodeBuild projects and their log groups

**Files:**
- Create: `infra/foundation/codebuild.tf`
- Modify: `infra/foundation/tests/pipeline_shape.tftest.hcl`

**Interfaces:**
- Consumes: the four roles from Task 2, `var.pipeline_log_retention_days`.
- Produces: `aws_codebuild_project.infra_validate`, `.infra_plan`, `.infra_apply`; `aws_cloudwatch_log_group.infra_validate`, `.infra_plan`, `.infra_apply`.

- [ ] **Step 1: Write the failing project assertions**

Append to `infra/foundation/tests/pipeline_shape.tftest.hcl`:

```hcl
run "only_the_validate_project_runs_containers" {
  command = plan

  assert {
    condition     = one(aws_codebuild_project.infra_validate.environment).privileged_mode
    error_message = "scripts/lint-infra.sh runs tflint and checkov from digest-pinned containers; without privileged mode docker cannot start"
  }

  assert {
    condition = !one(aws_codebuild_project.infra_plan.environment).privileged_mode &&
    !one(aws_codebuild_project.infra_apply.environment).privileged_mode
    error_message = "plan and apply run no containers; privileged mode there is reach nobody asked for"
  }
}

run "every_project_is_x86_because_the_lint_digests_are" {
  command = plan

  assert {
    condition = alltrue([
      for p in [aws_codebuild_project.infra_validate, aws_codebuild_project.infra_plan, aws_codebuild_project.infra_apply] :
      one(p.environment).type == "LINUX_CONTAINER"
    ])
    error_message = "ARM_CONTAINER would pull the pinned tflint and checkov digests on arm64, which local runs cannot prove exist — Docker Desktop emulates amd64 transparently. Plan §D7."
  }
}

run "each_project_runs_its_own_buildspec_under_its_own_role" {
  command = plan

  assert {
    condition = one(aws_codebuild_project.infra_plan.source).buildspec == "pipelines/infra-plan.yml" &&
    one(aws_codebuild_project.infra_apply.source).buildspec == "pipelines/infra-apply.yml" &&
    one(aws_codebuild_project.infra_validate.source).buildspec == "pipelines/infra-validate.yml"
    error_message = "a project pointing at the wrong buildspec plans when it should apply, and nothing about the pipeline shape reveals it"
  }

  assert {
    condition = aws_codebuild_project.infra_plan.service_role == aws_iam_role.infra_plan.arn &&
    aws_codebuild_project.infra_apply.service_role == aws_iam_role.infra_apply.arn
    error_message = "the service role is where a build's permissions come from (plan §F3); crossing these gives the plan build administrator"
  }
}

run "the_build_log_groups_have_retention" {
  command = plan

  assert {
    condition = alltrue([
      for g in [aws_cloudwatch_log_group.infra_validate, aws_cloudwatch_log_group.infra_plan, aws_cloudwatch_log_group.infra_apply] :
      g.retention_in_days == 30
    ])
    error_message = "CodeBuild creates its own group without retention if Terraform does not; logs then accumulate forever at a cost nobody attributes"
  }
}
```

- [ ] **Step 2: Run the suite and see the new runs fail**

```bash
./scripts/tf.sh test foundation
```

- [ ] **Step 3: Write `codebuild.tf`**

```hcl
# The three projects that execute the infra pipeline.
#
# Three rather than one because a build's permissions come from `service_role`,
# which is a property of the project — `action.role_arn` on a CodePipeline
# action is the role CodePipeline assumes to *invoke* the action, which is a
# different thing (plan §F3). Three roles that differ in what a build may do
# therefore means three projects.
#
# Which LAYER a build works on is not a property of the project. It is passed
# per action through the CodeBuild action's EnvironmentVariables override, so
# eight actions — four plans and four applies — share two projects.

locals {
  # x86_64 for all three. scripts/lint-infra.sh runs tflint and checkov from
  # digest-pinned containers, and those digests passing on the development
  # machine does not prove they have linux/arm64 variants: Docker Desktop runs
  # amd64 images transparently under emulation. CodeBuild does not. amd64 is
  # the side that is certainly safe for both pins, and Terraform is
  # architecture-agnostic. Phase 8's app build is ARM because its image is.
  # Plan §D7.
  codebuild_image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
  codebuild_compute_type = "BUILD_GENERAL1_SMALL"
}

resource "aws_cloudwatch_log_group" "infra_validate" {
  name              = "/bgd/${var.region}/shared/infra-validate"
  retention_in_days = var.pipeline_log_retention_days
}

resource "aws_cloudwatch_log_group" "infra_plan" {
  name              = "/bgd/${var.region}/shared/infra-plan"
  retention_in_days = var.pipeline_log_retention_days
}

resource "aws_cloudwatch_log_group" "infra_apply" {
  name              = "/bgd/${var.region}/shared/infra-apply"
  retention_in_days = var.pipeline_log_retention_days
}

# The gate, and the only project that needs docker.
resource "aws_codebuild_project" "infra_validate" {
  # checkov:skip=CKV_AWS_147:SSE-S3 and AWS-owned keys throughout, decided once in the Phase 3 plan §D4 and applied to every encrypted-at-rest resource here. A customer-managed key costs a monthly charge and its own policy for build logs that are reproducible from the commit.
  name          = "${local.name_prefix}-infra-validate-build"
  service_role  = aws_iam_role.infra_validate.arn
  build_timeout = 20

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = local.codebuild_compute_type
    image        = local.codebuild_image
    type         = "LINUX_CONTAINER"

    # checkov:skip=CKV_AWS_316:Docker-in-docker is how scripts/lint-infra.sh runs its digest-pinned tflint and checkov containers — the identical command used locally, installing nothing on the host. Removing it means installing both tools into the build image at floating versions, which is the drift the pins exist to prevent. Plan §F9.
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/infra-validate.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.infra_validate.name
      stream_name = "build"
    }
  }
}

resource "aws_codebuild_project" "infra_plan" {
  # checkov:skip=CKV_AWS_147:Same decision as infra_validate above, and as every other encrypted-at-rest resource in this project. Phase 3 plan §D4.
  name         = "${local.name_prefix}-infra-plan-build"
  service_role = aws_iam_role.infra_plan.arn

  # Longer than validate's because a plan on prod refreshes an ECS service, two
  # DynamoDB tables, an ALB with three listeners and three Lambda functions.
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = local.codebuild_compute_type
    image        = local.codebuild_image
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/infra-plan.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.infra_plan.name
      stream_name = "build"
    }
  }
}

resource "aws_codebuild_project" "infra_apply" {
  # checkov:skip=CKV_AWS_147:Same decision as infra_validate above, and as every other encrypted-at-rest resource in this project. Phase 3 plan §D4.
  name         = "${local.name_prefix}-infra-apply-build"
  service_role = aws_iam_role.infra_apply.arn

  # 60 minutes, and prod is why. Its service sets wait_for_steady_state, so an
  # apply that starts a blue/green deployment does not return until green has
  # been provisioned, tested by three hooks, promoted and baked for five
  # minutes under the alarms — six to ten minutes when it goes well, and this
  # timeout should not be the thing that decides when it has gone badly.
  # Phase 6 plan §D11.
  build_timeout = 60

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = local.codebuild_compute_type
    image        = local.codebuild_image
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipelines/infra-apply.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.infra_apply.name
      stream_name = "build"
    }
  }
}
```

- [ ] **Step 4: Run the suite**

```bash
./scripts/tf.sh test foundation
```

Expected: PASS for every run in `pipeline_iam.tftest.hcl` and for the project runs in `pipeline_shape.tftest.hcl`. The layer and SSM runs from Task 1 still pass. Nothing yet asserts on the pipeline itself.

- [ ] **Step 5: Commit**

```bash
git add infra/foundation/codebuild.tf infra/foundation/tests/pipeline_shape.tftest.hcl
git commit -m "feat(infra): three CodeBuild projects and their retained log groups"
```

---

### Task 4: `install-terraform.sh` and the three buildspecs

The executable content, written before the pipeline that references it so that the buildspec paths in Task 3 stop being promises.

**Files:**
- Create: `scripts/install-terraform.sh`
- Create: `pipelines/infra-validate.yml`, `pipelines/infra-plan.yml`, `pipelines/infra-apply.yml`
- Modify: `pipelines/README.md`

**Interfaces:**
- Consumes: `.terraform-version` (currently `1.15.7`), `scripts/lib/common.sh`.
- Produces: `terraform` on `PATH` inside the build; `plan-vars.env` at the workspace root, read by `pipelines/infra-plan.yml`.

- [ ] **Step 1: Write `scripts/install-terraform.sh`**

```bash
#!/usr/bin/env bash
#
# Install the pinned Terraform into a CodeBuild container.
#
# CodeBuild's standard images ship language runtimes, not Terraform. The
# version comes from .terraform-version — the same file tfenv reads on the
# development machine — so the pipeline and that machine cannot drift, which is
# the property a `hashicorp/terraform` image would lose by putting the version
# in a second place. Plan §D14.
#
# The checksum is pinned here beside the version. Re-record both together with:
#
#   curl -sS https://releases.hashicorp.com/terraform/<version>/terraform_<version>_SHA256SUMS \
#     | grep linux_amd64
#
# linux_amd64 because all three infra CodeBuild projects are LINUX_CONTAINER
# (plan §D7). Phase 8's app build is ARM and does not use this script.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd curl
require_cmd unzip
require_cmd sha256sum

ROOT="$(repo_root)"

VERSION="$(tr -d '[:space:]' <"$ROOT/.terraform-version")"

# Pinned 2026-08-29 for 1.15.7. A version bump that does not bump this line
# fails the checksum rather than installing something unverified.
EXPECTED_SHA256="73bbb8f5188ad75d4fb853fd100ae4d7e146ef7af7db18776109642fdb7759d2"

ZIP="terraform_${VERSION}_linux_amd64.zip"
URL="https://releases.hashicorp.com/terraform/${VERSION}/${ZIP}"
DEST="${TERRAFORM_INSTALL_DIR:-/usr/local/bin}"

# Idempotent: CodeBuild caches nothing between actions, but a local run of this
# script for debugging should not re-download.
if command -v terraform >/dev/null 2>&1 &&
  [[ "$(extract_version "$(terraform version)")" == "$VERSION" ]]; then
  ok "terraform $VERSION already installed"
  exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

info "downloading terraform $VERSION"
curl -fsSL --retry 3 --retry-delay 2 -o "$workdir/$ZIP" "$URL"

actual="$(sha256sum "$workdir/$ZIP" | cut -d' ' -f1)"
[[ "$actual" == "$EXPECTED_SHA256" ]] ||
  die "checksum mismatch for $ZIP — expected $EXPECTED_SHA256, got $actual"

unzip -q -o "$workdir/$ZIP" -d "$workdir"
install -m 0755 "$workdir/terraform" "$DEST/terraform"

ok "terraform $("$DEST/terraform" version | head -1)"
```

- [ ] **Step 2: Verify the script is syntactically valid and the checksum is the recorded one**

```bash
bash -n scripts/install-terraform.sh && chmod +x scripts/install-terraform.sh
grep -c 73bbb8f5188ad75d4fb853fd100ae4d7e146ef7af7db18776109642fdb7759d2 scripts/install-terraform.sh
```

Expected: no output from `bash -n`, and `1` from `grep -c`. If a network connection is available, confirm the pin against the source:

```bash
curl -sS https://releases.hashicorp.com/terraform/1.15.7/terraform_1.15.7_SHA256SUMS | grep linux_amd64
```

Expected: `73bbb8f5188ad75d4fb853fd100ae4d7e146ef7af7db18776109642fdb7759d2  terraform_1.15.7_linux_amd64.zip`

- [ ] **Step 3: Write `pipelines/infra-validate.yml`**

```yaml
# The infra pipeline's gate. Runs the identical make targets you run locally,
# which is what makes a green pipeline and a green laptop mean the same thing.
#
# No AWS credentials are used here and none are available: scripts/tf.sh
# initialises validate and test with -backend=false, and tflint and checkov
# read files. The project's service role grants its log group and the artifact
# bucket, and nothing else. Plan §D6.
version: 0.2

phases:
  install:
    commands:
      - ./scripts/install-terraform.sh

  build:
    commands:
      # Ordered cheapest-first so a formatting mistake fails in seconds rather
      # than after the container pulls. tf-lint is last because it is the only
      # step that pulls two images.
      - make tf-fmt-check
      - make tf-validate
      - make tf-test
      - make tf-lint
```

- [ ] **Step 4: Write `pipelines/infra-plan.yml`**

```yaml
# Plan one layer and publish the workspace, saved plan included, for the Apply
# action in the same stage to consume. Plan §D9.
#
# LAYER and DEPLOY_SCOPE arrive as EnvironmentVariables overrides on the
# CodePipeline action — the project is shared by all four layers, so neither
# can be set here.
version: 0.2

env:
  # Read by the stage's manual approval action as #{Plan<Title>.PLAN_SUMMARY}
  # and #{Plan<Title>.PLAN_URL}. Renaming one of these does not fail anything:
  # the approval message simply shows the literal placeholder. A test in
  # infra/foundation/tests/pipeline_shape.tftest.hcl asserts these names still
  # match local.plan_exported_variables.
  exported-variables:
    - PLAN_STATUS
    - PLAN_SUMMARY
    - PLAN_URL

phases:
  install:
    commands:
      - ./scripts/install-terraform.sh

  build:
    commands:
      - ./scripts/pipeline-terraform.sh plan "$LAYER"
      # The script runs as a child process, so its exports do not reach this
      # shell. It writes the three variables to plan-vars.env instead and this
      # sources them into the environment CodeBuild reads exported-variables
      # from. `set -a` is what marks them exported.
      - set -a && . ./plan-vars.env && set +a

artifacts:
  # The whole workspace, so Apply gets the source tree and the saved plan
  # together. .terraform/ is excluded and Apply re-inits: the directory is
  # provider binaries, roughly 700 MB of them, and re-downloading from the
  # committed .terraform.lock.hcl gives byte-identical versions in less time
  # than uploading and downloading them costs.
  files:
    - '**/*'
  exclude-paths:
    - '**/.terraform/**'
```

- [ ] **Step 5: Write `pipelines/infra-apply.yml`**

```yaml
# Apply the plan the approval approved. Not a new one. Plan §D9.
#
# The input artifact is the Plan action's output, so the saved plan is already
# in the workspace at infra/<layer>/pipeline.tfplan. No -var is passed and none
# may be: `terraform apply <planfile>` rejects variables, because the plan file
# already contains the values it was made with.
version: 0.2

phases:
  install:
    commands:
      - ./scripts/install-terraform.sh

  build:
    commands:
      - ./scripts/pipeline-terraform.sh apply "$LAYER"
```

- [ ] **Step 6: Update `pipelines/README.md`**

Replace the table with one that reflects what now exists:

```markdown
| Buildspec | Pipeline | Phase | Status |
|---|---|---|---|
| [`infra-validate.yml`](./infra-validate.yml) — `make tf-fmt-check tf-validate tf-test tf-lint` | infra | 7 | built |
| [`infra-plan.yml`](./infra-plan.yml) — plan one layer, export the summary | infra | 7 | built |
| [`infra-apply.yml`](./infra-apply.yml) — apply the saved plan | infra | 7 | built |
| app build, test, image, SBOM | app | 8 | planned |
```

and add, below the existing "not to be confused with `.github/`" note:

```markdown
**Buildspecs here stay three lines.** The makefile states the convention for
this repository — make is the front door, scripts hold the logic — and it
applies here for a stronger reason: a buildspec cannot be run locally, so logic
that lives in one is logic nobody can test before merging it. The infra
buildspecs call `make` or `scripts/pipeline-terraform.sh`; neither branches.
```

- [ ] **Step 7: Verify the YAML parses**

```bash
python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]; print('ok')" \
  pipelines/infra-validate.yml pipelines/infra-plan.yml pipelines/infra-apply.yml
```

Expected: `ok`. This uses the system interpreter rather than the project virtualenv deliberately — it is a one-line syntax check on three files, not a reason to make the infra gate depend on `app/.venv`.

- [ ] **Step 8: Commit**

```bash
git add scripts/install-terraform.sh pipelines/
git commit -m "feat(pipelines): the pinned terraform install and the three infra buildspecs"
```

---

### Task 5: `pipeline-terraform.sh` — the scope gate, the image tag, the plan and the apply

The most consequential file in the phase, because it is the gate D4 relies on being right when the stage condition is not.

**Files:**
- Create: `scripts/pipeline-terraform.sh`
- Modify: `scripts/README.md`

**Interfaces:**
- Consumes: `DEPLOY_SCOPE` and `LAYER` from the environment; `scripts/tf.sh` for the layer-name-to-directory mapping and the init; `/bgd/<env>/image_tag` from SSM for the two environment layers.
- Produces: `infra/<layer>/pipeline.tfplan` in `plan` mode; `plan-vars.env` at the repository root with `PLAN_STATUS`, `PLAN_SUMMARY`, `PLAN_URL`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
#
# The infra pipeline's Terraform driver: one script, two modes.
#
#   scripts/pipeline-terraform.sh plan  <layer>
#   scripts/pipeline-terraform.sh apply <layer>
#
# Called only from CodeBuild, by pipelines/infra-plan.yml and
# pipelines/infra-apply.yml. Local work still goes through `make plan-<layer>`
# and `make apply-<layer>`, which call scripts/tf.sh — and so does this, which
# is why the layer-name-to-directory mapping appears here nowhere. That map
# already exists in three places (tf.sh, lint-infra.sh, teardown.sh) and a
# fourth copy would be a fourth thing to forget.
#
# Three things it does that scripts/tf.sh deliberately does not:
#
#  1. It enforces DEPLOY_SCOPE itself. The pipeline already skips out-of-scope
#     stages with a before_entry condition, so this is the second of two
#     independent gates. The redundancy is deliberate and the asymmetry is the
#     point: if the condition is wrong in the direction of entering a stage it
#     should have skipped, this refuses and the cost is an approval nobody
#     wanted. If this were absent and the condition were wrong that way, a
#     DEPLOY_SCOPE=network run would apply production. Plan §D4.
#
#  2. It supplies image_tag from SSM for the two environment layers, because
#     terraform.tfvars is gitignored and does not exist in a CodeBuild
#     workspace. Plan §D8.
#
#  3. It exports the plan summary the manual approval displays, so the approval
#     is an informed decision rather than a reflex.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform
require_cmd aws

ROOT="$(repo_root)"

# Relative to the layer directory, because scripts/tf.sh runs terraform with
# -chdir. Named to match .gitignore's *.tfplan, so a copy pulled down for
# debugging cannot be committed.
PLAN_FILE="pipeline.tfplan"
VARS_FILE="$ROOT/plan-vars.env"

mode="${1:-}"
layer="${2:-}"
[[ -n "$mode" && -n "$layer" ]] || die "usage: pipeline-terraform.sh <plan|apply> <layer>"

# Cumulative scope: the value names the LAST layer a run applies, so a rank
# comparison is the whole rule. An unrecognised scope ranks 0, which is below
# every layer, so nothing runs — and it is rejected by name below rather than
# being allowed to behave like a silent `foundation`. Plan §D3.
scope_rank() {
  case "$1" in
    foundation) echo 1 ;;
    network) echo 2 ;;
    staging) echo 3 ;;
    all) echo 4 ;;
    *) echo 0 ;;
  esac
}

layer_rank() {
  case "$1" in
    foundation) echo 1 ;;
    network) echo 2 ;;
    staging) echo 3 ;;
    prod) echo 4 ;;
    *) echo 99 ;;
  esac
}

# Written on every path out of plan mode, including the skip. Without the skip
# case the approval action would interpolate the previous execution's summary,
# which is a worse failure than an empty one — it describes changes that are
# not in this run.
write_vars() {
  local status="$1" summary="$2" url="$3"
  {
    printf 'PLAN_STATUS=%q\n' "$status"
    printf 'PLAN_SUMMARY=%q\n' "$summary"
    printf 'PLAN_URL=%q\n' "$url"
  } >"$VARS_FILE"
}

# The CodeBuild console deep link for this build, so the approval message can
# offer the full plan behind the truncated summary. Built from the build ARN
# because that is the only place the account id appears in a CodeBuild
# environment. Empty outside CodeBuild, which is harmless — the field is
# optional.
build_url() {
  [[ -n "${CODEBUILD_BUILD_ARN:-}" ]] || return 0
  local _ arn_region arn_account project
  IFS=':' read -r _ _ _ arn_region arn_account _ <<<"$CODEBUILD_BUILD_ARN"
  project="${CODEBUILD_BUILD_ID%%:*}"
  printf 'https://%s.console.aws.amazon.com/codesuite/codebuild/%s/projects/%s/build/%s/?region=%s' \
    "$arn_region" "$arn_account" "$project" "${CODEBUILD_BUILD_ID//:/%3A}" "$arn_region"
}

# ---------------------------------------------------------------------------
# Gate 1 of 1 in this script, and gate 2 of 2 in the pipeline.
# ---------------------------------------------------------------------------

scope="${DEPLOY_SCOPE:-}"
[[ -n "$scope" ]] ||
  die "DEPLOY_SCOPE is unset — the pipeline action must pass it as an EnvironmentVariables override"

(($(scope_rank "$scope") > 0)) ||
  die "DEPLOY_SCOPE is '$scope'; expected one of foundation, network, staging, all"

(($(layer_rank "$layer") < 99)) ||
  die "unknown layer: $layer (expected foundation, network, staging or prod)"

# Before the saved-plan check below, deliberately. An out-of-scope apply must
# report a skip, not die on a plan file the skipped plan never wrote.
if (($(layer_rank "$layer") > $(scope_rank "$scope"))); then
  info "$layer is outside DEPLOY_SCOPE=$scope — nothing to do"
  if [[ "$mode" == "plan" ]]; then
    write_vars "skipped" "Skipped. $layer is outside DEPLOY_SCOPE=$scope." "$(build_url)"
  fi
  exit 0
fi

case "$mode" in
  plan) ;;
  apply) ;;
  *) die "unknown mode: $mode (expected plan or apply)" ;;
esac

# ---------------------------------------------------------------------------
# apply — the saved plan, and only the saved plan
# ---------------------------------------------------------------------------

if [[ "$mode" == "apply" ]]; then
  case "$layer" in
    foundation | network) dir="infra/$layer" ;;
    *) dir="infra/environments/$layer" ;;
  esac

  [[ -f "$ROOT/$dir/$PLAN_FILE" ]] ||
    die "no saved plan at $dir/$PLAN_FILE — the Plan action in this stage must run first"

  # No -var, and none is permitted: terraform rejects variables when applying a
  # saved plan, because the plan already holds the values it was made with.
  # This is also what makes the approval meaningful — the plan a human read is
  # the plan that runs. Plan §D9.
  #
  # A stale-plan error here means the layer's state moved between the plan and
  # this apply, almost always a local `make apply-<layer>` racing the pipeline.
  # Failing is correct; the runbook says what to do about it.
  info "applying the saved plan for $layer"
  "$ROOT/scripts/tf.sh" apply "$layer" -input=false -lock-timeout=5m "$PLAN_FILE"
  ok "$layer applied"
  exit 0
fi

# ---------------------------------------------------------------------------
# plan — resolve the image tag, plan, summarise
# ---------------------------------------------------------------------------

tf_vars=()

case "$layer" in
  staging | prod)
    param="/bgd/${layer}/image_tag"

    tag="$(aws ssm get-parameter --name "$param" --query 'Parameter.Value' --output text 2>/dev/null)" ||
      die "cannot read $param — apply the foundation layer before planning $layer"

    if [[ -z "$tag" || "$tag" == "unset" || "$tag" == "None" ]]; then
      die "$param is '$tag' — run 'make seed-ecr' to record the seeded tag, or let the app pipeline set it (Phase 8)"
    fi

    info "image_tag for $layer comes from $param → $tag"
    tf_vars=(-var "image_tag=$tag")
    ;;
esac

# -detailed-exitcode is what separates "no changes" from "changes" without
# parsing prose: 0 means empty, 2 means there is a diff, 1 means the plan
# failed. Under `set -e` the 2 has to be caught, hence the `|| status=$?`.
info "planning $layer"

status=0
"$ROOT/scripts/tf.sh" plan "$layer" \
  -input=false \
  -lock-timeout=5m \
  -detailed-exitcode \
  -out="$PLAN_FILE" \
  ${tf_vars[@]+"${tf_vars[@]}"} || status=$?

case "$layer" in
  foundation | network) dir="infra/$layer" ;;
  *) dir="infra/environments/$layer" ;;
esac

case "$status" in
  0)
    summary="No changes. $layer is up to date."
    ok "$summary"
    ;;
  2)
    # `terraform show` on the saved plan rather than scraping the plan output,
    # so the summary describes the artifact Apply will consume rather than the
    # text that scrolled past. The Plan: line first, then the resource
    # addresses, which is the order someone reads an approval in.
    summary="$(
      terraform -chdir="$ROOT/$dir" show -no-color "$PLAN_FILE" |
        grep -E '^(Plan:|  # )' |
        sed 's/^  # //'
    )"
    ;;
  *)
    die "terraform plan failed for $layer (exit $status)"
    ;;
esac

# One line, and short. A CodePipeline variable and a manual approval's
# CustomData are both capped at 1000 characters, and a newline inside a
# KEY=value line would break the `. plan-vars.env` the buildspec does. The
# full plan is one click away through PLAN_URL, which is the point of
# exporting it.
summary="$(printf '%s' "$summary" | tr '\n' ' ' | tr -s ' ')"
if ((${#summary} > 900)); then
  summary="${summary:0:880} … (truncated; full plan in the build log)"
fi

write_vars "$status" "$summary" "$(build_url)"

info "plan summary: $summary"
```

- [ ] **Step 2: Verify the script parses and the scope logic is right**

```bash
bash -n scripts/pipeline-terraform.sh && chmod +x scripts/pipeline-terraform.sh
```

Then exercise the gate without Terraform, which is the part D4 depends on. The script exits 0 with a skip message for out-of-scope layers, and reaches Terraform for in-scope ones:

```bash
for scope in foundation network staging all bogus; do
  for layer in foundation network staging prod; do
    printf '%-11s %-11s ' "$scope" "$layer"
    DEPLOY_SCOPE=$scope ./scripts/pipeline-terraform.sh plan $layer >/dev/null 2>&1 \
      && echo "ran or skipped (exit 0)" || echo "refused (exit $?)"
  done
done
```

Expected: for `bogus`, all four refuse. For the other four scopes, the cells below the diagonal in D3's table are the ones that exit 0 having skipped — confirm by reading the message rather than the exit code:

```bash
DEPLOY_SCOPE=network ./scripts/pipeline-terraform.sh plan prod
```

Expected: `==> prod is outside DEPLOY_SCOPE=network — nothing to do`, exit 0, and `plan-vars.env` containing `PLAN_STATUS=skipped`.

In-scope invocations will fail at Terraform for want of an AWS session, which is expected on this machine and is not what this step is testing.

- [ ] **Step 3: Confirm the skip writes the variables file**

```bash
DEPLOY_SCOPE=foundation ./scripts/pipeline-terraform.sh plan prod >/dev/null && cat plan-vars.env
```

Expected:

```
PLAN_STATUS=skipped
PLAN_SUMMARY=Skipped.\ prod\ is\ outside\ DEPLOY_SCOPE=foundation.
PLAN_URL=''
```

The `%q` quoting is what makes `set -a && . ./plan-vars.env` safe for a summary containing spaces. Then remove the file so it is not committed:

```bash
rm -f plan-vars.env
```

- [ ] **Step 4: Add `plan-vars.env` to `.gitignore`**

Under the existing `# Local scratch` heading:

```
# Written by scripts/pipeline-terraform.sh for the buildspec to source. A
# CodeBuild-only file that a local debugging run also produces.
plan-vars.env
```

- [ ] **Step 5: Note both scripts in `scripts/README.md`**

Add two rows to the table, after the `seed-ecr.sh` row:

```markdown
| `install-terraform.sh` | 7 — the pinned Terraform install, for CodeBuild only |
| `pipeline-terraform.sh` | 7 — the pipeline's plan/apply driver, scope gate and plan summary |
```

and a paragraph below the table, because these two break the pattern every row above them follows:

```markdown
The last two are the only scripts here that no `make` target calls. They are
entry points for CodeBuild, invoked by the buildspecs under `pipelines/`, and
they are in this directory rather than in that one for the reason the makefile
gives for its own three-line rule: a buildspec cannot be run locally, so logic
that lives in one is logic nobody can test before merging it.
`pipeline-terraform.sh` still calls `tf.sh` for the layer-name-to-directory
mapping rather than carrying a fourth copy of it.
```

- [ ] **Step 6: Commit**

```bash
git add scripts/pipeline-terraform.sh scripts/README.md .gitignore
git commit -m "feat(scripts): the pipeline's terraform driver, scope gate and plan summary"
```

---

### Task 6: The pipeline — six stages, the variable, the trigger and the conditions

The centre of the phase. Everything before it exists so this file can be short.

**Files:**
- Create: `infra/foundation/codepipeline.tf`
- Modify: `infra/foundation/tests/pipeline_shape.tftest.hcl`

**Interfaces:**
- Consumes: `aws_iam_role.pipeline`, the three CodeBuild projects, `aws_s3_bucket.artifacts`, `aws_codeconnections_connection.github`, `local.pipeline_layers`, `var.deploy_scope_default`, `var.github_repository_id`, `var.github_branch`.
- Produces: `aws_codepipeline.infra`.

- [ ] **Step 1: Write the failing pipeline assertions**

Append to `infra/foundation/tests/pipeline_shape.tftest.hcl`:

```hcl
run "the_stages_are_source_validate_then_the_four_layers_in_order" {
  command = plan

  assert {
    condition = [for s in aws_codepipeline.infra.stage : s.name] == [
      "Source", "Validate", "Foundation", "Network", "Staging", "Prod"
    ]
    error_message = "stage order is dependency order; staging reads network's outputs through remote state and prod must be last"
  }

  assert {
    condition     = aws_codepipeline.infra.pipeline_type == "V2"
    error_message = "variable, trigger and before_entry are all V2-only, and a V1 pipeline rejects them at apply rather than at plan"
  }

  assert {
    condition     = aws_codepipeline.infra.execution_mode == "QUEUED"
    error_message = "SUPERSEDED would cancel a run whose approval is open, or one mid-apply, when a second merge lands (plan §D11)"
  }
}

run "every_layer_stage_plans_then_approves_then_applies" {
  command = plan

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : (
        [for a in s.action : a.name] == ["Plan", "Approve", "Apply"] &&
        [for a in s.action : a.run_order] == [1, 2, 3]
      ) if contains(["Foundation", "Network", "Staging", "Prod"], s.name)
    ])
    error_message = "each layer stage is three ordered actions in one stage — the skip condition is stage-level, so splitting them could strand an approval (plan §D2)"
  }

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : (
        [for a in s.action : a.category if a.name == "Approve"] == ["Approval"]
      ) if contains(["Foundation", "Network", "Staging", "Prod"], s.name)
    ])
    error_message = "the middle action must be a manual approval; the roadmap's gate is a human, not a rule"
  }
}

run "apply_consumes_the_plan_action_output_and_never_replans" {
  command = plan

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : (
        [for a in s.action : a.output_artifacts if a.name == "Plan"] ==
        [for a in s.action : a.input_artifacts if a.name == "Apply"]
      ) if contains(["Foundation", "Network", "Staging", "Prod"], s.name)
      ])
    error_message = "the approval approves a plan file; if Apply does not consume Plan's artifact it computes a new one and the approval meant nothing (plan §D9)"
  }

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : (
        [for a in s.action : a.configuration["ProjectName"] if a.name == "Apply"] ==
        ["bgd-us-east-1-infra-apply-build"]
      ) if contains(["Foundation", "Network", "Staging", "Prod"], s.name)
    ])
    error_message = "an Apply action pointed at the plan project applies nothing and reports success"
  }
}

run "only_the_three_later_stages_are_scope_gated" {
  command = plan

  assert {
    condition = length([
      for s in aws_codepipeline.infra.stage : s if length(s.before_entry) > 0
    ]) == 3
    error_message = "network, staging and prod are conditional; foundation runs under every scope so a condition there could only evaluate true"
  }

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : alltrue([
        for c in s.before_entry[0].condition : c.result == "SKIP"
      ]) if length(s.before_entry) > 0
    ])
    error_message = "the result must be SKIP, not FAIL — an out-of-scope stage leaves the execution green, or Phase 9's change-failure-rate counts a deliberate stop as a failure"
  }

  assert {
    condition = [
      for s in aws_codepipeline.infra.stage :
      s.before_entry[0].condition[0].rule[0].configuration["Value"]
      if s.name == "Prod"
    ] == ["all"]
    error_message = "production runs under exactly one scope, and equality is the operator a VariableCheck certainly has (plan §F2)"
  }
}

run "the_trigger_filters_the_paths_the_pipeline_actually_owns" {
  command = plan

  assert {
    condition = toset(aws_codepipeline.infra.trigger[0].git_configuration[0].push[0].file_paths[0].includes) == toset([
      "infra/**", "pipelines/**", "scripts/pipeline-*.sh", "scripts/install-terraform.sh"
    ])
    error_message = "scripts/** as a whole would cross-trigger a four-approval infra run on every app change; infra/** alone would ignore edits to the pipeline's own logic (plan §D12)"
  }

  assert {
    condition     = aws_codepipeline.infra.stage[0].action[0].configuration["DetectChanges"] == "false"
    error_message = "DetectChanges creates a second, unfiltered webhook that fires on every push to the branch, and terraform plan stays clean forever (plan §D13)"
  }
}

run "deploy_scope_is_an_execution_variable_defaulting_to_all" {
  command = plan

  assert {
    condition     = aws_codepipeline.infra.variable[0].name == "DEPLOY_SCOPE"
    error_message = "the roadmap names this variable, and scripts/pipeline-terraform.sh reads it by that name"
  }

  assert {
    condition     = aws_codepipeline.infra.variable[0].default_value == "all"
    error_message = "a git-triggered run cannot set variables, so the default is the policy: every infra merge reaches production, gated by four approvals (plan §F4)"
  }
}

run "the_approval_shows_the_plan_it_is_approving" {
  command = plan

  assert {
    condition = alltrue([
      for s in aws_codepipeline.infra.stage : alltrue([
        for a in s.action :
        strcontains(a.configuration["CustomData"], ".PLAN_SUMMARY}")
        if a.name == "Approve"
      ]) if contains(["Foundation", "Network", "Staging", "Prod"], s.name)
    ])
    error_message = "an approval with no plan in the message is a reflex, not a decision — the roadmap asks for the plan output in the approval"
  }
}

run "the_buildspec_still_exports_what_the_approval_interpolates" {
  command = plan

  assert {
    condition = alltrue([
      for v in local.plan_exported_variables :
      strcontains(file("${path.module}/../../pipelines/infra-plan.yml"), v)
    ])
    error_message = "renaming an exported variable does not fail anything: the approval message shows the literal #{PlanProd.PLAN_SUMMARY} instead. This is the only thing that notices."
  }
}
```

- [ ] **Step 2: Run the suite and see the eight new runs fail**

```bash
./scripts/tf.sh test foundation
```

- [ ] **Step 3: Write `codepipeline.tf`**

```hcl
# The infrastructure pipeline.
#
# Source → Validate → Foundation → Network → Staging → Prod, where each of the
# last four is one stage holding Plan, a manual approval, and Apply. Six stages
# rather than fourteen, because before_entry is a stage-level condition: one
# condition skips a layer's plan, its approval and its apply together, and
# three stages per layer would need three conditions each with four times as
# many ways to disagree with themselves. Plan §D2.
#
# This pipeline lives in the layer it deploys. That is intentional (roadmap §1)
# and it has one consequence worth stating here rather than only in the
# runbook: a change that breaks the pipeline definition cannot be repaired by
# the pipeline, and must be fixed with a local `make apply-foundation`.

resource "aws_codepipeline" "infra" {
  name          = "${local.name_prefix}-infra-pipeline"
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V2"

  # QUEUED, not the SUPERSEDED default. SUPERSEDED cancels the older execution
  # when a newer one starts, and this pipeline's executions sit waiting on
  # human approvals and then run applies that take minutes — so a second merge
  # would cancel the run whose plan someone is part-way through reading, and
  # could cancel one mid-apply. PARALLEL is worse still: two applies of the
  # same layer contend on the same state lock. Plan §D11.
  execution_mode = "QUEUED"

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  # A run started by the git trigger supplies no variables, so every merge takes
  # this default (plan §F4). `all` is the policy: an infra change is normally a
  # change you want in production, and the four approvals — not this default —
  # are what stand between the merge and prod.
  variable {
    name          = "DEPLOY_SCOPE"
    default_value = var.deploy_scope_default
    description   = "How far this run goes: foundation | network | staging | all. Cumulative — staging also applies foundation and network; all reaches production."
  }

  trigger {
    provider_type = "CodeStarSourceConnection"

    git_configuration {
      source_action_name = "Source"

      push {
        branches {
          includes = [var.github_branch]
        }

        # The roadmap says infra/**. The other three are the pipeline's own
        # executable content: a change to a buildspec or to
        # pipeline-terraform.sh changes what every stage does, and it would be
        # odd for that to reach production only when someone next edits a .tf
        # file.
        #
        # scripts/** as a whole is deliberately excluded — it also holds
        # build-image.sh, smoke.sh and generate-sbom.sh, which belong to Phase
        # 8's pipeline, and watching the directory would run a four-approval
        # infra deployment on an application change. Plan §D12.
        file_paths {
          includes = [
            "infra/**",
            "pipelines/**",
            "scripts/pipeline-*.sh",
            "scripts/install-terraform.sh",
          ]
        }
      }
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source"]

      configuration = {
        ConnectionArn        = aws_codeconnections_connection.github.arn
        FullRepositoryId     = var.github_repository_id
        BranchName           = var.github_branch
        OutputArtifactFormat = "CODE_ZIP"

        # False, deliberately. True creates a second webhook that fires on
        # every push to the branch with no path filter, which would run this
        # pipeline on an app-only commit while the trigger block above sat
        # beside it looking as though it were working. In a V2 pipeline the
        # trigger owns change detection. Plan §D13.
        DetectChanges = "false"
      }
    }
  }

  # No AWS credentials are used here and the project's role grants none: tf.sh
  # initialises validate and test with -backend=false, and tflint and checkov
  # read files. Plan §D6.
  stage {
    name = "Validate"

    action {
      name            = "Validate"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source"]

      configuration = {
        ProjectName = aws_codebuild_project.infra_validate.name
      }
    }
  }

  dynamic "stage" {
    for_each = local.pipeline_layers

    content {
      name = stage.value.title

      # foundation has no condition — every scope includes it. The other three
      # skip rather than fail, so a deliberately narrow run finishes green;
      # a FAIL result would make Phase 9's change-failure-rate count an
      # intentional stop as a failure, which is the roadmap's stated reason for
      # not using a declined approval as the mechanism.
      dynamic "before_entry" {
        for_each = stage.value.scope_operator == null ? [] : [stage.value]

        content {
          condition {
            result = "SKIP"

            rule {
              name = "in-scope"

              rule_type_id {
                category = "Rule"
                owner    = "AWS"
                provider = "VariableCheck"
                version  = "1"
              }

              # configuration is an untyped map(string): the provider validates
              # nothing here and the service validates it at execution time, so
              # whether MATCHES is accepted cannot be confirmed offline. That is
              # why scripts/pipeline-terraform.sh checks the scope again — see
              # plan §F2 for the fallback if it is not.
              configuration = {
                Variable = "#{variables.DEPLOY_SCOPE}"
                Operator = before_entry.value.scope_operator
                Value    = before_entry.value.scope_value
              }
            }
          }
        }
      }

      action {
        name             = "Plan"
        category         = "Build"
        owner            = "AWS"
        provider         = "CodeBuild"
        version          = "1"
        run_order        = 1
        namespace        = "Plan${stage.value.title}"
        input_artifacts  = ["source"]
        output_artifacts = ["plan_${stage.value.name}"]

        configuration = {
          ProjectName = aws_codebuild_project.infra_plan.name

          # LAYER is what makes one project serve four layers; DEPLOY_SCOPE is
          # the second gate. Both are per-action overrides because neither is a
          # property of the shared project.
          EnvironmentVariables = jsonencode([
            { name = "LAYER", value = stage.value.name, type = "PLAINTEXT" },
            { name = "DEPLOY_SCOPE", value = "#{variables.DEPLOY_SCOPE}", type = "PLAINTEXT" },
          ])
        }
      }

      action {
        name      = "Approve"
        category  = "Approval"
        owner     = "AWS"
        provider  = "Manual"
        version   = "1"
        run_order = 2

        configuration = {
          # The plan summary the Plan action exported, so approving is an
          # informed decision rather than a reflex. Capped at 1000 characters
          # by CodePipeline, which is why the script truncates at 900 and
          # offers the full plan behind the link.
          CustomData         = "#{Plan${stage.value.title}.PLAN_SUMMARY}"
          ExternalEntityLink = "#{Plan${stage.value.title}.PLAN_URL}"
        }
      }

      action {
        name            = "Apply"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        run_order       = 3
        input_artifacts = ["plan_${stage.value.name}"]

        configuration = {
          ProjectName = aws_codebuild_project.infra_apply.name

          EnvironmentVariables = jsonencode([
            { name = "LAYER", value = stage.value.name, type = "PLAINTEXT" },
            { name = "DEPLOY_SCOPE", value = "#{variables.DEPLOY_SCOPE}", type = "PLAINTEXT" },
          ])
        }
      }
    }
  }
}
```

- [ ] **Step 4: Run the suite**

```bash
./scripts/tf.sh test foundation
```

Expected: PASS, all runs across all five test files.

- [ ] **Step 5: Commit**

```bash
git add infra/foundation/codepipeline.tf infra/foundation/tests/pipeline_shape.tftest.hcl
git commit -m "feat(infra): the infra pipeline, its scope variable and its skip conditions"
```

---

### Task 7: Artifact lifecycle, outputs, and the full offline gate

**Files:**
- Modify: `infra/foundation/artifacts.tf`
- Modify: `infra/foundation/outputs.tf`
- Modify: `infra/foundation/README.md`
- Modify: `infra/foundation/tests/pipeline_shape.tftest.hcl`

**Interfaces:**
- Produces: outputs `infra_pipeline_name`, `infra_pipeline_arn`, `infra_apply_role_arn`, `image_tag_parameter_names`.

- [ ] **Step 1: Write the failing lifecycle and output assertions**

Append to `infra/foundation/tests/pipeline_shape.tftest.hcl`:

```hcl
run "pipeline_artifacts_expire_and_the_existing_rule_does_not_cover_them" {
  command = plan

  assert {
    condition = length([
      for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule :
      r if r.id == "expire-infra-pipeline-artifacts"
    ]) == 1
    error_message = "CodePipeline writes a source zip and four plan artifacts per execution as CURRENT versions; the Phase 3 rule expires only noncurrent ones and matches none of them"
  }

  assert {
    condition = [
      for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule :
      one(r.filter).prefix if r.id == "expire-infra-pipeline-artifacts"
    ] == ["bgd-us-east-1-infra-pipeline/"]
    error_message = "the rule must be scoped to the pipeline's own prefix — an unscoped expiration would delete the SBOMs and test reports the bucket exists to keep"
  }
}

run "the_outputs_phase_8_and_9_consume_are_present" {
  command = plan

  assert {
    condition     = output.infra_pipeline_name == "bgd-us-east-1-infra-pipeline"
    error_message = "Phase 9's EventBridge rule filters on the pipeline name and reads it from here rather than typing it again"
  }

  assert {
    condition     = toset(keys(output.image_tag_parameter_names)) == toset(["staging", "prod"])
    error_message = "Phase 8 writes these parameters after pushing an image and needs their names from the layer that owns them"
  }
}
```

- [ ] **Step 2: Run the suite and see them fail**

```bash
./scripts/tf.sh test foundation
```

- [ ] **Step 3: Add the lifecycle rule**

In `infra/foundation/artifacts.tf`, add a second rule inside `aws_s3_bucket_lifecycle_configuration.artifacts`, after the existing one:

```hcl
  # CodePipeline's own artifacts, which the rule above does not reach.
  #
  # That rule expires *noncurrent* versions, and every pipeline execution
  # writes objects under a fresh key — a source zip and one saved plan per
  # layer. They are all current versions forever, so nothing expires them and
  # the bucket grows by five objects per run.
  #
  # Scoped by prefix rather than applied to the bucket, because the same bucket
  # holds the SBOMs and test reports the design wants kept as history (§4.2).
  # CodePipeline writes under <pipelineName>/, which is the prefix below.
  rule {
    id     = "expire-infra-pipeline-artifacts"
    status = "Enabled"

    filter {
      prefix = "${local.name_prefix}-infra-pipeline/"
    }

    expiration {
      days = var.pipeline_artifact_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
```

- [ ] **Step 4: Add the outputs**

Append to `infra/foundation/outputs.tf`:

```hcl
output "infra_pipeline_name" {
  description = "Name of the infrastructure pipeline. Phase 9's EventBridge rule filters execution state changes on it."
  value       = aws_codepipeline.infra.name
}

output "infra_pipeline_arn" {
  description = "ARN of the infrastructure pipeline."
  value       = aws_codepipeline.infra.arn
}

output "infra_apply_role_arn" {
  description = "The role the pipeline's applies run as. Recorded because 'who changed this' is the first question about any resource this project creates."
  value       = aws_iam_role.infra_apply.arn
}

output "image_tag_parameter_names" {
  description = "SSM parameters holding the tag each environment deploys, keyed by environment. Phase 8 writes these after pushing an image; scripts/pipeline-terraform.sh reads them."
  value       = { for env, p in aws_ssm_parameter.image_tag : env => p.name }
}
```

- [ ] **Step 5: Update `infra/foundation/README.md`**

Replace the paragraph beginning "Both CodePipelines also belong to this layer, but they arrive with **Phases 7 and 8**" with:

```markdown
The **infrastructure pipeline** lives here, added in Phase 7 — a CodePipeline
v2 with three CodeBuild projects, four IAM roles, and the two SSM parameters
that tell the environment layers which image tag to deploy. The application
pipeline arrives in Phase 8, as more files in this layer rather than a new one.

Each IAM role is still created by the phase that creates the resource it acts
on, which is why Phase 3 created none: a policy cannot be scoped to resources
that do not exist yet.
```

And extend the closing paragraph:

```markdown
The pipelines live in this layer, so the infra pipeline ends up managing the layer
that contains it. That is intentional — but it means a broken pipeline definition
must be repaired by a local `terraform apply`. The
[Phase 7 runbook](../../docs/runbooks/phase-07-infra-pipeline.md) has that
procedure as a step of its own, because the moment it is needed is the moment
the pipeline cannot help.
```

- [ ] **Step 6: Run the full offline gate**

```bash
make tf-check
```

This is the first run of the whole gate for this phase: `tf-validate`, `tf-lint` and `tf-test` across all five layers. Expect checkov findings on the new resources.

- [ ] **Step 7: Triage every checkov finding**

For each finding, either fix it or add a `# checkov:skip=<ID>:<reason>` comment whose reason names the trade-off. F9 predicts five; the prediction may be wrong in either direction.

**A bare skip is not acceptable.** If a finding has no defensible reason, fix the code instead.

Record the real list — including where F9 was wrong — for Task 10's verification record.

- [ ] **Step 8: Re-run the gate until clean**

```bash
make tf-check
```

Expected: `all infra checks passed`.

- [ ] **Step 9: Commit**

```bash
git add infra/foundation/artifacts.tf infra/foundation/outputs.tf \
        infra/foundation/README.md infra/foundation/tests/pipeline_shape.tftest.hcl \
        infra/foundation/codebuild.tf infra/foundation/iam-pipeline.tf \
        infra/foundation/codepipeline.tf infra/foundation/ssm.tf
git commit -m "feat(infra): pipeline artifact lifecycle, outputs, and a clean static analysis pass"
```

---

### Task 8: `seed-ecr.sh` writes the parameters, and the makefile stops exporting a profile into CodeBuild

Two changes that are small and unrelated except in being the parts of D8 and F6 that live outside `infra/`.

**Files:**
- Modify: `scripts/seed-ecr.sh`
- Modify: `makefile`

**Interfaces:**
- Consumes: `foundation`'s `image_tag_parameter_names` output.
- Produces: `make tf-fmt-check`; `/bgd/staging/image_tag` and `/bgd/prod/image_tag` populated with a real tag.

- [ ] **Step 1: Make `seed-ecr.sh` record the tag it pushed**

Append to `scripts/seed-ecr.sh`, after the digest assertion and before the closing `ok`/`dim` lines:

```bash
# Record the tag as the one both environment layers should deploy.
#
# The environment layers declare image_tag with no default and read it from
# terraform.tfvars, which is gitignored — so a CodeBuild workspace has no value
# and the infra pipeline cannot plan staging or prod without this (Phase 7
# §D8). Writing it here rather than in a separate step means the parameter is
# populated by the same command that makes the tag real.
#
# --overwrite because the parameter is created holding "unset" and every
# subsequent seed replaces the previous tag. Terraform ignores changes to the
# value, so this does not create drift.
for env in staging prod; do
  aws ssm put-parameter \
    --profile "$PROFILE" --region "$REGION" \
    --name "/bgd/${env}/image_tag" \
    --value "$TAG" \
    --type String \
    --overwrite >/dev/null
  dim "  /bgd/${env}/image_tag  ->  $TAG"
done
```

Then amend the script's closing `dim` line so the handover it describes is the whole one:

```bash
dim "  Phases 5 and 6 set BGD_IMAGE_DIGEST to this value in the task definition,"
dim "  and the infra pipeline plans both environments against /bgd/<env>/image_tag."
```

- [ ] **Step 2: Make the makefile's `AWS_PROFILE` conditional**

In `makefile`, replace:

```make
AWS_PROFILE := bootcamp-administrator-access
```

and the `export` line's mention of it, with:

```make
# := rather than ?=, deliberately, and this is load-bearing from Phase 3 on.
# GNU Make gives an environment variable precedence over ?=, so a shell that
# already exports AWS_PROFILE for some other account silently wins — and
# `make apply-foundation` would then run Terraform against that account. A :=
# assignment overrides the environment while still yielding to an explicit
# `make AWS_PROFILE=other <target>` on the command line, which is the only
# override that should count. Found in Phase 3; see
# docs/phases/phase3/2026-08-24-local-verification.md §F7.
#
# Not set inside CodeBuild. There is no shared config file there and no such
# profile: credentials come from the build project's service role. An exported
# AWS_PROFILE naming a profile that does not exist makes every SDK call fail
# with "The config profile could not be found" INSTEAD of falling back to the
# role — a credentials-shaped error with a makefile-shaped cause. Nothing the
# Validate stage runs today calls AWS, but that is a property of the current
# target list rather than a guarantee. Phase 7 §F6.
ifndef CODEBUILD_BUILD_ID
AWS_PROFILE := bootcamp-administrator-access
export AWS_PROFILE
endif
```

and change the remaining export line to:

```make
export AWS_REGION AWS_ACCOUNT_ID
```

- [ ] **Step 3: Add `tf-fmt-check`**

The Validate stage must run the same check as a laptop, and `make tf-fmt` *writes* — a pipeline cannot use it. Add beside it:

```make
# The pipeline's formatting gate. tf-fmt above rewrites files, which is right
# on a laptop and useless in CodeBuild, where a reformatted file is discarded
# with the container. -check exits non-zero instead, and -diff says which lines.
.PHONY: tf-fmt-check
tf-fmt-check: ## Fail if any Terraform file is unformatted (no AWS session needed)
	@terraform fmt -check -recursive -diff infra
```

- [ ] **Step 4: Confirm both changes behave**

```bash
make tf-fmt-check
CODEBUILD_BUILD_ID=fake:1 make -n tf-validate | head -3
bash -n scripts/seed-ecr.sh
```

Expected: `tf-fmt-check` passes silently. The second prints the recipe without an `AWS_PROFILE` export in front of it — confirm by:

```bash
CODEBUILD_BUILD_ID=fake:1 make -p 2>/dev/null | grep -c '^AWS_PROFILE'
make -p 2>/dev/null | grep -c '^AWS_PROFILE'
```

Expected: `0` then `1`.

- [ ] **Step 5: Confirm `make help` still reads correctly**

```bash
make help
```

Expected: `tf-fmt-check` appears under **Available now** with its description, and the Planned list is unchanged.

- [ ] **Step 6: Commit**

```bash
git add scripts/seed-ecr.sh makefile
git commit -m "feat(scripts): seed-ecr records the deployed tag; make stops exporting a profile into CodeBuild"
```

---

### Task 9: The runbook

Everything this session cannot execute, written so it can be followed by someone who did not write it.

**Files:**
- Create: `docs/runbooks/phase-07-infra-pipeline.md`
- Modify: `docs/runbooks/README.md`

- [ ] **Step 1: Write the runbook**

Sections, in the order they are needed:

1. **Preconditions.** `foundation` applied and its CodeConnections link **authorised** — the pipeline's Source stage fails on a `PENDING` connection with an error that does not mention the console click. `make seed-ecr` run at least once, so both SSM parameters hold a real tag rather than `unset`. Include the verification command for each:
   ```bash
   aws codeconnections get-connection --connection-arn "$(terraform -chdir=infra/foundation output -raw github_connection_arn)" --query 'Connection.ConnectionStatus' --output text
   aws ssm get-parameter --name /bgd/prod/image_tag --query Parameter.Value --output text
   ```
   Expected: `AVAILABLE`, and a tag that is not `unset`.
2. **AWS session.** `aws sso login --profile bootcamp-administrator-access`, then `make verify-aws`.
3. **Re-run the offline gate against the real toolchain.** `make tf-check` on a machine that now has credentials — the same command the branch was gated on, confirming nothing about it depended on being offline.
4. **The last local apply.** `make plan-foundation`, read it, `make apply-foundation`. State plainly that this is the handover: it is the last apply of this layer that has to be local, and the runbook says which resources to expect (four roles, three projects, three log groups, two parameters, one pipeline, one lifecycle rule).
5. **Confirm the pipeline exists and is idle.** `aws codepipeline get-pipeline-state --name bgd-us-east-1-infra-pipeline`.
6. **Exit criterion 1 — a change to an environment layer flows through and applies.** Make a genuinely trivial, honest change under `infra/environments/staging/` (a comment, or `log_retention_days`), merge it, and follow the run: Source, Validate, then Foundation and Network approving empty plans, then Staging approving a real one. Record the approval message text — it is the evidence that the plan reached the approval, which is the roadmap's stated requirement.
7. **Exit criterion 2 — `DEPLOY_SCOPE=network` leaves production untouched.** Start a run by hand:
   ```bash
   aws codepipeline start-pipeline-execution \
     --name bgd-us-east-1-infra-pipeline \
     --variables name=DEPLOY_SCOPE,value=network
   ```
   Then, and this is the part that matters, prove it three ways rather than one:
   - the Staging and Prod stages report `Skipped` in `get-pipeline-state`;
   - the execution's overall status is `Succeeded`, not `Failed` — the roadmap's requirement, and what keeps Phase 9's change-failure-rate honest;
   - production's ECS service `taskDefinition` is the same revision before and after. Capture it before starting the run.

   **This step also retires F2.** If the Staging stage runs rather than skipping, `MATCHES` was rejected — the plan build will refuse the layer anyway (D4), and the fix is F2's ordinal fallback. Record which happened either way, because "it worked" and "it worked for the reason we thought" are different findings.
8. **Read the approval message and the plan link.** Confirm `CustomData` shows a real summary rather than the literal `#{PlanStaging.PLAN_SUMMARY}`, and that `ExternalEntityLink` opens the CodeBuild log. A literal placeholder means the exported variable name and the interpolation disagree.
9. **Repairing a broken pipeline definition by local apply.** The procedure `docs/runbooks/README.md` has listed as planned for Phase 7 since Phase 3. Deliberately break nothing; describe the situation — a merged change that leaves the pipeline unable to run its own Source or Validate stage — and give the recovery: `git revert`, then `make apply-foundation` locally, because the pipeline cannot apply the fix to itself. Note the state-lock interaction: if a pipeline execution is stuck holding the `foundation` lock, `terraform force-unlock` with the ID from the error message.
10. **What goes wrong.** At minimum: `PENDING` connection; `unset` image tag; a stale-plan error from a local apply racing the pipeline (D9) and why failing is correct; an approval that expires after seven days; `MATCHES` rejected; the apply timing out on a prod blue/green deployment that rolled back.

- [ ] **Step 2: Update `docs/runbooks/README.md`**

Move the "Repairing a broken pipeline definition by local apply" row out of the planned list and into the table of written runbooks, pointing at the new file and describing it as covering the Phase 7 apply, both exit criteria, and the repair procedure.

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/
git commit -m "docs: the Phase 7 runbook"
```

---

### Task 10: Amendments and the local verification record

**Files:**
- Modify: `docs/2026-08-04-implementation-phase-roadmap.md`
- Modify: `docs/2026-08-04-blue-green-deployment-platform-design-research.md`
- Modify: `docs/naming-and-tagging-convention.md`
- Create: `docs/phases/phase7/2026-08-29-local-verification.md`

- [ ] **Step 1: Amend the roadmap's Phase 7 section**

In the style of Phases 4, 5 and 6 — a block quote naming what the phase built beyond the task list, each item pointing at the decision that settled it:

- The **two SSM parameters and the change to `scripts/seed-ecr.sh`** (D8). Not in the task list. The task list assumes the pipeline can plan every layer, and two of the four declare a required variable with no default whose value lives in a gitignored file (F7).
- **Three CodeBuild projects and four IAM roles**, where design §8.1 names one CodeBuild role and one CodePipeline role (D5, D6, F3). A build's permissions come from the project's service role, so three roles means three projects — and the split is what lets the plan role be genuinely read-only.
- **`DEPLOY_SCOPE`'s four values are cumulative, and `all` means "through prod"** (D3). The roadmap's phrasing "stop after `foundation`, `network` or `staging`" already implies it; the amendment states it as a table so it cannot be read the other way.
- **The scope is enforced twice** (D4), and the second gate is not redundancy for its own sake: the `VariableCheck` operator set is not in the provider schema (F2) and the failure modes are asymmetric.
- **`LINUX_CONTAINER`, not `ARM_CONTAINER`** (D7) — and the reason is the *opposite* of Phase 2's amendment, which requires `ARM_CONTAINER` for Phase 8's app build. Both are right; the divergence should read as deliberate.
- **The trigger watches four path patterns, not one** (D12), and deliberately not `scripts/**`.
- **Neither exit criterion is met by the branch alone.** The branch's gate is `make tf-check`; both are met when [the runbook](../../runbooks/phase-07-infra-pipeline.md) is executed — steps 6 and 7.
- **§2's branch table row 7 reads `feat/Phase7_InfraPipeline`, which is the branch used. No amendment needed there** — recorded explicitly, as Phases 3, 5 and 6 did, so the absence reads as checked rather than overlooked.

- [ ] **Step 2: Amend design §8.1**

Add a block quote in the established style: the design's single **CodeBuild** role is three — validate, plan and apply — because a build's permissions come from the project's service role and cannot be overridden per action (F3). Note that the split is what makes the plan role's `ReadOnlyAccess` meaningful, and that the apply role's `AdministratorAccess` is argued in the Phase 7 plan's D6 by the same rule the Phase 6 amendment used for the blue/green controller: write the policy that is honest about the boundary, not the one that looks strict.

- [ ] **Step 3: Amend the naming convention**

Add a row to §3's table:

| Resource type | Pattern | Example |
|---|---|---|
| SSM parameter | `/bgd/<env>/<key>` | `/bgd/prod/image_tag` |

with a note under "The deliberate deviations" that this is the third: SSM parameters are hierarchical by AWS convention and the console, `GetParametersByPath` and every IAM path-based scope assume slashes — the same argument the CloudWatch log group deviation makes, applied to a different service. Note also that §2's rule is what puts no `<env>` segment in `bgd-us-east-1-infra-pipeline`: it exists once for the whole project.

- [ ] **Step 4: Write the local verification record**

`docs/phases/phase7/2026-08-29-local-verification.md`, following Phase 6's structure:

1. **The gate.** The exact `make tf-check` output, and what each group of assertions protects against.
2. **Static analysis triage.** Every checkov finding on the new resources, what was skipped and why — and **where F9's prediction was wrong**, stated plainly, as Phase 6's record did.
3. **The executed evidence.** The scope-gate matrix from Task 5 Step 2, run and pasted; the YAML parse; `bash -n` on both new scripts; the `AWS_PROFILE` before/after counts from Task 8 Step 4.
4. **No AWS resource was created.** The same explicit statement Phases 3 to 6 each carry, with the evidence: no `aws` command that mutates anything was run, and `terraform plan` was never invoked against a backend.
5. **What remains before the exit criteria are met** — the runbook, step by step.
6. **Carried forward.** F2 as the open question step 7 closes, and the honest note that `MATCHES` may be wrong.

- [ ] **Step 5: Run the gate one last time**

```bash
make tf-check
```

Expected: `all infra checks passed`.

- [ ] **Step 6: Commit**

```bash
git add docs/
git commit -m "docs: Phase 7 amendments and the local verification record"
```

- [ ] **Step 7: Open the pull request**

Push `feat/Phase7_InfraPipeline` and open a pull request whose description is §5's exit criteria and how each was verified — stating plainly that neither is met by the branch, that the branch's gate is `make tf-check`, and that both are met when the runbook is executed.

---

## 5. Exit criteria

From the roadmap, verbatim:

1. **A change to an environment layer flows through the pipeline and applies.**
2. **A `DEPLOY_SCOPE=network` run demonstrably leaves production untouched.**

**Neither is met by this branch.** Both need a pipeline that exists and a run that happened, and this session creates no AWS resource (D1). They are met by [the runbook](../../runbooks/phase-07-infra-pipeline.md) — steps 6 and 7 respectively.

What the branch does gate itself on:

| Check | Command | Covers |
|---|---|---|
| Terraform validity | `make tf-validate` | all five layers parse and typecheck |
| Static analysis | `make tf-lint` | tflint and checkov, every finding fixed or skipped with a reason |
| Behaviour | `make tf-test` | five test files; the pipeline's shape, order, artifact hand-off, trigger, conditions and the four roles' boundaries |
| Formatting | `make tf-fmt-check` | the check the Validate stage will run |
| Shell | `bash -n` on both new scripts, plus the scope-gate matrix executed | D4's second gate actually refuses |
| Buildspecs | `yaml.safe_load` on all three | the three files parse as CodeBuild expects |

---

## 6. Risks this phase adds

| Risk | Handling |
|---|---|
| **`MATCHES` is not a `VariableCheck` operator** | F2. The second gate in `scripts/pipeline-terraform.sh` makes being wrong cost an unwanted approval rather than an unwanted apply, and the fallback is a Terraform-only change to ordinals and `LTE`. Runbook step 7 confirms it. |
| **The pipeline manages the layer that contains it** | Expected, and named in roadmap §1 since the design. A broken definition is repaired by a local `make apply-foundation`; runbook step 9 is that procedure, and it has been listed as a planned Phase 7 runbook since Phase 3. |
| **`AdministratorAccess` on the apply role** | Accepted, argued in D6, and skipped in checkov with that argument attached rather than silently. The compensating control is the manual approval on a saved plan, not the policy. |
| **A merge now reaches production** | Intended from this phase on (roadmap §2.1) and gated by four approvals. Worth stating as a risk anyway, because the change in what a merge *means* is the largest behavioural change in the project and it happens the moment this branch lands. |
| **A local apply racing a pipeline execution** | The saved plan goes stale and the apply fails, which is correct. The alternative — a re-planning apply — would succeed and silently do something nobody approved (D9). Runbook step 10 covers the recovery. |
| **The approval message shows a literal placeholder** | Caught offline by the test that asserts `pipelines/infra-plan.yml` still exports every name in `local.plan_exported_variables`, and confirmed live by runbook step 8. |
| **CodeBuild pulling checkov and tflint from public registries** | Anonymous pulls are rate-limited. If the Validate stage starts failing on image pulls rather than on findings, the fix is an ECR pull-through cache — noted, not built, because it is a cost and a resource for a problem that has not happened. |
| **Phase 8 has to write the SSM parameters** | D8 makes that the whole handoff, and `scripts/seed-ecr.sh` already demonstrates the exact call. Recorded here so Phase 8 inherits it as a requirement rather than discovering it. |
