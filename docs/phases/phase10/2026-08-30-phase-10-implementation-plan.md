# Phase 10 — Teardown and rebuild automation: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-30
**Status:** Proposed
**Branch:** `feat/Phase10_TeardownRebuild`
**AWS cost incurred by this phase as planned:** **$0.** Every deliverable is written and verified locally, against mocked providers, a fake AWS CLI and no AWS session. The teardown-and-rebuild cycle the roadmap asks to be *executed* is handed to you as a runbook — see §0.1 D1. Once applied, the phase adds one SSM standard parameter, which is free.
**Companion documents:**
[design research](../../2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 4 plan](../phase4/2026-08-26-phase-04-implementation-plan.md) ·
[Phase 7 plan](../phase7/2026-08-29-phase-07-implementation-plan.md) ·
[Phase 8 plan](../phase8/2026-08-30-phase-08-implementation-plan.md) ·
[Phase 8 runbook](../../runbooks/phase-08-app-pipeline.md) ·
[Phase 9 plan](../phase9/2026-08-30-phase-09-implementation-plan.md) ·
[naming and tagging convention](../../naming-and-tagging-convention.md)

**Goal:** Make "destroy when idle" a command rather than a discipline — `make teardown` destroying prod, staging and network in order behind one confirmation, `make rebuild` bringing them back and proving it with the same smoke tests the pipeline uses, `make verify-idle` proving the account is actually idle without trusting Terraform's word for it, and a marker in SSM that stops either pipeline deploying into an account that has been torn down.

The cost policy has existed since the roadmap was written. What has not existed is a way to act on it that does not depend on somebody remembering the order, remembering the image tag, and remembering not to merge afterwards.

**Architecture:** Three operator scripts (`teardown.sh` rewritten, `rebuild.sh` and `verify-idle.sh` new) over one new piece of shared state: `/bgd/platform/deployed_scope`, an SSM parameter in `foundation` holding one of `foundation | network | staging | all` — the four values `DEPLOY_SCOPE` already uses. Teardown lowers it, rebuild raises it, and both pipeline driver scripts clamp their own scope to it, so a merge to `main` while the platform is down skips the layers that do not exist instead of recreating or failing against them. Correctness is asserted by Terraform's native test framework against `mock_provider` and by a new dependency-free shell suite driven by a fake AWS CLI; the whole gate stays offline.

**Tech stack:** Bash 3.2-compatible shell (macOS ships GNU Bash 3.2 as `/bin/bash`; scripts use `/usr/bin/env bash`), Terraform 1.15.7, AWS provider 6.61.0, `aws_ssm_parameter`, the AWS CLI v2 (`ssm`, `ec2`, `elbv2`, `ecs`, `dynamodb`, `sts`, `resourcegroupstaggingapi`).

**Spec:** [phase roadmap §3, Phase 10](../../2026-08-04-implementation-phase-roadmap.md#phase-10--teardown-and-rebuild-automation), elaborated by [roadmap §1](../../2026-08-04-implementation-phase-roadmap.md#1-why-five-layers-instead-of-four)'s teardown/rebuild ordering, and closing by name the gap [Phase 8's runbook §11](../../runbooks/phase-08-app-pipeline.md) handed to this phase.

---

## Global Constraints

Project-wide requirements. Every task's requirements implicitly include this section.

- **Naming:** `bgd-us-east-1-<resource>`, all lowercase, hyphen-separated. The one resource this phase creates is an SSM parameter, and SSM parameters in this project use the path form `/bgd/<scope>/<name>` that `image_tag` established — so it is `/bgd/platform/deployed_scope`, not a hyphenated name. `platform` occupies the position `staging` and `prod` occupy in the existing two, and is not an environment: it names the whole thing.
- **Tagging:** exactly four keys — `environment`, `projectName`, `region`, `owner` — applied through the provider's `default_tags`. This layer's `environment` is `shared`; this phase adds no tag and changes no tag.
- **Terraform:** `required_version >= 1.10`, AWS provider `~> 6.61`, S3 backend with `use_lockfile = true`. Unchanged since Phase 3; this phase adds no provider.
- **The offline gate:** `make tf-check`, `make test-scripts` and `make test-lambdas` must all pass on a machine that has never run `aws sso login`.
- **Every checkov finding is either fixed or skipped with a written reason.** A bare skip is not acceptable; the reason names the trade-off.
- **Scripts source `lib/common.sh` and use its helpers.** `info`/`ok`/`warn`/`fail`/`die`, and the rule `die` records: anything reporting a problem writes to stderr.
- **No script in this phase destroys `foundation` or `bootstrap`.** If an implementation step appears to need that, something has been misread; stop and re-read D16.

---

## 0. Purpose and non-goals

After Phase 9 the platform builds, deploys, watches and alerts on itself. It also costs about $99/month to leave running, and roughly $1/month if the right three layers are destroyed in the right order. The gap between those two numbers is currently bridged by a fifty-line first-cut script and a person remembering things.

Three specific things are remembered rather than enforced today:

1. **The order.** `teardown.sh` has it right; nothing has it for the way back. A rebuild is three `make apply-*` commands whose order is load-bearing and written down in a roadmap, not in a script.
2. **The image tag.** Both environment layers declare `image_tag` with no default. Locally the value comes from a gitignored `terraform.tfvars`. `infra/foundation/ssm.tf` predicted this phase by name — *"a Phase 10 rebuild has to plan against the tag that was deployed before the teardown"* — and put the parameter in the surviving layer for that reason. Nothing reads it locally yet.
3. **Not merging afterwards.** [Phase 8's runbook §11](../../runbooks/phase-08-app-pipeline.md) tells you to disable both pipeline triggers in the console after a teardown and re-enable them "as the first step of the Phase 10 rebuild". That is a fourth manual step, in a project whose documents claim there are exactly three.

This phase closes all three. Its job is not scripting for its own sake: it is that **walking away costs one command, coming back costs one command, and forgetting either one cannot quietly cost $99 or deploy into an account that is not there.**

**This phase deliberately does not:**

- create any AWS resource, or make any AWS API call, in this session (D1)
- execute the teardown-and-rebuild cycle the roadmap's fourth bullet asks for — that is the runbook's, and the exit criterion is honestly not met by this branch (D1)
- destroy or modify `foundation` or `bootstrap` from any script (D16)
- add a Cost Explorer check (D15)
- change any pipeline stage, any IAM role, any buildspec other than `infra-validate.yml`'s one new line, or any application code
- change what `make apply-staging` and `make apply-prod` do — they still read `terraform.tfvars`, and `rebuild.sh` is the path that reads SSM (D10)
- produce the rollback evidence — Phase 11 owns that, and needs a rebuilt environment to produce it in

### 0.1 Decisions taken before this plan was written

#### D1 — This session writes and verifies; you execute the cycle

Same as Phases 3 through 9, and for the same reason. Everything that can be built and proved without an AWS session is; the cycle itself is handed over as [a runbook](../../runbooks/phase-10-teardown-and-rebuild.md).

This phase is the one where that split costs something worth naming. The roadmap's fourth bullet reads:

> **A full teardown and rebuild cycle executed and verified**, not merely written. This is the honest test of whether the infrastructure as code is complete.

It is right, and this branch does not satisfy it. The branch's own gate is `make tf-check` plus `make test-scripts` plus `make test-lambdas`. **The exit criterion in §5 is not met by the branch**, and the roadmap amendment says so in those words rather than letting a green gate imply a proven cycle. What the branch can prove is that every guard, every rank comparison and every refusal path behaves as written — which is what makes the runbook worth following rather than debugging.

#### D2 — One marker, in `foundation`, in `DEPLOY_SCOPE`'s vocabulary

`/bgd/platform/deployed_scope`, an SSM `String` parameter, holding one of `foundation`, `network`, `staging`, `all`.

Three choices inside that, each of which could have gone the other way:

- **In `foundation`.** It has to survive what it describes. Anywhere else and the record of "the platform is torn down" is destroyed by the teardown. This is the same argument `ssm.tf` already makes for `image_tag` and Phase 9's D2 makes for the whole observability plane.
- **SSM, not a file, not a tag, not a DynamoDB table.** A file in the repository would be committed, which makes the state of one AWS account a property of a git branch. A tag would have to live on some resource that survives. A table is a resource to create, pay for and destroy. SSM is already how this project passes a small string from one process to another, `foundation` already owns two of them, and the roles that need to read it already can (F3).
- **The same four values as `DEPLOY_SCOPE`.** Not `true`/`false`, and not a new vocabulary. `pipeline-terraform.sh` already ranks exactly these four names, `foundation/locals.tf`'s `pipeline_layers` already orders them, and the runbook already talks in them. A boolean would also have been wrong on the facts: with D7's scopes a partial teardown is a real state, and "torn down: yes" cannot express *how far*.

#### D3 — The marker never overstates what exists, and that fixes the write order

The rule is one sentence: **the marker may lag behind reality downward, never upward.** It falls out into an asymmetry that is easy to get wrong and expensive to get wrong.

- **`teardown.sh` writes the post-teardown value before it destroys anything.** The moment you decide to tear down is the moment merges should stop deploying. Writing it afterwards leaves a window — the whole destroy, minutes long — in which a merge lands, reads `all`, and starts applying into an account being dismantled underneath it. Worse, a teardown that dies half-way through would never write it at all, leaving the pipelines believing production is up when prod is exactly what was destroyed first.
- **`rebuild.sh` writes after each layer applies, not once at the end.** A rebuild that fails at prod leaves the marker reading `staging`, which is true. Writing `all` up front would mean a rebuild that never reached prod still told both pipelines to deploy there.

The failure this ordering accepts is the marker *understating* — saying `foundation` while a half-destroyed staging still exists. That direction costs a skipped stage and a line in the console. The other direction costs a deployment into an account that cannot serve it.

#### D4 — The default is `all`, not `foundation`

The parameter is created with `value = "all"` and `ignore_changes = [value]`, the same shape `image_tag` uses and for the same reason: `teardown.sh` and `rebuild.sh` write it, and without `ignore_changes` the next `foundation` apply reverts it — after which the following merge deploys into a torn-down account, with both applies green.

`all` rather than the more literally-honest `foundation` because of what the alternative does to a fresh account. Layers are applied in order, `foundation` first; a parameter defaulting to `foundation` would clamp `network` on an account that had simply never been torn down, and every runbook from Phase 4 onward would need a step it does not have. Making the default `all` means the marker only ever *restricts*, and only after somebody explicitly ran teardown.

The cost is stated rather than hidden: **the marker is a teardown marker, not a deployment registry.** It does not know that `make apply-prod` was run by hand. It knows that teardown was run, and that rebuild was or was not run afterwards. That is the whole of its contract and the runbook says so.

#### D5 — Both pipelines clamp, and `make rebuild` is the only thing that raises the marker

Each pipeline driver takes the smaller of its own scope and the marker:

```
effective = min(DEPLOY_SCOPE, deployed_scope)
```

A layer above `effective` **skips green**. It does not fail. Phase 7's D3 and Phase 8's APP_SCOPE both made the same choice for the same reason, and it matters more here: since Phase 9 a failed pipeline run sends an email and counts in change-failure-rate, so a run that correctly declined to deploy into a torn-down account must not look like a bad deployment.

What this buys, and what it costs, both stated plainly:

- A merge to `main` while torn down still runs Validate, still applies `foundation`, still builds, tests and pushes an image. It creates no network, no ALB and no Fargate task. Your work keeps flowing; the bill does not move.
- **A merge can no longer rebuild a torn-down layer.** That is deliberate and it is the point — the failure being prevented is a $99/month surprise from a merge nobody thought of as a deployment. `make rebuild` is the only path that raises the marker, and the runbook names the one-line `aws ssm put-parameter` escape hatch for the day you want the pipeline to do it instead.

The clamp message is deliberately *different* from the scope message. `"staging is outside DEPLOY_SCOPE=all"` would be a lie, and an operator reading it in the console would go looking for a bug in the scope handling. The clamp says what is true and what to do:

```
==> staging is torn down (/bgd/platform/deployed_scope = network) — nothing to do
    run `make rebuild` to bring it back
```

#### D6 — Reading the marker fails loudly, and `foundation` is exempt

If the parameter cannot be read — missing, or the role lost `ssm:GetParameter` — the driver dies. It does not assume `all`.

A gate that fails open is not a gate: assuming `all` on a read failure means a permissions regression silently restores the exact behaviour this decision exists to remove, and nothing anywhere reports it. Failing loudly turns the same regression into a red Validate-adjacent stage with the parameter name in the message. The parameter, the pipeline and the role are all created by the same layer, so "cannot read it" means `foundation` is broken, which is worth stopping for.

**`foundation` is exempt, and must be.** It is the layer that *creates* the parameter — on a fresh account the parameter does not exist at the moment `foundation` is first planned, and a driver that demanded it would make the layer unable to bootstrap itself. `foundation` ranks 1, every valid marker value ranks at least 1, so the clamp can never exclude it; the read is skipped entirely when the layer being handled is `foundation`.

#### D7 — Scope in both directions, cumulative, same vocabulary

Both operator scripts take a `SCOPE`, cumulative, naming where the run stops — the rule `DEPLOY_SCOPE` and `APP_SCOPE` already use, pointed the way each script travels.

| `make teardown SCOPE=` | prod | staging | network | marker becomes |
|---|---|---|---|---|
| `prod` | destroy | — | — | `staging` |
| `staging` | destroy | destroy | — | `network` |
| `network` *(default)* | destroy | destroy | destroy | `foundation` |

| `make rebuild SCOPE=` | network | staging | prod | marker becomes |
|---|---|---|---|---|
| `network` | apply | — | — | `network` |
| `staging` | apply | apply | — | `staging` |
| `prod` *(default)* | apply | apply | apply | `all` |

Both defaults are the whole thing, which is the common case and the one the roadmap describes. Both refuse an unrecognised value by name rather than falling back to the safe end — a `SCOPE=staginng` typo that silently tore down everything would be a bad surprise, and one that silently tore down nothing while printing success would be worse.

The value the marker becomes is derived, never typed twice: teardown writes the scope one rank *below* its shallowest destroyed layer, rebuild writes the scope matching its deepest applied layer.

#### D8 — What "Phase 10 hardens it" means for the teardown script

`scripts/teardown.sh`'s own header says this phase hardens it. Four changes, each answering a failure the first cut has:

- **One typed confirmation, not three Terraform prompts.** The current script relies on Terraform's own `yes` prompt per layer, and its header calls that the safety. Three identical prompts in a row is how the third one gets answered by reflex. Instead: print the layers to be destroyed, what survives, and the marker value about to be written; require the word `destroy`; then `-auto-approve` each layer. `BGD_ASSUME_YES=1` for the runbook and for a re-run after a partial failure.
- **A layer whose state holds no resources is skipped, not destroyed.** `terraform destroy` against empty state succeeds and takes thirty seconds of `init` to do nothing. Re-running teardown after a partial failure is the common case, so it should be quick and it should say which layers it passed over. The current script only skips a layer with no `.tf` files at all, which is a Phase 3-era check for layers that had not been written yet.
- **`-lock-timeout=5m`**, matching both pipeline drivers. Without it, a destroy racing a pipeline apply fails instantly on the lock instead of waiting for it.
- **Per-layer wall-clock timing, printed as a table.** Not decoration: the runbook has to state what a cycle costs in time, and a number measured by the script is better than a number somebody remembered.

#### D9 — `verify-idle.sh` does not trust Terraform state, because state is what is wrong

A clean `terraform destroy` on three layers is not the same claim as "this account is no longer billing". The three cases where they differ are the reason this script exists: a resource created by hand and never in state, a state file that drifted, and a destroy that failed part-way through a layer and left the expensive half running.

So the checks read AWS directly and never open a state file. Five authoritative checks, each on a shape that bills while idle:

| Check | How it finds them | Fails when |
|---|---|---|
| NAT Gateways | `ec2 describe-nat-gateways`, tag filter `projectName=bgd` | any in `pending` or `available` |
| Elastic IPs | `ec2 describe-addresses`, tag filter `projectName=bgd` | any at all — an unassociated EIP bills too |
| Load balancers | `elbv2 describe-load-balancers`, filtered on the `bgd-us-east-1-` name prefix | any in scope |
| ECS services | `ecs list-clusters` / `list-services` on the same prefix | any with `desiredCount > 0` |
| DynamoDB tables | `dynamodb list-tables` on the same prefix | any in scope |

Name prefix where the API has no tag filter, tag filter where it has one. Both derive from the same convention, and the prefix form costs one call instead of three.

Then one catch-all: `resourcegroupstaggingapi get-resources --tag-filters Key=projectName,Values=bgd`, reporting anything in the four **ephemeral** services — `ec2`, `elasticloadbalancing`, `ecs`, `dynamodb` — that the checks above did not already name. Those four are exactly the services in which this project owns nothing that survives a full teardown, which is what makes the rule expressible without an allowlist of the fourteen kinds of thing that do survive. The catch-all is a **warning, not a failure**, because the tagging API is eventually consistent and can still list a resource deleted a minute ago (F2).

Scope-aware, because a partial teardown has a partial answer: `environment=prod` resources are checked always, `environment=staging` only when staging was in scope, and the `ec2` checks only on a full teardown. The `environment` tag separates the two environments; the *service* separates network from foundation, because both tag `environment = "shared"` (F1).

#### D10 — `rebuild.sh`'s preconditions are all read-only, and run before a dollar is spent

Six checks, in this order, all before `terraform apply` touches anything:

1. `aws sts get-caller-identity` returns the expected account — a rebuild into the wrong account is not recoverable by re-running it.
2. The state bucket answers `head-bucket`.
3. `foundation`'s state is readable.
4. `/bgd/platform/deployed_scope` is readable and holds a known value.
5. For each environment layer in scope, `/bgd/<env>/image_tag` is set and is not `unset` or `None`.
6. **For each of those tags, the image is actually in ECR** — `aws ecr describe-images --image-ids imageTag=<tag>`.

The sixth is the one worth arguing for. `data.aws_ecr_image` already fails loudly on a missing tag, so the check is redundant in the sense that nothing wrong gets deployed. It is not redundant in the sense that matters: without it the failure lands at the *staging* layer, which is after `network` has applied, which means a NAT Gateway now exists and is billing while you work out that the tag was wrong. Ten seconds of read-only calls moves that discovery to before the first resource.

`rebuild.sh` reads `image_tag` from SSM exactly as `pipeline-terraform.sh` does, and **`make apply-staging` / `make apply-prod` are left alone** — they still read `terraform.tfvars`. Two paths, deliberately: the by-hand path is for changing the tag, and the rebuild path is for restoring the one that was already deployed. Making `tf.sh` read SSM would take the by-hand override away.

#### D11 — Rebuild smokes each environment, and staging failing stops it before prod

`scripts/smoke.sh <env>` runs after each environment layer applies. It already asserts the four things worth asserting, including that `/version`'s `image_digest` equals the digest Terraform deployed — which is exactly the question a rebuild raises. Phase 8's pipeline runs the identical script for the identical reason.

Staging's smoke failing aborts the run **before** prod applies. That is the same fail-fast shape the application pipeline has, and it is what makes the exit criterion checkable by exit status: `make rebuild` returning 0 means both environments served traffic, not that three applies returned 0.

#### D12 — A dependency-free shell suite, and why not `bats`

This phase adds roughly six hundred lines of shell whose failure mode is destroying the wrong thing, plus rank arithmetic that decides whether production is deployed into. Phase 8 verified its scripts with `bash -n` and executed refusal-path transcripts recorded in the verification document, which is honest evidence but is not a regression test: nothing re-runs it.

So `scripts/tests/` gains a suite and `make test-scripts` joins the offline gate. Roughly forty lines of harness — `check`, `check_contains`, `run_capture` — and a fake `aws` on `PATH` that answers `ssm get-parameter`, `ssm put-parameter` and `sts get-caller-identity` from environment variables and **dies loudly on any other subcommand**, so a test cannot pass by silently reaching an unstubbed call.

Not `bats`, for the reason the offline gate exists: a harness that has to be installed is a harness the gate cannot depend on. `make test-scripts` must run on a laptop that has bash and nothing else, and in CodeBuild without an install step. Forty lines buys the three things a framework would provide here.

The suite tests the pure functions directly and the scripts through their refusal paths. It does not test a real destroy — nothing offline can — which is precisely why D1's runbook still exists.

#### D13 — `layer_dir()` moves into `lib/common.sh`; `lint-infra.sh` is deliberately left out

The layer-name-to-directory map exists three times, and `tf.sh`'s own comment complains about it: *"That map already exists in three places (tf.sh, lint-infra.sh, teardown.sh) and a fourth copy would be a fourth thing to forget."* `rebuild.sh` would be the fourth.

`layer_dir()` moves into `lib/common.sh` and `tf.sh`, `teardown.sh` and `rebuild.sh` all call it — the same move Phase 8 made with `write_vars`, `build_url` and `plan_summary`, for the same rule: two scripts that must not derive the same value differently.

Into `common.sh` rather than a new `lib/layers.sh` for a reason that is not tidiness. The infra pipeline's trigger is at **seven of its eight permitted `filePaths.includes` patterns** (F3), and `scripts/lib/common.sh` is already one of them. A new library file would have to be added as the eighth, spending the last slot on a file that could have been a function.

**`lint-infra.sh` is not converted, and that is a decision rather than an oversight.** Its `layer_path` has a different contract: it returns a path *relative to `infra/`*, and must accept both bare layer names and already-relative paths, because the discovery branch below it yields the latter. Folding it in would mean either broadening the shared function to return two different kinds of path or breaking discovery. Three copies become one plus one documented exception, and the comment in `lint-infra.sh` says which.

#### D14 — `make test-scripts` joins the pipeline's validate stage

`pipelines/infra-validate.yml`'s header states the property it is defending: *"Runs the identical make targets you run locally, which is what makes a green pipeline and a green laptop mean the same thing."* Leaving the new suite out of it would break that sentence in the same commit that makes the suite worth having.

It goes **first**, before `tf-fmt-check`: it is pure bash, needs no container and no Terraform, and runs in under a second. The buildspec's own comment already orders steps cheapest-first.

It is also the step with the strongest claim to being there. The scripts it tests — `tf.sh`, `lib/common.sh`, `pipeline-terraform.sh` — are the scripts *that stage itself runs*.

#### D15 — No Cost Explorer check

Considered and rejected. Confirming that the bill actually fell is the most direct possible reading of "did the teardown work", and Cost Explorer cannot answer it: its data lags roughly a day. Run after a teardown, it reports yesterday — the day the platform was up — and reports it as though it were the answer. A check whose green means nothing and whose red means nothing is worse than no check, because somebody will trust it.

The runbook says instead where to look the next morning, and `make verify-idle` answers the question that can be answered now: is anything still running.

#### D16 — Nothing in this phase can destroy `foundation` or `bootstrap`

`teardown.sh` accepts `SCOPE` values `prod`, `staging` and `network` only. There is no value that reaches `foundation`, no `--all` flag, and no undocumented escape. The five-layer split exists precisely so that the expensive things can be destroyed without touching the certificate, the images, the artifact history, the pipelines, the observability plane or the CodeConnections authorisation — several of which are painful or manual to recreate.

Tearing down `foundation` is a real thing somebody might one day want, and it is a runbook entry with a list of what it costs to undo, not a flag on a script that also runs routinely.

`bootstrap` is further out still: it holds the state for everything else, so destroying it strands every other layer.

---

## 1. Findings recorded before this plan was written

### F1 — `network` and `foundation` both tag `environment = "shared"`

`infra/network/locals.tf:16-21` sets `environment = "shared"`, identical to `infra/foundation/locals.tf`. The two environment layers use their own name. So the `environment` tag separates staging from prod, and cannot separate network from foundation.

It does not need to. This project creates no `ec2` resource outside `network` and no `elasticloadbalancing`, `ecs` or `dynamodb` resource outside the two environment layers. The *service* is the discriminator for network, the `environment` tag is the discriminator between the environments, and D9's checks are built on that split rather than on tags alone.

### F2 — `resourcegroupstaggingapi` is eventually consistent

The tagging API is an index, not the resource itself, and it can list a resource for some minutes after deletion — and can omit one created seconds ago. Used as an assertion it produces false failures immediately after a teardown, which is the exact moment it would be run.

So it is the catch-all and not the check: reported as a warning, phrased as "still indexed", with the direct describe calls carrying the pass/fail verdict.

### F3 — The infra pipeline's trigger is at seven of eight patterns

Phase 9 raised it to seven: `infra/**`, `pipelines/infra-*.yml`, `scripts/pipeline-terraform.sh`, `scripts/install-terraform.sh`, `scripts/tf.sh`, `scripts/lib/common.sh`, `lambdas/**`. `filePaths.includes` accepts a maximum of eight per `push` block (Phase 8 §F11).

This phase adds **no new pattern**, and that is worth stating rather than assuming. `teardown.sh`, `rebuild.sh` and `verify-idle.sh` are operator scripts, not pipeline content — no stage runs them, so a change to one changes nothing about what a run does. `scripts/tests/**` is likewise not watched: the suite is *run by* the validate stage but the stage runs `make test-scripts`, and the makefile is not watched either, which is a pre-existing gap this phase notes and does not fix. The three files this phase edits that *are* watched — `lib/common.sh`, `tf.sh`, `pipeline-terraform.sh` — are already matched.

### F4 — Sourcing `lib/common.sh` turns on `set -euo pipefail`

`lib/common.sh:8` sets it for every script that sources it, which is right for the scripts and hostile to a test suite: a refusal path is a **non-zero exit the suite needs to assert on**, and under `set -e` the first one aborts the run.

Hence `run_capture`, which wraps the call in `set +e` / `set -e`. And hence counters incremented as `X=$((X + 1))` rather than `((X++))` — the latter evaluates to the pre-increment value, so `((X++))` on a zero counter returns status 1 and kills the suite at the first failing check, which is the one moment it must survive.

### F5 — `aws ssm put-parameter --overwrite` creates a parameter that does not exist

`--overwrite` overwrites if present and creates if absent; it does not require prior existence. On this project that is a trap rather than a convenience: if the parameter is missing because `foundation` has not been applied, a bare `put-parameter` creates one outside Terraform's state, and the next `foundation` apply fails trying to create a parameter that already exists.

So `write_deployed_scope` reads before it writes, and dies with "apply the foundation layer first" if the read fails.

### F6 — `lint-infra.sh`'s `layer_path` has a different contract from `layer_dir`

Recorded so the refactor's asymmetry reads as chosen. `layer_path` returns `environments/staging` — relative to `infra/`, because it is passed to `docker run -w`. `layer_dir` returns an absolute path, because it is passed to `terraform -chdir` and to `compgen -G`. `layer_path` must also pass through an already-relative path unchanged, since `lint-infra.sh`'s discovery branch produces those. See D13.

### F7 — `pipeline-deploy.sh` already defines `scope_rank`, with a different vocabulary

`pipeline-deploy.sh:85` ranks `build`/`staging`/`all` (APP_SCOPE); `pipeline-terraform.sh:60` ranks `foundation`/`network`/`staging`/`all` (DEPLOY_SCOPE). Same function name, different meaning, in two files that both source `common.sh`.

A shared helper named `scope_rank` would be shadowed by whichever local definition came later — silently, because bash redefines without complaint. The shared helpers are therefore named `platform_scope_rank` and `platform_layer_rank`, `pipeline-terraform.sh`'s two local copies are deleted in favour of them, and `pipeline-deploy.sh` keeps its own two under their existing names because they mean something else.

### F8 — A NAT Gateway in `deleting` still appears in `describe-nat-gateways`

Deletion is asynchronous and the gateway lingers in state `deleting` for some minutes. Billing stops at deletion, so `deleting` is not a failure — but reporting it as a clean pass hides the fact that the account is not yet in its final state, which matters if the next thing you do is a rebuild.

`verify-idle.sh` treats `pending` and `available` as failures, `deleting` as a warning naming the gateway, and `deleted`/`failed` as absent.

### Findings discovered during implementation

*(Appended during execution; see the local verification record.)*

---

## 2. Global constraints

Restating the ones this phase breaks if it gets them wrong, with the symptom attached.

| Constraint | Symptom if missed |
|---|---|
| `teardown.sh` writes the marker **before** the first destroy (D3) | A merge landing during the destroy deploys into an account being dismantled; a half-failed teardown leaves both pipelines believing prod is up. |
| `rebuild.sh` writes the marker **after each** layer, not once at the end (D3) | A rebuild that dies at prod tells both pipelines to deploy to a production that does not exist. |
| `ignore_changes = [value]` on the new parameter (D4) | The next `foundation` apply resets it to `all`, and the following merge deploys into a torn-down account. Both applies are green. |
| The parameter defaults to `all`, not `foundation` (D4) | Every runbook from Phase 4 on gains an undocumented step, and a fresh account's `network` stage skips for no reason anyone can see. |
| `foundation` is exempt from the marker read (D6) | A fresh account cannot apply the layer that creates the parameter the apply demands. Deadlock on the first run. |
| Out-of-marker layers **skip green**, never fail (D5) | Phase 9's change-failure-rate counts a correct decision not to deploy as a failed deployment, and emails you about it. |
| The clamp message differs from the scope message (D5) | The console says "outside DEPLOY_SCOPE=all" when the scope is fine, and the next hour goes into debugging scope handling. |
| The shared rank helpers are **not** named `scope_rank` (F7) | `pipeline-deploy.sh`'s local definition shadows the shared one, or vice versa depending on source order, and APP_SCOPE is ranked against the wrong vocabulary. |
| `write_deployed_scope` reads before it writes (F5) | A missing parameter is created outside Terraform, and the next `foundation` apply fails on a name that already exists. |
| Counters use `X=$((X + 1))`, never `((X++))` (F4) | The suite exits at the first failing check, reporting one failure where there are nine. |
| `SCOPE` refuses unknown values by name (D7) | A typo silently tears down everything, or silently tears down nothing while printing success. |
| No `SCOPE` value reaches `foundation` (D16) | The certificate, the images, the pipelines and the CodeConnections authorisation are destroyed by a routine command. |
| `verify-idle.sh` opens no state file (D9) | It agrees with Terraform in exactly the three cases where Terraform is wrong, which are the only cases it exists for. |
| The ECR tag check runs before `network` applies (D10) | A wrong tag is discovered after the NAT Gateway exists and has started billing. |

---

## 3. File structure

```
scripts/
  lib/common.sh              MODIFIED  layer_dir, the two rank helpers, the marker
                                       read/write, min_rank
  tf.sh                      MODIFIED  the inline case becomes layer_dir
  teardown.sh                REWRITTEN scope, confirmation, marker-first, empty-state
                                       skip, timing
  rebuild.sh                 NEW       preconditions, ordered applies, smoke, marker
                                       per layer, timing
  verify-idle.sh             NEW       five direct checks plus one tagged sweep
  pipeline-terraform.sh      MODIFIED  local ranks deleted, clamp added
  pipeline-deploy.sh         MODIFIED  clamp added, local ranks untouched
  lint-infra.sh              MODIFIED  one comment: why layer_path stays (D13, F6)
  README.md                  MODIFIED  the three new scripts and the suite
  tests/
    lib.sh                   NEW       check, check_contains, run_capture
    run.sh                   NEW       runs every test_*.sh, sums the results
    fake-bin/aws             NEW       the stubbed CLI; dies on any unstubbed call
    test_common.sh           NEW       layer_dir, ranks, min_rank, marker read/write
    test_pipeline_scope.sh   NEW       both drivers' clamp and refusal paths
    test_operator_scripts.sh NEW       teardown/rebuild/verify-idle guards

infra/foundation/
  ssm.tf                     MODIFIED  aws_ssm_parameter.deployed_scope
  outputs.tf                 MODIFIED  deployed_scope_parameter_name
  README.md                  MODIFIED  the layer now owns the platform marker
  tests/
    pipeline_shape.tftest.hcl MODIFIED the parameter, its default, its lifecycle,
                                       and the output

pipelines/
  infra-validate.yml         MODIFIED  make test-scripts, first (D14)

makefile                     MODIFIED  rebuild, verify-idle, test-scripts; teardown's
                                       SCOPE; the PLANNED line removed

docs/
  runbooks/phase-10-teardown-and-rebuild.md   NEW
  runbooks/README.md                          MODIFIED  the row that says "planned",
                                                        and the trigger paragraph
  runbooks/phase-08-app-pipeline.md           MODIFIED  §11 no longer says
                                                        "disable both triggers"
  phases/phase10/
    2026-08-30-phase-10-implementation-plan.md  this document
    2026-08-30-local-verification.md            NEW  the evidence record
  2026-08-04-implementation-phase-roadmap.md    MODIFIED  Phase 10's amendment, and
                                                          notes in Phases 7 and 8
```

**Why these boundaries.** Three operator scripts rather than one with three modes, because they answer three different questions asked at three different times — *stop paying*, *is it really stopped*, *start again* — and the middle one is the one you run alone, the morning after, when the other two are not what you want.

`verify-idle.sh` is separate from `teardown.sh` specifically so it can be re-run. Folding it into teardown would make "the destroy failed" and "the destroy succeeded but something survived" the same red exit from the same command, and would give no way to check an account nobody tore down today.

The test suite splits by what it protects: `test_common.sh` covers pure functions where a wrong rank is a wrong deployment; `test_pipeline_scope.sh` covers the two drivers, which are the files where a clamp bug reaches production; `test_operator_scripts.sh` covers the guards on the three scripts that destroy and create.

---

## 4. Tasks

Eleven tasks. Tests precede implementation throughout — for shell that means the assertion is written against a function that does not exist yet and **seen to fail**, and for Terraform it means the `.tftest.hcl` run block is written before the resource it asserts on.

Every task ends with its suite passing and a commit **proposed for approval, never made automatically**. The full gate — `make tf-check`, `make test-scripts` and `make test-lambdas` — runs at Task 9 and again at Task 11.

---

### Task 1: The shell suite, and `layer_dir()` moved into `lib/common.sh`

First, because every later task's tests need the harness and every later script needs the function. Nothing here touches AWS or Terraform behaviour: the map moves, the callers change, the behaviour is identical.

**Files:**
- Create: `scripts/tests/lib.sh`
- Create: `scripts/tests/run.sh`
- Create: `scripts/tests/test_common.sh`
- Modify: `scripts/lib/common.sh` (append a new section)
- Modify: `scripts/tf.sh:38-42` (the inline `case`)
- Modify: `scripts/teardown.sh:24-32` (the local `layer_dir`)
- Modify: `scripts/lint-infra.sh:24-37` (comment only)
- Modify: `makefile` (the `test-scripts` target)

**Interfaces:**
- Produces: `layer_dir <layer>` → absolute path to a layer's root module, dies on an unknown layer. `check <desc> <expected> <actual>`, `check_contains <desc> <needle> <haystack>`, `run_capture <cmd...>` setting `OUTPUT` and `STATUS`.
- Consumes: `repo_root`, `die`, `info`, `ok` from `lib/common.sh`.

- [ ] **Step 1: Write the harness**

Create `scripts/tests/lib.sh`:

```bash
#!/usr/bin/env bash
# Assertions for the shell suite. Sourced by every scripts/tests/test_*.sh;
# do not execute it.
#
# Deliberately not bats. A harness that has to be installed is a harness the
# offline gate cannot depend on: `make test-scripts` must run on a laptop that
# has bash and nothing else, and in CodeBuild with no install step. Forty
# lines buys the three things a framework would provide here. Plan §D12.

CHECKS_RUN=0
CHECKS_FAILED=0

# Counters are incremented as X=$((X + 1)) and never as ((X++)).
#
# ((X++)) evaluates to the value BEFORE the increment, so on a zero counter it
# returns status 1 — and every script under test sources lib/common.sh, which
# sets -e. The suite would then exit at the first failing check, reporting one
# failure where there are nine, at the one moment it most needs to survive.
# Plan §F4.

# check <description> <expected> <actual>
check() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  if [[ "$2" == "$3" ]]; then
    printf '  ✓ %s\n' "$1"
  else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    printf '  ✗ %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
  fi
}

# check_contains <description> <needle> <haystack>
check_contains() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  if [[ "$3" == *"$2"* ]]; then
    printf '  ✓ %s\n' "$1"
  else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    printf '  ✗ %s\n      expected to contain: %s\n      actual:              %s\n' "$1" "$2" "$3"
  fi
}

# run_capture <command...> — run it, capture stdout+stderr into OUTPUT and the
# exit status into STATUS, without letting a non-zero status abort the suite.
#
# The set +e is the whole point. A refusal path is a NON-ZERO exit this suite
# needs to assert on rather than die from, and every script under test inherits
# set -e from lib/common.sh. Plan §F4.
run_capture() {
  set +e
  OUTPUT="$("$@" 2>&1)"
  STATUS=$?
  set -e
}

# report — the trailing summary and this file's exit status.
report() {
  printf '\n  %s: %d checks, %d failed\n' "$(basename "$0")" "$CHECKS_RUN" "$CHECKS_FAILED"
  ((CHECKS_FAILED == 0))
}
```

Create `scripts/tests/run.sh`:

```bash
#!/usr/bin/env bash
#
# The shell suite. Runs every scripts/tests/test_*.sh in its own process and
# sums the results.
#
#   make test-scripts
#
# Needs no AWS session, no Terraform state and no network: the scripts under
# test reach AWS only through the fake CLI in fake-bin/, which the individual
# test files put on PATH. Plan §D12.
#
# NOT set -e: a failing test file must be reported and the remaining files
# still run. A single red file that aborts the suite hides how much else broke.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failed=0
total=0

for file in "$HERE"/test_*.sh; do
  printf '\n\033[34m==>\033[0m %s\n' "$(basename "$file")"
  total=$((total + 1))
  bash "$file" || failed=$((failed + 1))
done

printf '\n'
if ((failed == 0)); then
  printf '\033[32m  ✓\033[0m %d test files passed\n\n' "$total"
else
  printf '\033[31m  ✗\033[0m %d of %d test files failed\n\n' "$failed" "$total"
fi

((failed == 0))
```

- [ ] **Step 2: Write the failing test for `layer_dir`**

Create `scripts/tests/test_common.sh`:

```bash
#!/usr/bin/env bash
#
# lib/common.sh's Phase 10 additions: the layer map, the two rank vocabularies,
# and the marker read and write.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

source "$HERE/lib.sh"
source "$ROOT/scripts/lib/common.sh"

# --- layer_dir ---------------------------------------------------------------
#
# The map lived in three scripts and was about to live in a fourth. tf.sh's own
# comment asked for this. Plan §D13.

check "layer_dir foundation"   "$ROOT/infra/foundation"           "$(layer_dir foundation)"
check "layer_dir bootstrap"    "$ROOT/infra/bootstrap"            "$(layer_dir bootstrap)"
check "layer_dir network"      "$ROOT/infra/network"              "$(layer_dir network)"
check "layer_dir staging"      "$ROOT/infra/environments/staging" "$(layer_dir staging)"
check "layer_dir prod"         "$ROOT/infra/environments/prod"    "$(layer_dir prod)"

run_capture layer_dir nonsense
check          "layer_dir refuses an unknown layer"          "1" "$STATUS"
check_contains "…and names what it expected"  "expected bootstrap, foundation, network, staging or prod" "$OUTPUT"

report
```

- [ ] **Step 3: Run it and watch it fail**

```bash
chmod +x scripts/tests/run.sh scripts/tests/test_common.sh
bash scripts/tests/test_common.sh
```

Expected: FAIL — `layer_dir: command not found` on the first `check`, six failing checks and a non-zero exit.

- [ ] **Step 4: Add `layer_dir` to `lib/common.sh`**

Append to `scripts/lib/common.sh`:

```bash
# ---------------------------------------------------------------------------
# Phase 10 — layers, and the platform scope marker
# ---------------------------------------------------------------------------

# layer_dir <layer> — absolute path to a layer's root module.
#
# The map that tf.sh, teardown.sh and lint-infra.sh each carried a copy of, and
# that rebuild.sh would have been the fourth to copy. tf.sh's own comment asked
# for this. Plan §D13.
#
# lint-infra.sh is deliberately NOT converted: its layer_path returns a path
# relative to infra/ and has to pass an already-relative path through unchanged,
# which is a different contract from this one. Plan §F6.
#
# Errors go to stderr through die(), which matters here more than usual: this is
# always called inside "$(...)", and a die() writing to stdout would be captured
# into the variable being assigned and the caller would exit 1 in silence. That
# cost real debugging time in Phase 3; see die()'s own comment above.
layer_dir() {
  local root
  root="$(repo_root)"
  case "$1" in
    bootstrap | foundation | network) printf '%s/infra/%s\n' "$root" "$1" ;;
    staging | prod) printf '%s/infra/environments/%s\n' "$root" "$1" ;;
    *) die "unknown layer: $1 (expected bootstrap, foundation, network, staging or prod)" ;;
  esac
}
```

- [ ] **Step 5: Run it and watch it pass**

```bash
bash scripts/tests/test_common.sh
```

Expected: `test_common.sh: 7 checks, 0 failed`, exit 0.

- [ ] **Step 6: Convert the two callers**

In `scripts/tf.sh`, replace the inline `case "$layer" in … esac` block (and keep the comment above it, rewritten) with:

```bash
# The map moved to lib/common.sh in Phase 10, when rebuild.sh would have been
# the fourth copy. The original comment here recorded why it was inline rather
# than in a helper — die() wrote to stdout, so a failure inside "$(...)" was
# captured instead of shown. die() writes to stderr now, which is what makes
# the shared helper safe to call this way.
dir="$(layer_dir "$layer")"
```

In `scripts/teardown.sh`, delete the local `layer_dir()` definition entirely — the name and the contract are identical, so every call site already works.

In `scripts/lint-infra.sh`, replace the paragraph beginning *"This is the same mapping scripts/tf.sh and scripts/teardown.sh each carry"* with:

```bash
# Phase 10 moved that shared map into lib/common.sh as layer_dir(), and this
# function is deliberately NOT it: layer_dir returns an ABSOLUTE path, while
# docker's -w needs one relative to infra/ — and this has to pass an
# already-relative path through unchanged, because the discovery branch below
# yields those. Plan §D13 and §F6.
```

- [ ] **Step 7: Prove the conversion changed no behaviour**

```bash
bash -n scripts/tf.sh scripts/teardown.sh scripts/lint-infra.sh
./scripts/tf.sh validate network
./scripts/tf.sh fmt prod
```

Expected: `bash -n` silent; `terraform validate — network` then `Success! The configuration is valid.`; `fmt` prints nothing. Both prove `layer_dir` resolves through the shared helper for a layer at each depth.

- [ ] **Step 8: Add the makefile target**

In `makefile`, after the `test-lambdas` target, add a new section:

```make
# ---------------------------------------------------------------------------
# Phase 10 — teardown and rebuild
# ---------------------------------------------------------------------------

# The shell suite. Pure bash: no virtualenv, no Terraform, no AWS session, and
# no installed test framework — the scripts reach AWS only through the fake CLI
# in scripts/tests/fake-bin. See the plan's D12.
.PHONY: test-scripts
test-scripts: ## Run the shell suite for scripts/ (no AWS session needed)
	@./scripts/tests/run.sh
```

- [ ] **Step 9: Run the suite through make**

```bash
make test-scripts
```

Expected: `✓ 1 test files passed`.

- [ ] **Step 10: Commit**

```bash
git add scripts/tests scripts/lib/common.sh scripts/tf.sh scripts/teardown.sh scripts/lint-infra.sh makefile
git commit -m "test(phase10): shell suite harness, and layer_dir shared in lib/common.sh"
```

---

### Task 2: The platform-scope vocabulary and the marker helpers

**Files:**
- Modify: `scripts/lib/common.sh` (the same new section)
- Create: `scripts/tests/fake-bin/aws`
- Modify: `scripts/tests/test_common.sh`

**Interfaces:**
- Produces: `platform_scope_rank <foundation|network|staging|all>` → `1..4`, `0` unknown. `platform_layer_rank <foundation|network|staging|prod>` → `1..4`, `99` unknown. `min_rank <a> <b>`. `read_deployed_scope` → the marker's value on stdout, dies on failure. `write_deployed_scope <value>`. `DEPLOYED_SCOPE_PARAM` = `/bgd/platform/deployed_scope`.
- Consumes: `platform_scope_rank` is consumed by Tasks 4, 5, 6 and 8; `read_deployed_scope` by Tasks 4 and 5; `write_deployed_scope` by Tasks 6 and 8.

- [ ] **Step 1: Write the fake AWS CLI**

Create `scripts/tests/fake-bin/aws`:

```bash
#!/usr/bin/env bash
#
# A stand-in for the AWS CLI, put on PATH by the shell suite so the marker,
# clamp and precondition paths can be exercised on a machine with no AWS
# session at all. Plan §D12.
#
# Driven entirely by environment variables the test sets:
#
#   FAKE_SSM_DEPLOYED_SCOPE   value returned for /bgd/platform/deployed_scope.
#                             Empty makes get-parameter FAIL, which is what a
#                             missing parameter does.
#   FAKE_SSM_IMAGE_TAG        value returned for any /bgd/<env>/image_tag.
#                             Empty makes get-parameter fail.
#   FAKE_ACCOUNT_ID           value returned by sts get-caller-identity.
#   FAKE_S3_MISSING=1         makes every s3api head-* call fail.
#   FAKE_ECR_MISSING=1        makes ecr describe-images fail, as an absent tag
#                             does.
#   FAKE_AWS_LOG              file every invocation is appended to, so a test
#                             can assert on call ORDER — which is how the
#                             marker-before-destroy rule is checked.
#
# Any subcommand not stubbed below exits 90 with a loud message. That is
# deliberate: a fake that returns empty success for unknown calls lets a test
# pass by reaching an unstubbed path, which is the one thing a fake must never
# do.

set -uo pipefail

if [[ -n "${FAKE_AWS_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$FAKE_AWS_LOG"
fi

# The CLI accepts its arguments in any order, so the stub scans for what it
# needs rather than assuming positions.
name=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "--name" ]] && name="$arg"
  prev="$arg"
done

case "$1 ${2:-}" in
  "ssm get-parameter")
    case "$name" in
      /bgd/platform/deployed_scope)
        [[ -n "${FAKE_SSM_DEPLOYED_SCOPE:-}" ]] || {
          printf 'ParameterNotFound\n' >&2
          exit 255
        }
        printf '%s\n' "$FAKE_SSM_DEPLOYED_SCOPE"
        ;;
      /bgd/*/image_tag)
        [[ -n "${FAKE_SSM_IMAGE_TAG:-}" ]] || {
          printf 'ParameterNotFound\n' >&2
          exit 255
        }
        printf '%s\n' "$FAKE_SSM_IMAGE_TAG"
        ;;
      *)
        printf 'fake aws: no stub for parameter %s\n' "$name" >&2
        exit 90
        ;;
    esac
    ;;

  "ssm put-parameter")
    # Silent success, like the real thing with --overwrite. The assertion a
    # test makes about a write is on FAKE_AWS_LOG, not on this output.
    ;;

  "sts get-caller-identity")
    printf '%s\n' "${FAKE_ACCOUNT_ID:-590184028094}"
    ;;

  "s3api head-bucket" | "s3api head-object")
    [[ -z "${FAKE_S3_MISSING:-}" ]] || {
      printf 'Not Found\n' >&2
      exit 254
    }
    ;;

  "ecr describe-images")
    [[ -z "${FAKE_ECR_MISSING:-}" ]] || {
      printf 'ImageNotFoundException\n' >&2
      exit 254
    }
    ;;

  *)
    printf 'fake aws: no stub for `%s` — add one rather than letting the test pass on an unstubbed call\n' "$*" >&2
    exit 90
    ;;
esac
```

- [ ] **Step 2: Write the failing tests**

Append to `scripts/tests/test_common.sh`, before the final `report`:

```bash
# --- the two rank vocabularies -----------------------------------------------
#
# Named platform_* and NOT scope_rank, because pipeline-deploy.sh already
# defines scope_rank over a DIFFERENT vocabulary (build/staging/all) and bash
# redefines a function without complaint. Plan §F7.

check "scope rank: foundation" "1" "$(platform_scope_rank foundation)"
check "scope rank: network"    "2" "$(platform_scope_rank network)"
check "scope rank: staging"    "3" "$(platform_scope_rank staging)"
check "scope rank: all"        "4" "$(platform_scope_rank all)"
check "scope rank: unknown ranks 0, below every layer" "0" "$(platform_scope_rank prod)"

check "layer rank: foundation" "1"  "$(platform_layer_rank foundation)"
check "layer rank: network"    "2"  "$(platform_layer_rank network)"
check "layer rank: staging"    "3"  "$(platform_layer_rank staging)"
check "layer rank: prod"       "4"  "$(platform_layer_rank prod)"
check "layer rank: unknown ranks 99, above every scope" "99" "$(platform_layer_rank all)"

check "min_rank takes the smaller" "2" "$(min_rank 2 4)"
check "min_rank is symmetric"      "2" "$(min_rank 4 2)"
check "min_rank of equals"         "3" "$(min_rank 3 3)"

# The property the clamp rests on: foundation is in scope under every valid
# marker value, so the layer that CREATES the marker can always be applied.
# Plan §D6.
for marker in foundation network staging all; do
  check "foundation is in scope when the marker is $marker" \
    "yes" \
    "$(if (($(platform_layer_rank foundation) <= $(min_rank "$(platform_scope_rank all)" "$(platform_scope_rank "$marker")"))); then echo yes; else echo no; fi)"
done

# --- the marker --------------------------------------------------------------

export PATH="$HERE/fake-bin:$PATH"

check "the parameter name is the one foundation creates" \
  "/bgd/platform/deployed_scope" "$DEPLOYED_SCOPE_PARAM"

FAKE_SSM_DEPLOYED_SCOPE=staging
export FAKE_SSM_DEPLOYED_SCOPE
check "read_deployed_scope returns the value" "staging" "$(read_deployed_scope)"

FAKE_SSM_DEPLOYED_SCOPE=nonsense
run_capture read_deployed_scope
check          "read_deployed_scope refuses a value outside the vocabulary" "1" "$STATUS"
check_contains "…and names the four it accepts" "expected one of foundation, network, staging, all" "$OUTPUT"

# A missing parameter is a hard failure, never an assumed `all`. A gate that
# fails open is not a gate. Plan §D6.
FAKE_SSM_DEPLOYED_SCOPE=""
run_capture read_deployed_scope
check          "a missing parameter is fatal, not assumed" "1" "$STATUS"
check_contains "…and says to apply foundation" "apply the foundation layer" "$OUTPUT"

# write_deployed_scope READS first, so a put-parameter --overwrite cannot create
# a parameter outside Terraform's state. Plan §F5.
FAKE_SSM_DEPLOYED_SCOPE=""
run_capture write_deployed_scope network
check          "write refuses when the parameter does not exist" "1" "$STATUS"
check_contains "…for the reason --overwrite would otherwise create it" "apply the foundation layer" "$OUTPUT"

FAKE_SSM_DEPLOYED_SCOPE=all
run_capture write_deployed_scope sideways
check          "write refuses a value outside the vocabulary" "1" "$STATUS"
check_contains "…and names it" "refusing to write 'sideways'" "$OUTPUT"

FAKE_AWS_LOG="$(mktemp)"
export FAKE_AWS_LOG
FAKE_SSM_DEPLOYED_SCOPE=all
run_capture write_deployed_scope foundation
check "write succeeds on a valid value" "0" "$STATUS"
check_contains "…and calls put-parameter with it" "put-parameter" "$(cat "$FAKE_AWS_LOG")"
check_contains "…carrying the new value" "foundation" "$(cat "$FAKE_AWS_LOG")"
rm -f "$FAKE_AWS_LOG"
unset FAKE_AWS_LOG
```

- [ ] **Step 3: Run and watch it fail**

```bash
chmod +x scripts/tests/fake-bin/aws
bash scripts/tests/test_common.sh
```

Expected: FAIL — `platform_scope_rank: command not found` and every new check red.

- [ ] **Step 4: Implement the helpers**

Append to `scripts/lib/common.sh`, in the Phase 10 section under `layer_dir`:

```bash
# The four values /bgd/platform/deployed_scope holds, ranked. The SAME four
# DEPLOY_SCOPE uses, deliberately — pipeline-terraform.sh already ranks them and
# foundation/locals.tf already orders them, so a second vocabulary for the same
# idea would be a second thing to keep in step. Plan §D2.
#
# Named platform_scope_rank rather than scope_rank because pipeline-deploy.sh
# defines a scope_rank of its own over build/staging/all, and bash redefines a
# function silently. Plan §F7.
#
# An unrecognised value ranks 0, below every layer, so it can only ever produce
# "nothing is deployed" rather than a partial and unintended one.
platform_scope_rank() {
  case "$1" in
    foundation) echo 1 ;;
    network) echo 2 ;;
    staging) echo 3 ;;
    all) echo 4 ;;
    *) echo 0 ;;
  esac
}

# The layers, ranked on the same scale. `all` is not a layer, so it ranks 99
# here — above every scope — which is what makes an unknown name skip rather
# than apply.
platform_layer_rank() {
  case "$1" in
    foundation) echo 1 ;;
    network) echo 2 ;;
    staging) echo 3 ;;
    prod) echo 4 ;;
    *) echo 99 ;;
  esac
}

min_rank() {
  if (($1 < $2)); then echo "$1"; else echo "$2"; fi
}

# The marker: how deep the platform is currently applied.
#
# Written ONLY by scripts/teardown.sh and scripts/rebuild.sh, and defaulted to
# `all` by Terraform so that it can only ever restrict, and only after somebody
# explicitly ran a teardown. It is a teardown marker, not a deployment registry:
# it does not know that `make apply-prod` was run by hand. Plan §D2 and §D4.
DEPLOYED_SCOPE_PARAM="/bgd/platform/deployed_scope"

# read_deployed_scope — the marker's current value, on stdout.
#
# Dies rather than assuming `all` on a read failure, and that is the decision
# rather than an oversight: assuming `all` would mean a lost ssm:GetParameter
# permission silently restores the behaviour the marker exists to remove, with
# nothing anywhere reporting it. Plan §D6.
read_deployed_scope() {
  local value
  value="$(aws ssm get-parameter \
    --region "${AWS_REGION:-us-east-1}" \
    --name "$DEPLOYED_SCOPE_PARAM" \
    --query 'Parameter.Value' --output text 2>/dev/null)" ||
    die "cannot read $DEPLOYED_SCOPE_PARAM — apply the foundation layer, which is what creates it"

  (($(platform_scope_rank "$value") > 0)) ||
    die "$DEPLOYED_SCOPE_PARAM is '$value'; expected one of foundation, network, staging, all"

  printf '%s' "$value"
}

# write_deployed_scope <value> — record how deep the platform is applied.
#
# The read first is not a courtesy check. `put-parameter --overwrite` CREATES a
# parameter that does not exist, so without it a write against an account where
# foundation was never applied would create one outside Terraform's state — and
# the next foundation apply would fail on a name that already exists. Plan §F5.
write_deployed_scope() {
  local value="$1"

  (($(platform_scope_rank "$value") > 0)) ||
    die "refusing to write '$value' to $DEPLOYED_SCOPE_PARAM; expected one of foundation, network, staging, all"

  read_deployed_scope >/dev/null

  aws ssm put-parameter \
    --region "${AWS_REGION:-us-east-1}" \
    --name "$DEPLOYED_SCOPE_PARAM" \
    --value "$value" \
    --type String \
    --overwrite >/dev/null ||
    die "could not write $DEPLOYED_SCOPE_PARAM"

  ok "$DEPLOYED_SCOPE_PARAM now records $value"
}
```

- [ ] **Step 5: Run and watch it pass**

```bash
make test-scripts
```

Expected: `test_common.sh: 37 checks, 0 failed`, then `✓ 1 test files passed`.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/common.sh scripts/tests
git commit -m "feat(phase10): platform scope ranks and the deployed_scope marker helpers"
```

---

### Task 3: The marker parameter in `foundation`

**Files:**
- Modify: `infra/foundation/ssm.tf`
- Modify: `infra/foundation/outputs.tf`
- Modify: `infra/foundation/tests/pipeline_shape.tftest.hcl`
- Modify: `infra/foundation/README.md`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `aws_ssm_parameter.deployed_scope` at `/bgd/platform/deployed_scope`; `output.deployed_scope_parameter_name`.

- [ ] **Step 1: Write the failing test**

Append to `infra/foundation/tests/pipeline_shape.tftest.hcl`, after the `every_environment_layer_has_an_image_tag_parameter` run block:

```hcl
run "the_platform_carries_a_deployed_scope_marker" {
  command = plan

  assert {
    condition     = aws_ssm_parameter.deployed_scope.name == "/bgd/platform/deployed_scope"
    error_message = "scripts/lib/common.sh looks this name up as a literal; the two must agree or teardown writes a parameter nothing reads"
  }

  # `all`, not `foundation`, and the difference is what a fresh account does.
  # A marker defaulting to foundation would clamp `network` on an account that
  # had simply never been torn down, and every runbook from Phase 4 on would
  # need a step it does not have. Plan §D4.
  assert {
    condition     = aws_ssm_parameter.deployed_scope.value == "all"
    error_message = "the marker must default to all, so it can only ever restrict — and only after somebody ran teardown"
  }

  assert {
    condition     = aws_ssm_parameter.deployed_scope.type == "String"
    error_message = "a scope name is read by two pipeline roles and printed in every skip message; SecureString would imply it is a secret and cost both roles a KMS grant"
  }

  # `ignore_changes = [value]` cannot be asserted here: lifecycle is a
  # meta-argument and has no representation in a resource's plan object. What
  # CAN be asserted is the property that makes it necessary — the value is a
  # literal that every apply would otherwise reassert — plus a description that
  # names the two writers, so a reader who removes the lifecycle block has been
  # told what it was for.
  assert {
    condition     = strcontains(aws_ssm_parameter.deployed_scope.description, "teardown.sh") && strcontains(aws_ssm_parameter.deployed_scope.description, "rebuild.sh")
    error_message = "the description must name both writers; ignore_changes = [value] is what stops the next apply reverting them, and it is reviewed rather than planned"
  }
}
```

And append to the existing `the_outputs_phase_8_and_9_consume_are_present` run block:

```hcl
  assert {
    condition     = output.deployed_scope_parameter_name == "/bgd/platform/deployed_scope"
    error_message = "Phase 10's runbook reads the marker through this output rather than typing the path again"
  }
```

- [ ] **Step 2: Run and watch it fail**

```bash
./scripts/tf.sh test foundation
```

Expected: FAIL — `A managed resource "aws_ssm_parameter" "deployed_scope" has not been declared`.

- [ ] **Step 3: Add the parameter**

Append to `infra/foundation/ssm.tf`:

```hcl
# ---------------------------------------------------------------------------
# Phase 10 — how deep the platform is currently applied
# ---------------------------------------------------------------------------
#
# One of foundation | network | staging | all — the same four values
# DEPLOY_SCOPE uses, deliberately. pipeline-terraform.sh already ranks them and
# locals.tf's pipeline_layers already orders them; a second vocabulary for the
# same idea would be a second thing to keep in step. Plan §D2.
#
# Written ONLY by scripts/teardown.sh and scripts/rebuild.sh, and read by both
# pipeline drivers, which clamp their own scope to it. What that buys is a merge
# to main after a teardown that validates, applies this layer, builds and pushes
# an image — and creates no network, no ALB and no Fargate task. What it costs
# is that a merge can no longer rebuild a torn-down layer: `make rebuild` is the
# only thing that raises this value. That is the point rather than a side
# effect. Plan §D5.
#
# In THIS layer because it has to survive what it describes. Anywhere else and
# the record of "the platform is torn down" is destroyed by the teardown — the
# same argument image_tag above makes, and the same one Phase 9's D2 makes for
# the whole observability plane.
#
# `platform` occupies the position `staging` and `prod` occupy in the two
# parameters above, and is deliberately not an environment: it names the whole
# thing.

resource "aws_ssm_parameter" "deployed_scope" {
  # checkov:skip=CKV2_AWS_34:SecureString for a value printed in every pipeline skip message and read by two pipeline roles. Encrypting it would imply it is a secret and cost both roles a KMS grant to read the word "staging". Same trade as image_tag above.
  name = "/bgd/platform/deployed_scope"
  type = "String"

  # `all`, not the more literally-honest `foundation`, and the difference is
  # what happens on a fresh account. Layers are applied in order and this one is
  # first; a marker defaulting to `foundation` would clamp `network` on an
  # account nobody had ever torn down, and every runbook from Phase 4 onward
  # would need a step it does not have. Defaulting to `all` means the marker
  # only ever RESTRICTS, and only after somebody explicitly ran teardown.
  # Plan §D4.
  value = "all"

  description = "How deep the platform is currently applied: foundation, network, staging or all. Written by scripts/teardown.sh and scripts/rebuild.sh; read by both pipeline drivers, which clamp their scope to it."

  lifecycle {
    # The whole point, and the same reason image_tag carries it. Without this
    # the next foundation apply resets the marker to `all` and the following
    # merge deploys into a torn-down account — with both applies green.
    ignore_changes = [value]
  }
}
```

- [ ] **Step 4: Add the output**

Append to `infra/foundation/outputs.tf`, after `image_tag_parameter_names`:

```hcl
output "deployed_scope_parameter_name" {
  description = "SSM parameter holding how deep the platform is currently applied. Written by scripts/teardown.sh and scripts/rebuild.sh; read by both pipeline drivers. Phase 10's runbook reads it through here rather than typing the path again."
  value       = aws_ssm_parameter.deployed_scope.name
}
```

- [ ] **Step 5: Run and watch it pass**

```bash
./scripts/tf.sh test foundation
```

Expected: `Success!` with three more passing runs than before.

- [ ] **Step 6: Static analysis on the new resource**

```bash
./scripts/lint-infra.sh foundation
```

Expected: tflint clean; checkov reports one more skipped check (`CKV2_AWS_34`) and no new failures.

- [ ] **Step 7: Update the layer README**

In `infra/foundation/README.md`, add the marker to the list of what this layer owns, phrased as what it is for:

```markdown
- **`/bgd/platform/deployed_scope`** — how deep the platform is currently
  applied. Written by `make teardown` and `make rebuild`; read by both pipeline
  drivers, which clamp their own scope to it so that a merge to `main` while the
  platform is torn down skips the layers that do not exist rather than
  recreating them. It lives here because it has to survive what it describes.
```

- [ ] **Step 8: Commit**

```bash
git add infra/foundation
git commit -m "feat(phase10): /bgd/platform/deployed_scope, the teardown marker foundation keeps"
```

---

### Task 4: `pipeline-terraform.sh` clamps to the marker

**Files:**
- Modify: `scripts/pipeline-terraform.sh:56-75` (delete both local rank functions), and the gate section
- Create: `scripts/tests/test_pipeline_scope.sh`

**Interfaces:**
- Consumes: `platform_scope_rank`, `platform_layer_rank`, `min_rank`, `read_deployed_scope` from Task 2.
- Produces: the clamp behaviour Task 10's runbook documents and Task 5 mirrors.

- [ ] **Step 1: Write the failing tests**

Create `scripts/tests/test_pipeline_scope.sh`:

```bash
#!/usr/bin/env bash
#
# Both pipeline drivers' scope handling: their own scope variable, the marker
# clamp, and the difference between the two skip messages.
#
# Every case here exits before terraform is invoked, which is what lets the
# suite run with no AWS session and no state backend. A case that reached
# terraform would be testing terraform.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

source "$HERE/lib.sh"

export PATH="$HERE/fake-bin:$PATH"

TF="$ROOT/scripts/pipeline-terraform.sh"

# --- the marker clamp --------------------------------------------------------
#
# A merge to main while the platform is torn down must SKIP the layers that do
# not exist, green, and say why in words that are true. Plan §D5.

export DEPLOY_SCOPE=all
export FAKE_SSM_DEPLOYED_SCOPE=foundation

run_capture "$TF" plan network
check          "a torn-down network skips green"      "0" "$STATUS"
check_contains "…saying it is torn down"              "is torn down" "$OUTPUT"
check_contains "…naming the marker and its value"     "/bgd/platform/deployed_scope = foundation" "$OUTPUT"
check_contains "…and how to bring it back"            "make rebuild" "$OUTPUT"

run_capture "$TF" plan prod
check "a torn-down prod skips green too" "0" "$STATUS"

# The message must NOT blame DEPLOY_SCOPE, which is fine. An operator reading
# "outside DEPLOY_SCOPE=all" would go looking for a bug in scope handling.
check "the clamp does not blame the scope" \
  "" \
  "$(printf '%s' "$OUTPUT" | grep -o 'outside DEPLOY_SCOPE' || true)"

# foundation is exempt: it is the layer that CREATES the marker, so on a fresh
# account the parameter does not exist when it is first planned. Plan §D6.
#
# Exercised through `apply` rather than `plan`, deliberately. An exempt layer
# proceeds PAST the gates, and `plan foundation` would then run terraform — the
# one thing this suite must not do. `apply` stops at the missing saved-plan
# check, which sits immediately after the gates and before any terraform call,
# so the exemption is proved behaviourally and nothing is planned.
export FAKE_SSM_DEPLOYED_SCOPE=""
run_capture "$TF" apply foundation
check          "foundation never reads the marker" "1" "$STATUS"
check_contains "…it stops at the missing plan file, not at the marker" "no saved plan" "$OUTPUT"

# A marker that cannot be read is fatal for every layer above foundation. A gate
# that fails open is not a gate. Plan §D6.
export FAKE_SSM_DEPLOYED_SCOPE=""
run_capture "$TF" plan staging
check          "an unreadable marker is fatal above foundation" "1" "$STATUS"
check_contains "…and says which layer creates it" "apply the foundation layer" "$OUTPUT"

# --- DEPLOY_SCOPE itself, unchanged by this phase ----------------------------
#
# Phase 7's matrix, re-run against the clamped script. The marker is `all`
# throughout, so anything that skips here skips because of DEPLOY_SCOPE.

export FAKE_SSM_DEPLOYED_SCOPE=all

export DEPLOY_SCOPE=network
run_capture "$TF" plan staging
check          "DEPLOY_SCOPE=network still skips staging" "0" "$STATUS"
check_contains "…blaming the scope, not the marker" "outside DEPLOY_SCOPE=network" "$OUTPUT"

run_capture "$TF" plan prod
check "DEPLOY_SCOPE=network still skips prod" "0" "$STATUS"

unset DEPLOY_SCOPE
run_capture "$TF" plan network
check          "an unset DEPLOY_SCOPE is still fatal" "1" "$STATUS"
check_contains "…naming the override the action must pass" "EnvironmentVariables override" "$OUTPUT"

export DEPLOY_SCOPE=sideways
run_capture "$TF" plan network
check          "an unrecognised DEPLOY_SCOPE is still fatal" "1" "$STATUS"
check_contains "…listing the four it accepts" "expected one of foundation, network, staging, all" "$OUTPUT"

export DEPLOY_SCOPE=all
run_capture "$TF" plan nonsense
check          "an unknown layer is still fatal" "1" "$STATUS"
check_contains "…and named"  "unknown layer: nonsense" "$OUTPUT"

report
```

- [ ] **Step 2: Run and watch it fail**

```bash
chmod +x scripts/tests/test_pipeline_scope.sh
bash scripts/tests/test_pipeline_scope.sh
```

Expected: FAIL — the clamp checks red because `plan network` proceeds past the gate and reaches `terraform`. The `DEPLOY_SCOPE` checks at the bottom already pass, which is the point: they are Phase 7's behaviour, asserted before it is touched.

- [ ] **Step 3: Delete the local rank functions**

In `scripts/pipeline-terraform.sh`, delete the `scope_rank()` and `layer_rank()` definitions and replace the comment above them with:

```bash
# scope_rank and layer_rank moved to lib/common.sh in Phase 10, as
# platform_scope_rank and platform_layer_rank — rebuild.sh, teardown.sh and
# this script all rank the same four names, and three copies of a rank table
# that decides whether production is applied is three chances to disagree.
#
# The names gained a platform_ prefix rather than moving as-is: pipeline-deploy.sh
# defines a scope_rank of its own over build/staging/all, and bash redefines a
# function silently. Plan §F7.
#
# Cumulative scope: the value names the LAST layer a run applies, so a rank
# comparison is the whole rule. An unrecognised scope ranks 0, which is below
# every layer, so nothing runs — and it is rejected by name below rather than
# being allowed to behave like a silent `foundation`. Plan §D3.
```

Then replace every `scope_rank` call with `platform_scope_rank` and every `layer_rank` call with `platform_layer_rank`.

- [ ] **Step 4: Add the clamp**

In `scripts/pipeline-terraform.sh`, immediately after the existing out-of-scope skip block and before `case "$mode" in`, insert:

```bash
# ---------------------------------------------------------------------------
# Gate 2: the platform marker
# ---------------------------------------------------------------------------
#
# The scope above says how far this RUN wants to go. The marker says how far the
# platform actually is. A merge to main after `make teardown` must not recreate
# a NAT gateway, an ALB and two Fargate tasks because somebody fixed a typo in
# a README under infra/.
#
# So the effective scope is the smaller of the two, and a layer above it SKIPS
# — green, never failed. Since Phase 9 a failed run emails you and counts in
# change-failure-rate, and a run that correctly declined to deploy into a
# torn-down account must not look like a bad deployment. Plan §D5.
#
# foundation is exempt and must be: it is the layer that CREATES the marker, so
# on a fresh account the parameter does not exist at the moment it is first
# planned. It ranks 1 and every valid marker value ranks at least 1, so the
# clamp could never exclude it anyway — skipping the READ is what makes the
# bootstrap case work. Plan §D6.
if [[ "$layer" != "foundation" ]]; then
  deployed="$(read_deployed_scope)"

  if (($(platform_layer_rank "$layer") > $(platform_scope_rank "$deployed"))); then
    info "$layer is torn down ($DEPLOYED_SCOPE_PARAM = $deployed) — nothing to do"
    info "run \`make rebuild\` to bring it back"
    if [[ "$mode" == "plan" ]]; then
      write_vars "skipped" "Skipped. $layer is torn down ($DEPLOYED_SCOPE_PARAM = $deployed); run make rebuild." "$(build_url)"
    fi
    exit 0
  fi
fi
```

- [ ] **Step 5: Run and watch it pass**

```bash
make test-scripts
```

Expected: `test_pipeline_scope.sh: 19 checks, 0 failed`, `✓ 2 test files passed`.

- [ ] **Step 6: Prove the plan-vars file is still written on the new skip**

```bash
DEPLOY_SCOPE=all FAKE_SSM_DEPLOYED_SCOPE=foundation \
  PATH="scripts/tests/fake-bin:$PATH" ./scripts/pipeline-terraform.sh plan prod
cat plan-vars.env
rm -f plan-vars.env
```

Expected: `PLAN_STATUS=skipped` and a `PLAN_SUMMARY` naming the marker. This matters because `pipelines/infra-plan.yml` sources the file; a skip that wrote nothing would turn a correct skip into a red stage.

- [ ] **Step 7: Commit**

```bash
git add scripts/pipeline-terraform.sh scripts/tests/test_pipeline_scope.sh
git commit -m "feat(phase10): the infra pipeline clamps its scope to the platform marker"
```

---

### Task 5: `pipeline-deploy.sh` clamps to the marker

The same gate, over a different vocabulary. `APP_SCOPE` ranks `build`/`staging`/`all` and environments rank `staging`=2, `prod`=3, so the marker has to be mapped onto that scale rather than compared against it directly.

**Files:**
- Modify: `scripts/pipeline-deploy.sh` (a mapping function and the clamp)
- Modify: `scripts/tests/test_pipeline_scope.sh`

**Interfaces:**
- Consumes: `read_deployed_scope`, `DEPLOYED_SCOPE_PARAM` from Task 2.
- Produces: `marker_env_rank <marker>` → the deepest `env_rank` the marker permits.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/tests/test_pipeline_scope.sh`, before `report`:

```bash
# --- the same clamp, over APP_SCOPE's vocabulary -----------------------------

DEPLOY="$ROOT/scripts/pipeline-deploy.sh"

export APP_SCOPE=all
export IMAGE_TAG=1.0.0-abc1234
export FAKE_SSM_DEPLOYED_SCOPE=network

run_capture "$DEPLOY" deploy staging
check          "a torn-down staging skips green"  "0" "$STATUS"
check_contains "…saying it is torn down"          "is torn down" "$OUTPUT"
check_contains "…and how to bring it back"        "make rebuild" "$OUTPUT"

# The skip must still write deploy-vars.env, or pipelines/app-deploy.yml fails
# sourcing a file that is not there — turning a correct skip into a red stage.
check "the skip still writes the deploy vars file" "0" \
  "$(if [[ -f "$ROOT/deploy-vars.env" ]]; then echo 0; else echo 1; fi)"
rm -f "$ROOT/deploy-vars.env"

export FAKE_SSM_DEPLOYED_SCOPE=staging
run_capture "$DEPLOY" plan prod
check          "staging deployed but prod torn down skips prod" "0" "$STATUS"
check_contains "…blaming the marker"  "is torn down" "$OUTPUT"
rm -f "$ROOT/plan-vars.env"

# …and with the same marker, staging is IN scope, so the run proceeds past the
# gate. Exercised through `apply` for the reason the foundation case above is:
# an in-scope `deploy` would run terraform, and `apply` stops at the missing
# saved-plan check immediately after the gates.
run_capture "$DEPLOY" apply staging
check          "staging is not skipped when the marker says staging" "" \
  "$(printf '%s' "$OUTPUT" | grep -o 'is torn down' || true)"
check_contains "…it stops at the missing plan file instead" "no saved plan" "$OUTPUT"

export FAKE_SSM_DEPLOYED_SCOPE=""
run_capture "$DEPLOY" deploy staging
check          "an unreadable marker is fatal here too" "1" "$STATUS"
check_contains "…and says which layer creates it" "apply the foundation layer" "$OUTPUT"

# APP_SCOPE itself, unchanged: Phase 8's behaviour asserted against the clamped
# script, with the marker at `all` so nothing skips because of it.
export FAKE_SSM_DEPLOYED_SCOPE=all
export APP_SCOPE=build
run_capture "$DEPLOY" deploy staging
check          "APP_SCOPE=build still skips staging" "0" "$STATUS"
check_contains "…blaming the scope, not the marker" "outside APP_SCOPE=build" "$OUTPUT"
rm -f "$ROOT/deploy-vars.env"

export APP_SCOPE=staging
run_capture "$DEPLOY" plan prod
check          "APP_SCOPE=staging still skips prod" "0" "$STATUS"
check_contains "…blaming the scope"  "outside APP_SCOPE=staging" "$OUTPUT"
rm -f "$ROOT/plan-vars.env"

unset APP_SCOPE
run_capture "$DEPLOY" deploy staging
check "an unset APP_SCOPE is still fatal" "1" "$STATUS"

export APP_SCOPE=all
run_capture "$DEPLOY" deploy nonsense
check          "an unknown environment is still fatal" "1" "$STATUS"
check_contains "…and named" "unknown environment: nonsense" "$OUTPUT"
```

- [ ] **Step 2: Run and watch it fail**

```bash
bash scripts/tests/test_pipeline_scope.sh
```

Expected: FAIL on the clamp checks; the `APP_SCOPE` checks at the bottom pass already.

- [ ] **Step 3: Add the mapping and the clamp**

In `scripts/pipeline-deploy.sh`, after `env_rank()`, add:

```bash
# The marker's four values mapped onto env_rank's scale.
#
# The marker speaks DEPLOY_SCOPE's vocabulary — foundation, network, staging,
# all — and this script ranks environments, not layers. `foundation` and
# `network` both mean "neither environment exists", so both map below staging.
#
# Deliberately a mapping rather than a shared rank table: the two scales
# measure different things and collapsing them would put `build` and `network`
# on the same number, which is true of nothing. Plan §D5.
marker_env_rank() {
  case "$1" in
    foundation | network) echo 1 ;;
    staging) echo 2 ;;
    all) echo 3 ;;
    *) echo 0 ;;
  esac
}
```

Then, immediately after the existing out-of-scope skip block and before the `deploy` section, insert:

```bash
# ---------------------------------------------------------------------------
# Gate 2: the platform marker
# ---------------------------------------------------------------------------
#
# APP_SCOPE says how far this run wants to go; the marker says how far the
# platform actually is. Deploying an image into an environment `make teardown`
# destroyed fails at the remote-state read — which since Phase 9 also sends an
# email and counts in change-failure-rate. Skipping green instead costs a line
# in the console and tells the truth. Plan §D5.
#
# Unlike pipeline-terraform.sh there is no exemption: both environments are
# above the marker's floor, and the Build stage — which legitimately runs while
# the platform is down, and whose image is waiting when it comes back — is a
# different script that never reaches here.
deployed="$(read_deployed_scope)"

if (($(env_rank "$env_name") > $(marker_env_rank "$deployed"))); then
  info "$env_name is torn down ($DEPLOYED_SCOPE_PARAM = $deployed) — nothing to do"
  info "run \`make rebuild\` to bring it back"
  case "$mode" in
    deploy) write_deploy_vars "" "" ;;
    plan) write_vars "skipped" "Skipped. $env_name is torn down ($DEPLOYED_SCOPE_PARAM = $deployed); run make rebuild." "$(build_url)" ;;
  esac
  exit 0
fi
```

- [ ] **Step 4: Run and watch it pass**

```bash
make test-scripts
```

Expected: `test_pipeline_scope.sh: 36 checks, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/pipeline-deploy.sh scripts/tests/test_pipeline_scope.sh
git commit -m "feat(phase10): the app pipeline clamps its scope to the platform marker"
```

---

### Task 6: `teardown.sh`, rewritten

**Files:**
- Modify: `scripts/teardown.sh` (rewritten in full)
- Create: `scripts/tests/test_operator_scripts.sh`
- Modify: `makefile` (the `teardown` target's help text)

**Interfaces:**
- Consumes: `layer_dir`, `write_deployed_scope`, `platform_scope_rank` from Tasks 1 and 2.
- Produces: `make teardown SCOPE=<prod|staging|network>`; the marker values Task 8's rebuild raises again.

- [ ] **Step 1: Write the failing tests**

Create `scripts/tests/test_operator_scripts.sh`:

```bash
#!/usr/bin/env bash
#
# The three operator scripts' guards: scope parsing, the confirmation, the
# order in which the marker is written, and the preconditions.
#
# Nothing here runs a destroy or an apply — every case exits at a guard. What
# an offline suite can prove is that the guards are right; that a real cycle
# works is the runbook's job, and is why the runbook exists. Plan §D1.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

source "$HERE/lib.sh"

export PATH="$HERE/fake-bin:$PATH"
export FAKE_SSM_DEPLOYED_SCOPE=all

TEARDOWN="$ROOT/scripts/teardown.sh"

# --- scope parsing -----------------------------------------------------------

run_capture env SCOPE=sideways "$TEARDOWN"
check          "an unrecognised SCOPE is fatal"  "1" "$STATUS"
check_contains "…listing the three it accepts"   "expected one of prod, staging, network" "$OUTPUT"

# There is no value that reaches foundation. The five-layer split exists so the
# certificate, the images, the artifact history, the pipelines and the
# CodeConnections authorisation survive a routine command. Plan §D16.
run_capture env SCOPE=foundation "$TEARDOWN"
check          "SCOPE=foundation is refused"     "1" "$STATUS"
check_contains "…as an unrecognised value"       "expected one of prod, staging, network" "$OUTPUT"

run_capture env SCOPE=bootstrap "$TEARDOWN"
check "SCOPE=bootstrap is refused" "1" "$STATUS"

# --- the confirmation --------------------------------------------------------

# The marker assertions name the whole line, not just the value: "network"
# appears in the survivor sentence too, so a bare substring would pass on the
# wrong half of the output.
run_capture env SCOPE=prod BGD_TEARDOWN_DRY_RUN=1 "$TEARDOWN"
check          "a dry run exits 0 without destroying"     "0" "$STATUS"
check_contains "…listing the layer it would destroy"      "prod" "$OUTPUT"
check_contains "…naming what survives"                    "foundation and bootstrap are never destroyed" "$OUTPUT"
check_contains "…and the marker value it would write"     "/bgd/platform/deployed_scope = staging" "$OUTPUT"

run_capture env SCOPE=staging BGD_TEARDOWN_DRY_RUN=1 "$TEARDOWN"
check_contains "SCOPE=staging destroys prod first"      "prod" "$OUTPUT"
check_contains "…then staging"                          "staging" "$OUTPUT"
check_contains "…and would leave the marker at network" "/bgd/platform/deployed_scope = network" "$OUTPUT"

run_capture env SCOPE=network BGD_TEARDOWN_DRY_RUN=1 "$TEARDOWN"
check_contains "the default scope would leave the marker at foundation" "/bgd/platform/deployed_scope = foundation" "$OUTPUT"

# A confirmation that is not the word `destroy` aborts, and aborts BEFORE the
# marker is written — otherwise declining the prompt would still tell both
# pipelines the platform is down.
FAKE_AWS_LOG="$(mktemp)"
export FAKE_AWS_LOG
run_capture env SCOPE=prod "$TEARDOWN" <<<"yes"
check "a confirmation other than the word destroy aborts" "1" "$STATUS"
check "…and writes no marker" "" "$(grep -o put-parameter "$FAKE_AWS_LOG" || true)"
rm -f "$FAKE_AWS_LOG"
unset FAKE_AWS_LOG

report
```

- [ ] **Step 2: Run and watch it fail**

```bash
chmod +x scripts/tests/test_operator_scripts.sh
bash scripts/tests/test_operator_scripts.sh
```

Expected: FAIL — the current script takes no `SCOPE`, so it proceeds toward a real destroy. **Run this with no AWS session** so a mistake cannot reach the account; the `terraform init` in `tf.sh` will fail on credentials, which is a failing test rather than a destroyed environment.

- [ ] **Step 3: Rewrite the script**

Replace `scripts/teardown.sh` in full:

```bash
#!/usr/bin/env bash
#
# Ordered teardown: prod, then staging, then network. foundation and bootstrap
# are never touched — that is the whole reason the five-layer split exists
# (roadmap §1), and there is deliberately no SCOPE value and no flag that
# reaches either of them (plan §D16).
#
#   make teardown                  destroy all three
#   make teardown SCOPE=staging    destroy prod and staging, leave the network
#   make teardown SCOPE=prod       destroy prod only
#
# Order is not cosmetic. Destroying network first would strand the ALBs and ECS
# services that depend on its subnets, and the destroy would fail part-way with
# a dependency violation, leaving the expensive half running.
#
# ---------------------------------------------------------------------------
# The marker is written BEFORE the first destroy
# ---------------------------------------------------------------------------
#
# /bgd/platform/deployed_scope records how deep the platform is applied, and
# both pipeline drivers clamp their scope to it. Writing it first is what makes
# the rule "the marker never overstates what exists" hold at both ends:
#
#   - writing it afterwards leaves a window, the whole length of the destroy,
#     in which a merge to main lands, reads `all`, and starts applying into an
#     account being dismantled underneath it
#   - a teardown that dies half-way would never write it at all, leaving both
#     pipelines believing production is up when prod is what was destroyed first
#
# The direction this accepts — the marker understating, saying `foundation`
# while a half-destroyed staging still exists — costs a skipped stage and a line
# in the console. The other direction costs a deployment into an account that
# cannot serve it. Plan §D3.
#
# Environment variables:
#   SCOPE                  prod | staging | network   (default: network)
#   BGD_ASSUME_YES=1       skip the confirmation, for the runbook and for a
#                          re-run after a partial failure
#   BGD_TEARDOWN_DRY_RUN=1 print the plan and exit; destroy nothing, write
#                          nothing

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform
require_cmd aws

ROOT="$(repo_root)"

SCOPE="${SCOPE:-network}"

# Cumulative, naming where the run STOPS — the rule DEPLOY_SCOPE and APP_SCOPE
# already use, pointed the way this script travels. An unrecognised value is
# refused by name rather than falling back to the safe end: a SCOPE=staginng
# typo that silently tore down everything would be a bad surprise, and one that
# silently tore down nothing while printing success would be worse. Plan §D7.
case "$SCOPE" in
  prod) TEARDOWN_ORDER=(prod) SURVIVING_SCOPE=staging ;;
  staging) TEARDOWN_ORDER=(prod staging) SURVIVING_SCOPE=network ;;
  network) TEARDOWN_ORDER=(prod staging network) SURVIVING_SCOPE=foundation ;;
  *) die "SCOPE is '$SCOPE'; expected one of prod, staging, network" ;;
esac

# ---------------------------------------------------------------------------
# What is about to happen, in full, before anything happens
# ---------------------------------------------------------------------------

echo
info "teardown scope: $SCOPE"
echo
printf '  will destroy, in order:\n'
for layer in "${TEARDOWN_ORDER[@]}"; do
  printf '    %s\n' "$layer"
done
printf '\n  will survive: foundation and bootstrap are never destroyed'
case "$SCOPE" in
  prod) printf ', and so are network and staging\n' ;;
  staging) printf ', and so is network\n' ;;
  *) printf '\n' ;;
esac
printf '  will record:  %s = %s\n\n' "$DEPLOYED_SCOPE_PARAM" "$SURVIVING_SCOPE"

if [[ -n "${BGD_TEARDOWN_DRY_RUN:-}" ]]; then
  ok "dry run — nothing was destroyed and nothing was written"
  exit 0
fi

# One typed confirmation, not three Terraform prompts. The first cut relied on
# terraform's own `yes` prompt per layer and called that the safety; three
# identical prompts in a row is how the third one gets answered by reflex. The
# word rather than a letter for the same reason. Plan §D8.
if [[ -z "${BGD_ASSUME_YES:-}" ]]; then
  printf '  type "destroy" to continue: '
  read -r reply
  [[ "$reply" == "destroy" ]] || die "aborted — nothing was destroyed and no marker was written"
fi

# ---------------------------------------------------------------------------
# The marker, then the destroys
# ---------------------------------------------------------------------------

write_deployed_scope "$SURVIVING_SCOPE"

declare -a TIMINGS=()

for layer in "${TEARDOWN_ORDER[@]}"; do
  dir="$(layer_dir "$layer")"

  # A layer with no .tf files at all is skipped and SAYS SO. Silence would be
  # the dangerous behaviour: the failure mode this guards against is the
  # production layer being quietly passed over and left running at ~$40/month.
  if [[ ! -d "$dir" ]] || ! compgen -G "$dir/*.tf" >/dev/null; then
    info "$layer — no .tf files, skipping"
    TIMINGS+=("$layer|skipped (no .tf files)|0")
    continue
  fi

  # A layer whose state holds nothing is skipped too, and this is the common
  # case on a re-run after a partial failure. `terraform destroy` against empty
  # state succeeds and spends half a minute of init doing nothing.
  #
  # The init is -backend=false-free on purpose: reading state needs the real
  # backend, so this goes through tf.sh's plan/apply init path.
  terraform -chdir="$dir" init -input=false >/dev/null 2>&1 || true
  if [[ -z "$(terraform -chdir="$dir" state list 2>/dev/null)" ]]; then
    info "$layer — state is empty, skipping"
    TIMINGS+=("$layer|skipped (already destroyed)|0")
    continue
  fi

  info "$layer — terraform destroy"
  started=$SECONDS

  # -auto-approve because the single typed confirmation above replaced the
  # per-layer prompts. -lock-timeout matches both pipeline drivers: without it
  # a destroy racing a pipeline apply fails instantly on the lock rather than
  # waiting for it.
  "$ROOT/scripts/tf.sh" destroy "$layer" -auto-approve -input=false -lock-timeout=5m ||
    die "destroy failed for $layer; later layers were not touched. The marker already reads $SURVIVING_SCOPE, so both pipelines will skip this layer — re-run once the cause is fixed."

  elapsed=$((SECONDS - started))
  TIMINGS+=("$layer|destroyed|$elapsed")
  ok "$layer destroyed in $((elapsed / 60))m$((elapsed % 60))s"
done

# ---------------------------------------------------------------------------
# What it cost in time — measured rather than remembered
# ---------------------------------------------------------------------------

echo
printf '  %-12s %-28s %s\n' "layer" "outcome" "time"
printf '  %-12s %-28s %s\n' "-----" "-------" "----"
total=0
for row in "${TIMINGS[@]}"; do
  IFS='|' read -r layer outcome elapsed <<<"$row"
  printf '  %-12s %-28s %dm%02ds\n' "$layer" "$outcome" "$((elapsed / 60))" "$((elapsed % 60))"
  total=$((total + elapsed))
done
printf '  %-12s %-28s %dm%02ds\n\n' "total" "" "$((total / 60))" "$((total % 60))"

ok "teardown complete — $DEPLOYED_SCOPE_PARAM records $SURVIVING_SCOPE"
info "run \`make verify-idle\` to confirm nothing billable survived"
```

- [ ] **Step 4: Run and watch it pass**

```bash
make test-scripts
```

Expected: `test_operator_scripts.sh: 15 checks, 0 failed`.

- [ ] **Step 5: Update the makefile's help text**

Replace the `teardown` target:

```make
# SCOPE names where the run stops: prod destroys prod only, staging destroys
# prod and staging, network (the default) destroys all three. foundation and
# bootstrap are never reachable — see the plan's D16.
.PHONY: teardown
teardown: ## Destroy prod, staging and network; SCOPE=prod|staging|network (needs an AWS session)
	@./scripts/teardown.sh
```

- [ ] **Step 6: Commit**

```bash
git add scripts/teardown.sh scripts/tests/test_operator_scripts.sh makefile
git commit -m "feat(phase10): teardown takes a scope, confirms once, and lowers the marker first"
```

---

### Task 7: `verify-idle.sh`

**Files:**
- Create: `scripts/verify-idle.sh`
- Modify: `scripts/tests/test_operator_scripts.sh`
- Modify: `makefile`

**Interfaces:**
- Consumes: nothing from earlier tasks except `lib/common.sh`'s reporting helpers.
- Produces: `make verify-idle SCOPE=<prod|staging|network>`; exit 0 when nothing billable survives.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/tests/test_operator_scripts.sh`, before `report`:

```bash
# --- verify-idle -------------------------------------------------------------

IDLE="$ROOT/scripts/verify-idle.sh"

run_capture env SCOPE=sideways "$IDLE"
check          "an unrecognised SCOPE is fatal"  "1" "$STATUS"
check_contains "…listing the three it accepts"   "expected one of prod, staging, network" "$OUTPUT"

# The script must never read a state file: state is exactly what is wrong in
# the three cases it exists for — a resource created by hand, a drifted state,
# and a destroy that failed part-way. Plan §D9.
check "verify-idle opens no state file" "" \
  "$(grep -n 'terraform_remote_state\|terraform output\|state list\|\.tfstate' "$IDLE" || true)"

check "verify-idle requires the AWS CLI" "0" \
  "$(if grep -q 'require_cmd aws' "$IDLE"; then echo 0; else echo 1; fi)"

# The four ephemeral services are the ones in which this project owns nothing
# that survives a full teardown, which is what makes the rule expressible
# without an allowlist of the fourteen kinds of thing that do. Plan §D9.
for service in ec2 elasticloadbalancing ecs dynamodb; do
  check "the sweep covers $service" "0" \
    "$(if grep -q "$service" "$IDLE"; then echo 0; else echo 1; fi)"
done
```

- [ ] **Step 2: Run and watch it fail**

```bash
bash scripts/tests/test_operator_scripts.sh
```

Expected: FAIL — `scripts/verify-idle.sh: No such file or directory`.

- [ ] **Step 3: Write the script**

Create `scripts/verify-idle.sh`:

```bash
#!/usr/bin/env bash
#
# Is this account actually idle?
#
#   make verify-idle                  after a full teardown
#   make verify-idle SCOPE=prod       after `make teardown SCOPE=prod`
#
# A clean `terraform destroy` on three layers is not the same claim. The three
# cases where they differ are the reason this exists: a resource created by hand
# and never in state, a state file that drifted, and a destroy that failed
# part-way and left the expensive half running.
#
# So NOTHING here reads a state file. Every check goes to AWS directly, because
# state is precisely what is wrong in the cases this is for. Plan §D9.
#
# Five authoritative checks, each on a shape that bills while idle, plus one
# tagged sweep as a catch-all. The sweep is a WARNING and not a verdict:
# resourcegroupstaggingapi is an index and can still list a resource deleted a
# minute ago — which is the exact moment this runs. Plan §F2.
#
# Exit 0 means nothing billable survived in scope.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd aws
require_cmd jq

REGION="${AWS_REGION:-us-east-1}"
PROJECT="${BGD_PROJECT_NAME:-bgd}"
PREFIX="${PROJECT}-${REGION}-"

SCOPE="${SCOPE:-network}"

# Which environments were destroyed, and whether the network was. The
# `environment` tag separates staging from prod; it CANNOT separate network from
# foundation, because both tag environment = "shared" — so the network checks
# key on the SERVICE instead. Plan §F1.
case "$SCOPE" in
  prod) ENVIRONMENTS=(prod) CHECK_NETWORK=no ;;
  staging) ENVIRONMENTS=(prod staging) CHECK_NETWORK=no ;;
  network) ENVIRONMENTS=(prod staging) CHECK_NETWORK=yes ;;
  *) die "SCOPE is '$SCOPE'; expected one of prod, staging, network" ;;
esac

FAILURES=0
WARNINGS=0

row() { printf '  %-34s ' "$1"; }

echo
info "verify-idle — scope $SCOPE, prefix ${PREFIX}"
echo

# ---------------------------------------------------------------------------
# ECS services, per environment
# ---------------------------------------------------------------------------
#
# desiredCount rather than existence: a service scaled to zero bills nothing,
# and reporting it as a failure would send someone hunting for a cost that is
# not there. A cluster with no service is free.

for env in "${ENVIRONMENTS[@]}"; do
  row "ecs services ($env)"
  cluster="${PREFIX}${env}-cluster"

  running="$(aws ecs list-services --region "$REGION" --cluster "$cluster" \
    --query 'serviceArns' --output text 2>/dev/null || true)"

  if [[ -z "$running" || "$running" == "None" ]]; then
    mark_ok
  else
    count="$(aws ecs describe-services --region "$REGION" --cluster "$cluster" \
      --services $running --query 'length(services[?desiredCount>`0`])' --output text 2>/dev/null || echo 0)"
    if [[ "$count" == "0" ]]; then
      mark_ok
    else
      FAILURES=$((FAILURES + 1))
      mark_fail "$count service(s) still running in $cluster"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Load balancers, per environment
# ---------------------------------------------------------------------------
#
# An ALB bills by the hour whether or not anything is behind it, and is the
# second-largest idle cost after the NAT gateway. describe-load-balancers has no
# tag filter, so the name prefix is the discriminator — the same convention
# every other name in this project derives from.

for env in "${ENVIRONMENTS[@]}"; do
  row "load balancers ($env)"
  found="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?starts_with(LoadBalancerName, '${PREFIX}${env}-')].LoadBalancerName" \
    --output text 2>/dev/null || true)"

  if [[ -z "$found" || "$found" == "None" ]]; then
    mark_ok
  else
    FAILURES=$((FAILURES + 1))
    mark_fail "still up: $found"
  fi
done

# ---------------------------------------------------------------------------
# DynamoDB tables, per environment
# ---------------------------------------------------------------------------
#
# On-demand tables bill nothing while idle, so this is not a cost check — it is
# a completeness check. A surviving table means the destroy did not finish, and
# the next rebuild will fail creating a table that already exists.

for env in "${ENVIRONMENTS[@]}"; do
  row "dynamodb tables ($env)"
  found="$(aws dynamodb list-tables --region "$REGION" \
    --query "TableNames[?starts_with(@, '${PREFIX}${env}-')]" --output text 2>/dev/null || true)"

  if [[ -z "$found" || "$found" == "None" ]]; then
    mark_ok
  else
    FAILURES=$((FAILURES + 1))
    mark_fail "still present: $found"
  fi
done

# ---------------------------------------------------------------------------
# The network, only on a full teardown
# ---------------------------------------------------------------------------

if [[ "$CHECK_NETWORK" == "yes" ]]; then
  # The single largest idle cost in the project, and the reason the network
  # layer was split out of foundation at all (roadmap §1).
  #
  # `deleting` is a warning rather than a failure: deletion is asynchronous and
  # billing stops at deletion, but reporting it as a clean pass would hide that
  # the account is not yet in its final state — which matters if the next thing
  # you do is a rebuild. Plan §F8.
  row "nat gateways"
  states="$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=tag:projectName,Values=${PROJECT}" \
    --query 'NatGateways[].State' --output text 2>/dev/null || true)"

  live="$(printf '%s\n' $states | grep -c -E '^(pending|available)$' || true)"
  deleting="$(printf '%s\n' $states | grep -c -E '^deleting$' || true)"

  if ((live > 0)); then
    FAILURES=$((FAILURES + 1))
    mark_fail "$live still billing"
  elif ((deleting > 0)); then
    WARNINGS=$((WARNINGS + 1))
    mark_warn "$deleting still deleting — re-run in a few minutes"
  else
    mark_ok
  fi

  # An Elastic IP bills whether or not it is associated — AWS has charged for
  # in-use addresses since 1 February 2024 and for idle ones for far longer.
  # So: any address carrying the project tag is a failure.
  row "elastic ips"
  found="$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:projectName,Values=${PROJECT}" \
    --query 'Addresses[].PublicIp' --output text 2>/dev/null || true)"

  if [[ -z "$found" || "$found" == "None" ]]; then
    mark_ok
  else
    FAILURES=$((FAILURES + 1))
    mark_fail "still allocated: $found"
  fi
fi

# ---------------------------------------------------------------------------
# The catch-all
# ---------------------------------------------------------------------------
#
# Everything above names a shape somebody thought of. This names the ones
# nobody did.
#
# The four services below are exactly those in which this project owns nothing
# that survives a full teardown, which is what makes the rule expressible
# without an allowlist of the fourteen kinds of thing that DO survive — the
# zone, the certificate, both repositories, both buckets, the topic, the
# connection, both pipelines, eight CodeBuild projects, the roles, three
# parameters, the collector, its log group and the dashboard.
#
# A warning, never a verdict: the tagging API is an index and lags deletion by
# minutes. Plan §F2.

row "tagged sweep (ec2/elb/ecs/ddb)"
tagged="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=projectName,Values=${PROJECT}" \
  --resource-type-filters ec2 elasticloadbalancing ecs dynamodb \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)"

if [[ -z "$tagged" || "$tagged" == "None" ]]; then
  mark_ok
else
  count="$(printf '%s\n' $tagged | wc -l | tr -d ' ')"
  WARNINGS=$((WARNINGS + 1))
  mark_warn "$count resource(s) still indexed (the index lags deletion by minutes)"
  for arn in $tagged; do
    dim "      $arn"
  done
fi

# ---------------------------------------------------------------------------

echo
if ((FAILURES > 0)); then
  die "$FAILURES check(s) failed — something is still billing"
fi

if ((WARNINGS > 0)); then
  warn "$WARNINGS warning(s) — nothing is billing, but the account is not yet settled"
fi

ok "nothing billable survives in scope $SCOPE"
```

- [ ] **Step 4: Run and watch it pass**

```bash
chmod +x scripts/verify-idle.sh
make test-scripts
```

Expected: `test_operator_scripts.sh: 23 checks, 0 failed`.

- [ ] **Step 5: Add the makefile target**

In the Phase 10 section:

```make
# Deliberately separate from teardown, and re-runnable. Folded in, "the destroy
# failed" and "the destroy succeeded but something survived" would be the same
# red exit from the same command — and there would be no way to check an account
# nobody tore down today. Plan §D9.
.PHONY: verify-idle
verify-idle: ## Prove nothing billable survives; SCOPE=prod|staging|network (needs an AWS session)
	@./scripts/verify-idle.sh
```

- [ ] **Step 6: Commit**

```bash
git add scripts/verify-idle.sh scripts/tests/test_operator_scripts.sh makefile
git commit -m "feat(phase10): verify-idle proves the account is idle without trusting state"
```

---

### Task 8: `rebuild.sh`

**Files:**
- Create: `scripts/rebuild.sh`
- Modify: `scripts/tests/test_operator_scripts.sh`
- Modify: `makefile`

**Interfaces:**
- Consumes: `layer_dir`, `write_deployed_scope`, `read_deployed_scope` from Tasks 1 and 2; `scripts/smoke.sh <env>` from Phase 5.
- Produces: `make rebuild SCOPE=<network|staging|prod>`.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/tests/test_operator_scripts.sh`, before `report`:

```bash
# --- rebuild -----------------------------------------------------------------

REBUILD="$ROOT/scripts/rebuild.sh"

run_capture env SCOPE=sideways "$REBUILD"
check          "an unrecognised SCOPE is fatal"  "1" "$STATUS"
check_contains "…listing the three it accepts"   "expected one of network, staging, prod" "$OUTPUT"

# foundation is not a rebuild target: it survived the teardown, by construction.
run_capture env SCOPE=foundation "$REBUILD"
check "SCOPE=foundation is refused" "1" "$STATUS"

# Every case below runs with BGD_REBUILD_DRY_RUN=1, which stops AFTER the
# preconditions and before the first apply. That is what lets the suite exercise
# all six preconditions without terraform ever being invoked — and it is why
# the flag stops where it does rather than before them.
export FAKE_SSM_IMAGE_TAG=1.0.0-abc1234

run_capture env SCOPE=network BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check          "a dry run exits 0"                     "0" "$STATUS"
check_contains "…listing what it would apply"          "network" "$OUTPUT"
check_contains "…and the marker value it would record" "/bgd/platform/deployed_scope = network" "$OUTPUT"
check_contains "…having actually checked something"    "preconditions pass" "$OUTPUT"

run_capture env SCOPE=prod BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check_contains "the default applies network first"  "network" "$OUTPUT"
check_contains "…then staging"                      "staging" "$OUTPUT"
check_contains "…then prod"                         "prod"    "$OUTPUT"
check_contains "…finishing at the marker value all" "/bgd/platform/deployed_scope = all" "$OUTPUT"

# The account check is first, because a rebuild into the wrong account is not
# recoverable by re-running it. Plan §D10.
export FAKE_ACCOUNT_ID=111122223333
run_capture env SCOPE=network BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check          "a wrong account is fatal"     "1" "$STATUS"
check_contains "…naming both account numbers" "111122223333" "$OUTPUT"
unset FAKE_ACCOUNT_ID

export FAKE_S3_MISSING=1
run_capture env SCOPE=network BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check          "an unreachable state bucket is fatal" "1" "$STATUS"
check_contains "…and names it"  "bgd-us-east-1-tfstate" "$OUTPUT"
unset FAKE_S3_MISSING

# An unset image tag is caught before the NAT gateway exists, not at the
# staging layer after it does. Plan §D10.
export FAKE_SSM_IMAGE_TAG=unset
run_capture env SCOPE=staging BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check          "an unset image tag is fatal" "1" "$STATUS"
check_contains "…and says how to set it"     "make seed-ecr" "$OUTPUT"
export FAKE_SSM_IMAGE_TAG=1.0.0-abc1234

# The check that moves the failure from after the NAT gateway to before it.
export FAKE_ECR_MISSING=1
run_capture env SCOPE=staging BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check          "a tag that is not in ECR is fatal"   "1" "$STATUS"
check_contains "…and says why it is caught here"     "after the network already exists and is billing" "$OUTPUT"
unset FAKE_ECR_MISSING

# SCOPE=network needs no image tag at all — there is no container in that layer,
# so an absent parameter must not stop a network-only rebuild.
export FAKE_SSM_IMAGE_TAG=""
run_capture env SCOPE=network BGD_REBUILD_DRY_RUN=1 "$REBUILD"
check "SCOPE=network needs no image tag" "0" "$STATUS"
unset FAKE_SSM_IMAGE_TAG
```

- [ ] **Step 2: Run and watch it fail**

```bash
bash scripts/tests/test_operator_scripts.sh
```

Expected: FAIL — `scripts/rebuild.sh: No such file or directory`.

- [ ] **Step 3: Write the script**

Create `scripts/rebuild.sh`:

```bash
#!/usr/bin/env bash
#
# The way back: network, then staging, then prod.
#
#   make rebuild                   all three, and smoke both environments
#   make rebuild SCOPE=staging     network and staging only
#   make rebuild SCOPE=network     the network only
#
# The mirror of teardown.sh, and the order is load-bearing in the same way:
# staging and prod both read network's outputs through remote state, so applying
# either against a network that does not exist is the failure the ordering
# exists to prevent.
#
# ---------------------------------------------------------------------------
# Two things this does that `make apply-network && make apply-staging` does not
# ---------------------------------------------------------------------------
#
#  1. It takes image_tag from SSM, exactly as scripts/pipeline-terraform.sh
#     does. Both environment layers declare image_tag with no default and the
#     local value lives in a gitignored terraform.tfvars — which is the right
#     input when you are CHANGING the tag, and the wrong one when you are
#     restoring what was deployed before a teardown. infra/foundation/ssm.tf
#     put the parameter in the surviving layer for this exact moment.
#
#     `make apply-staging` and `make apply-prod` are deliberately unchanged:
#     making tf.sh read SSM would take the by-hand override away. Plan §D10.
#
#  2. It raises /bgd/platform/deployed_scope, and it is the ONLY thing that
#     does. Written after each layer applies rather than once at the end, so a
#     rebuild that dies at prod leaves the marker reading `staging` — which is
#     true. The marker may lag reality downward; never upward. Plan §D3.
#
# Environment variables:
#   SCOPE                 network | staging | prod   (default: prod)
#   BGD_REBUILD_DRY_RUN=1 print the plan, run every precondition, and stop before
#                         the first apply. Answers "could I rebuild right now?"

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform
require_cmd aws

ROOT="$(repo_root)"
REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT="${AWS_ACCOUNT_ID:-590184028094}"
STATE_BUCKET="${BGD_STATE_BUCKET:-bgd-us-east-1-tfstate-${EXPECTED_ACCOUNT}}"

SCOPE="${SCOPE:-prod}"

# Cumulative, naming where the run stops, and refusing an unrecognised value by
# name for the same reason teardown does. foundation is not a value: it survived
# the teardown by construction, and this script never applies it. Plan §D7.
case "$SCOPE" in
  network) REBUILD_ORDER=(network) ;;
  staging) REBUILD_ORDER=(network staging) ;;
  prod) REBUILD_ORDER=(network staging prod) ;;
  *) die "SCOPE is '$SCOPE'; expected one of network, staging, prod" ;;
esac

# The marker value each layer's success earns. Derived from the layer rather
# than typed twice, so a reordering cannot leave the two disagreeing.
marker_after() {
  case "$1" in
    network) echo network ;;
    staging) echo staging ;;
    prod) echo all ;;
  esac
}

echo
info "rebuild scope: $SCOPE"
echo
printf '  will apply, in order:\n'
for layer in "${REBUILD_ORDER[@]}"; do
  printf '    %s\n' "$layer"
done
printf '\n  will record:  %s = %s\n\n' \
  "$DEPLOYED_SCOPE_PARAM" "$(marker_after "${REBUILD_ORDER[${#REBUILD_ORDER[@]} - 1]}")"

# ---------------------------------------------------------------------------
# Preconditions — all read-only, all before a dollar is spent
# ---------------------------------------------------------------------------
#
# The order is by what each one costs to get wrong. The account is first because
# a rebuild into the wrong one is not recoverable by re-running it; the image
# tags are last of the reads but still ahead of every apply, because discovering
# a wrong tag at the staging layer means the NAT gateway already exists and has
# started billing. Ten seconds of read-only calls moves that discovery to before
# the first resource. Plan §D10.

info "preconditions"

account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" ||
  die "no AWS session — run: aws sso login --profile ${AWS_PROFILE:-bootcamp-administrator-access}"
[[ "$account" == "$EXPECTED_ACCOUNT" ]] ||
  die "wrong account: session is $account, this project is $EXPECTED_ACCOUNT"
ok "account $account"

aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1 ||
  die "state bucket $STATE_BUCKET is unreachable — bootstrap has not been applied, or the session cannot see it"
ok "state bucket $STATE_BUCKET"

aws s3api head-object --bucket "$STATE_BUCKET" --key foundation/terraform.tfstate >/dev/null 2>&1 ||
  die "foundation has no state — apply it before rebuilding anything above it"
ok "foundation state present"

deployed="$(read_deployed_scope)"
info "marker currently reads $deployed"

# The two environment layers only. There is no container in the network layer,
# so a SCOPE=network rebuild needs no tag and must not demand one.
declare -a IMAGE_TAGS=()
for layer in "${REBUILD_ORDER[@]}"; do
  case "$layer" in
    staging | prod) ;;
    *) continue ;;
  esac

  param="/bgd/${layer}/image_tag"
  tag="$(aws ssm get-parameter --region "$REGION" --name "$param" \
    --query 'Parameter.Value' --output text 2>/dev/null)" ||
    die "cannot read $param — apply the foundation layer before rebuilding $layer"

  if [[ -z "$tag" || "$tag" == "unset" || "$tag" == "None" ]]; then
    die "$param is '$tag' — run 'make seed-ecr' to record a tag, or let the app pipeline set one"
  fi

  # The check that moves a failure from after the NAT gateway to before it.
  aws ecr describe-images --region "$REGION" \
    --repository-name "${BGD_ECR_REPOSITORY:-bgd-us-east-1-api}" \
    --image-ids "imageTag=$tag" >/dev/null 2>&1 ||
    die "$param names '$tag', which is not in ECR — data.aws_ecr_image would fail at the $layer layer, after the network already exists and is billing"

  IMAGE_TAGS+=("$layer=$tag")
  ok "$param → $tag, present in ECR"
done

# The dry run stops HERE rather than before the block above, and the placement
# is the whole value of the flag: a dry run that checks nothing tells you
# nothing. Stopping here means `BGD_REBUILD_DRY_RUN=1 make rebuild` answers
# "could I rebuild right now?" — session, account, state, marker, both tags and
# both images — for the price of six read-only calls and no resources.
if [[ -n "${BGD_REBUILD_DRY_RUN:-}" ]]; then
  echo
  ok "dry run — preconditions pass; nothing was applied and nothing was written"
  exit 0
fi

# Dies rather than returning empty on a miss. An empty tag would reach
# terraform as `-var image_tag=`, which fails in data.aws_ecr_image with a
# message about an empty tag rather than about this lookup — one layer away
# from the cause, after the network has applied.
tag_for() {
  local layer="$1" entry
  for entry in ${IMAGE_TAGS[@]+"${IMAGE_TAGS[@]}"}; do
    if [[ "${entry%%=*}" == "$layer" ]]; then
      printf '%s' "${entry#*=}"
      return 0
    fi
  done
  die "no image tag was resolved for $layer — the preconditions above should have made this impossible"
}

# ---------------------------------------------------------------------------
# The applies
# ---------------------------------------------------------------------------

declare -a TIMINGS=()

for layer in "${REBUILD_ORDER[@]}"; do
  info "$layer — terraform apply"
  started=$SECONDS

  tf_vars=()
  case "$layer" in
    staging | prod) tf_vars=(-var "image_tag=$(tag_for "$layer")") ;;
  esac

  "$ROOT/scripts/tf.sh" apply "$layer" \
    -auto-approve -input=false -lock-timeout=5m \
    ${tf_vars[@]+"${tf_vars[@]}"} ||
    die "apply failed for $layer; later layers were not touched. The marker still reads what was true before this layer."

  # After the apply, never before: the marker must not claim a layer that did
  # not finish. Plan §D3.
  write_deployed_scope "$(marker_after "$layer")"

  elapsed=$((SECONDS - started))
  TIMINGS+=("$layer|applied|$elapsed")
  ok "$layer applied in $((elapsed / 60))m$((elapsed % 60))s"

  # Smoke each environment as it lands, and stop before the next one if it
  # fails. scripts/smoke.sh asserts that /version's image_digest equals the
  # digest Terraform deployed, which is exactly the question a rebuild raises —
  # and it is the same script Phase 8's pipeline runs. Staging failing here is
  # what keeps prod from being applied on top of a broken rebuild. Plan §D11.
  case "$layer" in
    staging | prod)
      started=$SECONDS
      "$ROOT/scripts/smoke.sh" "$layer" ||
        die "$layer applied but does not serve traffic; later layers were not touched"
      elapsed=$((SECONDS - started))
      TIMINGS+=("$layer smoke|passed|$elapsed")
      ;;
  esac
done

# ---------------------------------------------------------------------------
# What it cost in time — this is where the runbook's number comes from
# ---------------------------------------------------------------------------

echo
printf '  %-16s %-12s %s\n' "step" "outcome" "time"
printf '  %-16s %-12s %s\n' "----" "-------" "----"
total=0
for row in "${TIMINGS[@]}"; do
  IFS='|' read -r name outcome elapsed <<<"$row"
  printf '  %-16s %-12s %dm%02ds\n' "$name" "$outcome" "$((elapsed / 60))" "$((elapsed % 60))"
  total=$((total + elapsed))
done
printf '  %-16s %-12s %dm%02ds\n\n' "total" "" "$((total / 60))" "$((total % 60))"

ok "rebuild complete — $DEPLOYED_SCOPE_PARAM records $(marker_after "${REBUILD_ORDER[${#REBUILD_ORDER[@]} - 1]}")"
```

- [ ] **Step 4: Run and watch it pass**

```bash
chmod +x scripts/rebuild.sh
make test-scripts
```

Expected: `test_operator_scripts.sh: 43 checks, 0 failed`.

- [ ] **Step 5: Add the makefile target and drop the PLANNED line**

In the Phase 10 section:

```make
# The way back. Reads image_tag from SSM rather than terraform.tfvars, which is
# the difference between restoring what was deployed and deploying whatever
# happens to be in a gitignored file. Plan §D10.
.PHONY: rebuild
rebuild: ## Apply network, staging and prod, then smoke both; SCOPE=network|staging|prod (needs an AWS session)
	@./scripts/rebuild.sh
```

Delete the last line of the makefile:

```make
# PLANNED: rebuild        Apply network then staging then prod (Phase 10)
```

- [ ] **Step 6: Check `make help` reads correctly**

```bash
make help
```

Expected: `rebuild`, `teardown`, `verify-idle` and `test-scripts` under **Available now**, and nothing left under **Planned**.

- [ ] **Step 7: Commit**

```bash
git add scripts/rebuild.sh scripts/tests/test_operator_scripts.sh makefile
git commit -m "feat(phase10): rebuild applies network, staging and prod, and smokes both environments"
```

---

### Task 9: The validate stage, the script README, and the full offline gate

**Files:**
- Modify: `pipelines/infra-validate.yml`
- Modify: `scripts/README.md`
- Modify: `infra/foundation/tests/pipeline_shape.tftest.hcl` (the trigger assertion is *unchanged* — confirm it, do not edit it)

- [ ] **Step 1: Add the suite to the validate stage**

In `pipelines/infra-validate.yml`, add `make test-scripts` as the first build command:

```yaml
  build:
    commands:
      # Ordered cheapest-first so a formatting mistake fails in seconds rather
      # than after the container pulls. tf-lint is last because it is the only
      # step that pulls two images.
      #
      # test-scripts is first and is the cheapest of all: pure bash, no
      # container, no Terraform, under a second. It also has the strongest claim
      # to being here — the scripts it tests are the scripts this stage runs.
      # Phase 10 §D14.
      - make test-scripts
      - make tf-fmt-check
      - make tf-validate
      - make tf-test
      - make tf-lint
```

- [ ] **Step 2: Confirm the trigger needs no new pattern**

```bash
grep -A14 'file_paths' infra/foundation/codepipeline.tf | head -20
```

Expected: the seven patterns Phase 9 left — `infra/**`, `pipelines/infra-*.yml`, `scripts/pipeline-terraform.sh`, `scripts/install-terraform.sh`, `scripts/tf.sh`, `scripts/lib/common.sh`, `lambdas/**`. **Change nothing.** The three watched files this phase edits are already matched, and the operator scripts are not pipeline content — no stage runs them, so a change to one changes nothing about what a run does (§F3). Record the check rather than the absence of a change.

- [ ] **Step 3: Update the scripts README**

In `scripts/README.md`, add the three operator scripts and the suite to the table, and a short paragraph:

```markdown
Phase 10 adds the operator pair and the check between them:

| Script | What it is for |
|---|---|
| `teardown.sh` | Destroy prod, staging and network in order. `SCOPE` stops it earlier. Lowers `/bgd/platform/deployed_scope` **before** the first destroy. |
| `verify-idle.sh` | Prove nothing billable survived, without reading a state file. |
| `rebuild.sh` | Apply the way back and smoke both environments. The only thing that raises the marker. |
| `tests/` | The shell suite. `make test-scripts`; needs bash and nothing else. |

`foundation` and `bootstrap` are unreachable from all three: there is no `SCOPE`
value and no flag that names them.
```

- [ ] **Step 4: Run the whole offline gate**

```bash
make test-scripts
make tf-check
make test-lambdas
bash -n scripts/*.sh scripts/lib/common.sh scripts/tests/*.sh scripts/tests/fake-bin/aws
```

Expected: the suite green; `all infra checks passed`; the Lambda suite green; `bash -n` silent.

- [ ] **Step 5: Commit**

```bash
git add pipelines/infra-validate.yml scripts/README.md
git commit -m "chore(phase10): the shell suite joins the pipeline's validate stage"
```

---

### Task 10: The runbook

**Files:**
- Create: `docs/runbooks/phase-10-teardown-and-rebuild.md`
- Modify: `docs/runbooks/README.md`
- Modify: `docs/runbooks/phase-08-app-pipeline.md` (§11)

- [ ] **Step 1: Write the runbook**

Create `docs/runbooks/phase-10-teardown-and-rebuild.md` with these sections, each carrying exact commands and expected output in the style of the Phase 4 through 9 runbooks:

1. **What survives and what does not** — a table, before any command, because it is the thing someone wants to know before they run the first one.

   | Survives `make teardown` | Destroyed |
   |---|---|
   | hosted zone, ACM certificate, both ECR repositories and every image | both ALBs and their listeners and target groups |
   | the state bucket and every layer's state | both ECS clusters, services and task definitions |
   | the artifact bucket, every SBOM and every test report | all four DynamoDB tables **and their contents** |
   | the SNS topic and its confirmed subscription | the three lifecycle hook Lambdas |
   | the CodeConnections authorisation | the four production bake alarms |
   | both pipelines and all eight CodeBuild projects | the VPC, both NAT-facing subnets, the NAT Gateway and its Elastic IP |
   | the collector Lambda, its log group and the dashboard | the application log groups and everything in them |
   | all three SSM parameters | the two Route 53 records (recreated on rebuild, same names) |

   With the sentence that matters attached: **the DynamoDB tables are destroyed and rebuilt empty.** Nothing in this project treats that as data loss — `deletion_protection_enabled = false` is set explicitly on all four and the Phase 5 plan's D6 argues it — but it is the one irreversible thing a teardown does, and it belongs at the top rather than in a footnote.

2. **Precondition** — an AWS session and `make verify-aws`.
3. **Teardown** — `make teardown`, the typed confirmation, the expected timing table, and what a failure part-way through means (the marker already reads the surviving scope, so both pipelines are already skipping; re-run once the cause is fixed).
4. **Confirm it is idle** — `make verify-idle`, its expected table, and what the `deleting` warning means.
5. **What the pipelines do now** — the marker, the two skip messages, and the explicit statement that a merge to `main` is safe and will not recreate anything. This replaces Phase 8's "disable both triggers in the console".
6. **Rebuild** — `BGD_REBUILD_DRY_RUN=1 make rebuild` first, which answers *could I rebuild right now?* by running all six preconditions and stopping before the first apply; then `make rebuild`, the per-layer timings, and both smoke runs.
7. **What a cycle costs in time** — a table to be filled in from the two timing tables the scripts print, with the estimates to be replaced by measurements on the first real run:

   | Step | Estimate | Measured |
   |---|---|---|
   | teardown, prod | 3–5 min | — |
   | teardown, staging | 2–4 min | — |
   | teardown, network | 2–3 min (the NAT dominates) | — |
   | rebuild, network | 2–4 min | — |
   | rebuild, staging + smoke | 4–6 min | — |
   | rebuild, prod + smoke | 5–8 min (`wait_for_steady_state`) | — |

   Marked as **estimates, not measurements**, in the same words the Phase 4 runbook uses about the NAT cost — a number nobody has observed should not be printed as though somebody had.

8. **Partial cycles** — `SCOPE=staging` for an app-only session, and what it costs and saves.
9. **The escape hatch** — the one `aws ssm put-parameter` command that raises the marker by hand, when you want the pipeline to do the rebuild, and the warning that it is a claim about the account rather than a change to it.
10. **What this runbook cannot do** — tear down `foundation`. What it would cost to undo: re-authorising CodeConnections by hand, re-confirming the SNS subscription, re-validating the certificate, and losing every SBOM and the entire metric history. Listed so the answer to "can I destroy everything" is a paragraph rather than a silence.

- [ ] **Step 2: Update the runbooks README**

Replace the planned row:

```markdown
| [Teardown, the idle check, and the rebuild — what survives, what does not, how long it takes](../../runbooks/phase-10-teardown-and-rebuild.md) | 10 |
```

And replace the paragraph beginning *"From Phase 7 the infra pipeline applies `infra/`"*'s teardown caveat with the new behaviour: both pipelines now read `/bgd/platform/deployed_scope` and skip the layers a teardown removed, so a merge while torn down is safe and creates nothing.

- [ ] **Step 3: Rewrite Phase 8's runbook §11**

`docs/runbooks/phase-08-app-pipeline.md` currently ends §11 with *"either stop merging to `main` or disable both triggers in the console — and re-enable them as the first step of the Phase 10 rebuild."* That instruction is now wrong. Replace the paragraph with:

```markdown
One consequence worth knowing before you walk away: the pipelines stay armed —
and since Phase 10 that is safe. `make teardown` lowers
`/bgd/platform/deployed_scope`, and both pipeline drivers clamp their own scope
to it, so a merge to `main` after a teardown validates, applies `foundation`,
builds and pushes an image, and skips every stage whose layer no longer exists.
The run finishes green, creates nothing, and Phase 9's change-failure-rate
correctly does not count it.

There is nothing to disable and nothing to re-enable. `make rebuild` raises the
marker again as its last act on each layer; see [the Phase 10
runbook](../../runbooks/phase-10-teardown-and-rebuild.md).
```

- [ ] **Step 4: Commit**

```bash
git add docs/runbooks
git commit -m "docs(phase10): the teardown and rebuild runbook, and Phase 8's §11 corrected"
```

---

### Task 11: Amendments and the local verification record

**Files:**
- Modify: `docs/2026-08-04-implementation-phase-roadmap.md`
- Create: `docs/phases/phase10/2026-08-30-local-verification.md`

- [ ] **Step 1: Amend the roadmap's Phase 10 section**

After the Phase 10 exit criteria, add an amendment in the form Phases 3 through 9 use, covering:

- **Everything the task list does not name**, each with the argument: the marker and the pipeline clamp (D2, D5), `SCOPE` on both scripts (D7), `verify-idle` (D9), the shell suite (D12), and `layer_dir` moving into `common.sh` (D13).
- **The gap Phase 8 handed here by name**, closed — and the corollary the task list does not state: **a merge can no longer rebuild a torn-down layer.**
- **The fourth bullet is not met by the branch**, in those words. The roadmap asks for an executed cycle; this session created no AWS resource, and the cycle is [the runbook](../../runbooks/phase-10-teardown-and-rebuild.md)'s steps 3 through 6. Say it plainly, as Phases 3 through 9 did.
- **§2's branch table row 10** reads `feat/Phase10_TeardownRebuild`, which is the branch used. **No amendment needed** — recorded explicitly, as Phases 3, 5, 6, 7, 8 and 9 did, so the absence reads as checked rather than overlooked.

- [ ] **Step 2: Amend the roadmap's Phase 7 and Phase 8 sections**

Both describe behaviour this phase changes, and both already carry the precedent that a cross-phase change is recorded in *both* places. Add to each a short note that the driver now clamps its scope to `/bgd/platform/deployed_scope`, that out-of-marker stages skip green, and that the trigger's seven patterns are unchanged (F3).

- [ ] **Step 3: Write the local verification record**

Create `docs/phases/phase10/2026-08-30-local-verification.md` in the shape Phases 8 and 9 use:

1. **The gate** — the three suites' output, with the count of new runs and what each group protects against.
2. **Static analysis triage** — every checkov finding on the new resource, fixed or skipped with the reason.
3. **The executed evidence** — the refusal paths run by hand with the fake CLI: every `SCOPE` value on both scripts, both dry runs, the clamp in both drivers, the marker-before-destroy ordering asserted against `FAKE_AWS_LOG`, and the two skip messages shown to differ.
4. **No AWS resource was created** — the explicit statement, with the same evidence Phases 6 through 9 gave.
5. **What remains before the exit criterion is met** — the runbook's steps 3 through 6.
6. **Findings discovered during implementation** — appended as they arise, each numbered from F9.
7. **Departures from the plan's literal text** — anything implemented differently, with the reason.
8. **Carried forward** — what Phase 11 inherits, specifically that its three demonstrations need a rebuilt environment and that `make rebuild` is now the way to get one.

- [ ] **Step 4: Run the full gate one last time**

```bash
make test-scripts && make tf-check && make test-lambdas
```

Expected: all three green.

- [ ] **Step 5: Commit**

```bash
git add docs
git commit -m "docs(phase10): roadmap amendments and the local verification record"
```

---

## 5. Exit criteria

The roadmap's criterion for this phase:

> After a teardown-and-rebuild cycle, both environments serve traffic again with no manual step other than waiting.

**It is not met by this branch**, and neither is the roadmap's fourth task-list bullet asking for an executed cycle. Both need a real teardown and a real rebuild against a live account, and this session creates no AWS resource (D1). They are met by [the runbook](../../runbooks/phase-10-teardown-and-rebuild.md) — steps 3 through 6, ending with `make rebuild` exiting 0, which by D11 means both environments were smoke-tested and served the digest Terraform deployed.

What this branch's gate does prove:

| Claim | Proved by |
|---|---|
| Every `SCOPE` value on both scripts behaves as documented, and unknown values are refused by name | `test_operator_scripts.sh` |
| No `SCOPE` value and no flag reaches `foundation` or `bootstrap` | `test_operator_scripts.sh` |
| The marker is written before the first destroy and after each apply | `test_operator_scripts.sh`, asserted against the fake CLI's call log |
| Both pipeline drivers skip green when their layer is torn down, with a message that does not blame the scope | `test_pipeline_scope.sh` |
| `foundation` can be planned when the marker does not yet exist | `test_pipeline_scope.sh` |
| An unreadable marker is fatal for every layer above `foundation` | `test_pipeline_scope.sh` |
| Phase 7's and Phase 8's scope matrices are unchanged by the clamp | `test_pipeline_scope.sh` |
| The parameter defaults to `all`, is a `String`, and carries the name the scripts look up | `foundation/tests/pipeline_shape.tftest.hcl` |
| Each of the rebuild's six preconditions refuses before any apply — wrong account, unreachable bucket, missing state, unreadable marker, unset tag, tag absent from ECR | `test_operator_scripts.sh`, all through the dry run |
| `verify-idle` reads no state file and covers the four ephemeral services | `test_operator_scripts.sh` |
| Every layer still validates, lints and tests | `make tf-check` |

---

## 6. Risks this phase adds

| Risk | Handling |
|---|---|
| **The marker drifts from reality after a by-hand `make apply-prod`.** It is a teardown marker, not a deployment registry (D4), so it does not observe manual applies. | Stated in the runbook and in the parameter's own description. The failure is a stage skipping when it did not need to, which is visible in the console and fixed by one `put-parameter`. The opposite failure — deploying when it should not — cannot happen, because the marker only ever restricts. |
| **A merge can no longer rebuild a torn-down layer** (D5), which will surprise someone eventually. | Deliberate, and the surprise is the cheap direction: the alternative is a $99/month one. The skip message names the marker, its value, and `make rebuild`. The runbook's step 9 gives the one-line escape hatch. |
| **`verify-idle`'s catch-all depends on the four ephemeral services staying ephemeral.** A future phase that puts a surviving resource in `ec2`, `ecs`, `elasticloadbalancing` or `dynamodb` would make it warn forever. | The sweep is a warning, never a verdict (F2), so the cost is noise rather than a false red. The rule is stated in the script's own comment so the next phase to add such a resource reads it. |
| **The rebuild's time estimates are estimates.** §7 of the runbook prints numbers nobody has measured. | Labelled as estimates in the runbook, in the same words Phase 4 used about the NAT cost, and both scripts print a measured table specifically so the first real run replaces them. |
| **`terraform state list` in `teardown.sh` needs the real backend**, so the empty-state skip costs an `init` per layer even when it then skips. | Accepted: an `init` is seconds and the skip saves a full destroy cycle. The `init` failure is swallowed (`|| true`) so a layer whose backend cannot be reached falls through to the destroy, which then fails loudly with a Terraform error rather than a silent skip — the safe direction, since a silent skip is how a production layer gets left running. |
