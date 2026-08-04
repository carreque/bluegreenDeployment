# Phase 0 — Prerequisites and Repository Scaffolding: Implementation Plan

**Date:** 2026-08-04
**Status:** Proposed, awaiting approval
**Branch:** `feat/Phase0_Scaffolding`
**AWS cost incurred by this phase:** $0
**Companion documents:**
[design research](./2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](./2026-08-04-implementation-phase-roadmap.md)

---

## 0. Purpose and non-goals

Phase 0 exists to make sure nothing gets built on an assumption that turns out to be false. It produces two things: **recorded answers** to every environmental question the design rests on, and a **repository skeleton** with a single documented entry point for local commands.

**This phase deliberately does not:**

- create any AWS resource, or run any `terraform apply`
- write any application code, `Dockerfile`, or Terraform configuration
- install anything into the AWS account

The only AWS calls made are read-only identity and Route 53 lookups.

---

## 1. Finding already recorded before this plan was written

The design document's environment audit (§2) does not describe this machine. Verified 2026-08-04:

| Tool | Design doc §2 | This machine | Verdict |
|---|---|---|---|
| terraform | 1.15.7 | **1.5.7** | **Blocking** |
| python | 3.14.6 | **3.12.3** | **Blocking** |
| git | 2.39.1.windows.1 | 2.50.1 (Apple Git-155) | Stale record |
| docker | 29.4.3 | 28.3.2 | Benign |
| aws-cli | 2.15.19 | 2.35.4 | Benign, newer |

The Windows git string shows the §2 audit was taken on a different machine. Two design decisions depend on the values it recorded:

- **Design §1.8** concluded that no DynamoDB lock table is needed because the S3 backend's `use_lockfile` is available. That option requires **Terraform ≥ 1.10**. On 1.5.7 the conclusion is false.
- **Design §1.6** chose `python:3.14-slim` partly *because* it matched local 3.14.6, arguing that local-vs-container parity is concrete evidence for the build-reproducibility requirement. At local 3.12.3 that argument does not hold.

Neither invalidates the architecture. Both need either a toolchain fix or a documented amendment, which is what task group **B** handles.

Also confirmed: `origin` is `https://github.com/carreque/bluegreenDeployment.git`, and both `main` and `feat/Phase0_Scaffolding` exist locally and on the remote.

---

## 2. Task group A — Verification

Runs first, because an answer here can invalidate work downstream. Every task records **the exact command, its raw output, the answer, and the design consequence** into the findings document (task E1).

### A1 — Re-audit the local toolchain

```bash
git --version
terraform version
python3 --version
docker --version
aws --version
make --version | head -1
jq --version
```

`jq` is needed by A6/A7. If absent, note it and use `python3 -m json.tool` instead.

**Records:** a replacement for design §2.
**Consequence if different from §2:** already known — drives group B.

### A2 — AWS identity and region

The SSO token is expired (design §11). Login is interactive, so **you run it**:

```
! aws sso login --profile bootcamp-administrator-access
```

Then:

```bash
aws sts get-caller-identity --profile bootcamp-administrator-access
aws configure get region --profile bootcamp-administrator-access
```

**Records:** account ID, caller ARN, region.
**Consequence:** the account ID becomes a naming input — S3 buckets are globally unique, so `bgd-<scope>-<purpose>-<account-id>` (task E2) needs it. If the region is not `us-east-1`, the design's single-region assumption and the `route53domains` endpoint both need revisiting.

### A3 — Does a hosted zone for `carloscloudengineer.com` already exist?

```bash
aws route53 list-hosted-zones-by-name \
  --dns-name carloscloudengineer.com \
  --profile bootcamp-administrator-access

aws route53domains get-domain-detail \
  --domain-name carloscloudengineer.com \
  --region us-east-1 \
  --profile bootcamp-administrator-access

dig NS carloscloudengineer.com +short
```

`route53domains` is only available in `us-east-1` regardless of the working region.

The three commands answer three different things: whether a zone resource exists, which name servers the **registrar** publishes, and what the **public internet** currently resolves. They must agree for ACM validation to succeed.

**Records:** zone exists yes/no; zone ID; the zone's NS set; the registrar's NS set; the publicly resolving NS set; whether all three match.
**Consequence:**

- *Zone exists and NS agree* → Phase 3 takes the **adopt** path. `wait_for_validation` can be `true` on the first apply. The two-phase apply never happens.
- *Zone absent, or NS disagree* → Phase 3 takes the **create/delegate** path: apply with `wait_for_validation = false`, update the registrar's name servers, wait for propagation, apply again. Phase 3's duration estimate grows by up to 48 hours of DNS propagation and the runbook must say so.

### A4 — Which Python runtimes does Lambda currently offer?

There is no reliable CLI enumeration of managed runtimes. Primary source is the docs page, cross-checked against the CLI:

```bash
aws lambda help | grep -i runtime   # check whether an enumeration command now exists
```

Then read <https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html> and record the full supported list with deprecation dates.

If the answer is ambiguous, probe it directly — Lambda's `InvalidParameterValueException` enumerates the valid values:

```bash
aws lambda create-function --function-name bgd-runtime-probe \
  --runtime python3.14 --role arn:aws:iam::000000000000:role/nonexistent \
  --handler index.handler --zip-file fileb:///dev/null \
  --profile bootcamp-administrator-access
```

This is expected to fail. It creates nothing.

**Records:** whether `python3.14` is offered; the newest Python runtime that is; its deprecation date.
**Consequence:** the Phase 6 lifecycle hooks and the Phase 9 metrics collector pin to the newest available runtime. If that is not 3.14, the divergence from the container's 3.14 is recorded now as a deliberate decision rather than discovered in Phase 6. Not a blocker either way.

### A5 — Does AWS provider ≥ 6.4 resolve?

In a throwaway directory outside the repository:

```bash
PROBE="$(mktemp -d)"
cat > "$PROBE/versions.tf" <<'EOF'
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.4"
    }
  }
}
EOF
terraform -chdir="$PROBE" init
terraform -chdir="$PROBE" version
```

**Records:** the exact provider version selected, and whether `terraform init` succeeded on the installed core version.
**Consequence:** if the installed Terraform core is too old to resolve provider 6.x, group B's upgrade becomes mandatory rather than optional. Keep `$PROBE` — A6 and A7 reuse it.

### A6 — Does `aws_ecs_service` expose `deployment_configuration` and `lifecycle_hook`?

Against the **installed** provider, not the changelog:

```bash
terraform -chdir="$PROBE" providers schema -json > "$PROBE/schema.json"

jq '.provider_schemas["registry.terraform.io/hashicorp/aws"]
    .resource_schemas.aws_ecs_service.block.block_types | keys' "$PROBE/schema.json"
```

**Records:** whether `deployment_configuration` and `lifecycle_hook` appear in the block-type list.
**Consequence:** **this is the highest-stakes question in Phase 0.** If either is absent, the ECS-native path (design §1.2, §1.4) is not implementable with this provider, and Phases 6, 7 and 8 revert to the CodeDeploy controller. That would be a design-level pivot, not a plan adjustment, and it stops Phase 0 until resolved.

### A7 — Are the blue/green attribute details present?

```bash
jq '.provider_schemas["registry.terraform.io/hashicorp/aws"]
    .resource_schemas.aws_ecs_service.block.block_types.deployment_configuration' "$PROBE/schema.json"

jq '.provider_schemas["registry.terraform.io/hashicorp/aws"]
    .resource_schemas.aws_ecs_service.block.block_types.lifecycle_hook' "$PROBE/schema.json"

jq '.provider_schemas["registry.terraform.io/hashicorp/aws"]
    .resource_schemas.aws_ecs_service.block.block_types.load_balancer
    .block.block_types.advanced_configuration' "$PROBE/schema.json"
```

**Records:** the exact attribute names and nesting for `strategy`, `bake_time`, the lifecycle hook's `hook_target_arn` / `role_arn` / `lifecycle_stages`, and `advanced_configuration`'s required fields. Copy the raw JSON into the findings document — Phase 6 writes HCL directly against it.
**Consequence:** attribute names that differ from the design's §1.4 sketch get corrected here, before Phase 6 is written against a guess.

---

## 3. Task group B — Toolchain remediation — **resolved 2026-08-04**

Both gaps are closed. Terraform is now **1.15.7** (above the 1.10 floor, so `use_lockfile` is real and design §1.8 stands unamended) and Python is **3.14.6** (matching design §2 and restoring §1.6's parity argument). Repository pins `.terraform-version` and `.python-version` are committed alongside.

The Python fix was not a plain install. pyenv had 3.14.6 set global, but `pyenv init` lived in `~/.zshrc`, which zsh sources **only for interactive shells** — so scripts, `make` recipes and hooks resolved a different interpreter than the terminal did. Two further shadowing layers were found on top of it:

| Layer | Effect | Fix |
|---|---|---|
| `~/.zprofile` prepended the python.org 3.12 framework | login shells got 3.12.3 | line removed; the framework install itself is untouched on disk |
| `~/.zprofile` runs `brew shellenv`, prepending `/opt/homebrew/bin` **after** `.zshenv` | login shells got homebrew's 3.14.5 | shims re-prepended after the `brew shellenv` call |
| `~/.zshenv` set `PYTHON=/opt/homebrew/bin/python3` and appended `$PYTHON/bin` | a PATH entry built from a file, not a directory — junk | removed; `PYTHON` repointed at the pyenv shim |

`pyenv init` stays in `~/.zshrc` for the interactive shell function; the PATH export moved to `~/.zshenv` so every shell kind inherits it. Dotfiles were backed up to `~/.zshenv.bak-phase0`, `~/.zprofile.bak-phase0` and `~/.zshrc.bak-phase0` before editing.

Verified across all four zsh invocation modes and, critically, **bash launched from a login zsh** — which is what a `make` recipe actually runs in. All report 3.14.6.

The original text of this group, describing the options considered, is retained below for the record.

### B1 — Terraform

Options, to be decided after A1:

| Option | Effect |
|---|---|
| `brew install tfenv` then `tfenv install latest && tfenv use latest` | Per-project version pinning via `.terraform-version`, committed to the repo. Preferred — it makes the required version part of the repository. |
| `brew install terraform` | Single global version. Simpler, no pinning. |
| Stay on 1.5.7 | Requires amending design §1.8 to reinstate a DynamoDB lock table in `infra/bootstrap`, and adds a resource Phase 3 must create and Phase 10 must preserve. |

Note that 1.5.7 is the last MPL-licensed release; 1.6+ is BUSL. If the 1.5.7 pin was deliberate for licensing reasons, say so and we take the third option knowingly.

### B2 — Python

| Option | Effect |
|---|---|
| `pyenv install 3.14.x` + `.python-version` in the repo | Restores design §1.6's parity argument and pins the version for anyone cloning. Preferred. |
| Stay on 3.12.3 | Requires amending design §1.6: the container still targets 3.14, but the "matches local" justification is struck and replaced with "pinned by digest, verified in CI". The reproducibility requirement is still met — by the digest pin and hash-locked requirements, which were always the stronger evidence. |

### B3 — Re-verify after remediation

Re-run A1, A5, A6 and A7 and record the after-state alongside the before-state. A verification that is not re-run after a change is not a verification.

### B4 — Amend the design documents if remediation is declined

Any option above that diverges from the design gets written back into the design document as an explicit, dated amendment — not left as a silent contradiction between two files in `docs/`.

---

## 4. Task group C — Repository scaffolding

### C1 — Directory skeleton

Most of this already exists on disk. The tree below is the authoritative target; only the rows marked **new** are still to be created. Every leaf directory holds a `.gitkeep` (git does not track empty directories) **and** a short `README.md` naming what lands there and in which phase.

```
app/
  src/                              Phase 1   FastAPI service
  tests/                            Phase 1   pytest suite
infra/
  bootstrap/                        Phase 3   root — S3 state backend, local state
  foundation/          new          Phase 3   root — zone, ACM, ECR, artifacts, SNS, pipelines, IAM
  network/             new          Phase 4   root — VPC, subnets, IGW, NAT, endpoints, SGs
  environments/
    staging/                        Phase 5   root — ALB, ECS rolling service, DynamoDB
    prod/                           Phase 6   root — ALB :443 + :8443, ECS BLUE_GREEN, hooks
  modules/
    foundation/                     Phase 3
    network/                        Phase 4
    lambda/                         Phase 6   lifecycle hooks; reused in Phase 9 for metrics
pipelines/                          Phase 7   CodeBuild buildspecs
scripts/
  lib/                 new          Phase 0   shared shell helpers
.github/               new
  workflows/                        Phase 1   PR validation — ruff, pytest
  CODEOWNERS                        Phase 0
  pull_request_template.md          Phase 0
docs/
  adr/                 new          Phase 11  architecture decision records
  evidence/            new          Phase 11  rollback demonstration evidence
  runbooks/            new          Phase 3+  operational runbooks
makefile                            Phase 0   front door; logic lives in scripts/
```

**Roots versus modules.** `bootstrap`, `foundation`, `network`, `environments/staging` and `environments/prod` are the roadmap's five layers, and each is a **root module with its own state file**. That separation is what the destroy-when-idle policy depends on: `terraform destroy` against `network` must not be able to reach `foundation`'s certificate or ECR images. `infra/modules/` holds reusable code, which has no state of its own and is never applied directly — hence `foundation` and `network` appearing in both places, as a root that calls a module of the same name.

**Modules are created by the phase that needs them,** not pre-created here. `alb`, `ecs-service`, `pipeline` and `observability` will likely appear later; adding empty directories for them now would assert a decomposition that Phases 5–9 have not made yet. This is the same reasoning as the makefile's "only what works today".

Structure differs from design §9 in three ways, all deliberate: `environments/` rather than `envs/`, Lambda code under `infra/modules/lambda/` rather than a top-level `lambdas/`, and the addition of `scripts/` and `.github/`, which §9 omits.

### C2 — `.gitignore` — **done**

Written and verified 2026-08-04. Covers Terraform (plugin caches, state, saved plans, crash logs, overrides), credentials and secrets, Python and its test/lint caches, build artefacts, editor and macOS noise, and local scratch.

Four negations carry the reasoning and are annotated in the file itself:

| Kept in git | Why |
|---|---|
| `.terraform.lock.hcl` | The provider lock file is what makes provider versions identical between this machine and CodeBuild. Ignoring it would quietly defeat the build-reproducibility requirement (design §4.1). |
| `.terraform-version`, `.python-version` | Toolchain pins belong to the repository, not the machine (group B). |
| `*.tfvars.example` | Real values stay out of git; the required shape stays documented. |
| `.env.example` | Same reasoning for application configuration. |

Verified by `git check-ignore` against twelve representative paths — lock files and version pins tracked; state, plans, `*.tfvars`, `.venv/`, `.env`, `.DS_Store` ignored; both `.example` counterparts surviving.

### C3 — `.editorconfig`

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 2

[*.py]
indent_size = 4

[[Mm]akefile]
indent_style = tab

[*.sh]
indent_size = 2

[*.md]
trim_trailing_whitespace = false
```

The last two matter: Make requires literal **tabs** and fails cryptically on spaces, and trailing whitespace in Markdown is a significant line break, so trimming it silently changes rendering.

The pattern is `[[Mm]akefile]` rather than `[Makefile]` because the file on disk is lowercase. GNU make searches `GNUmakefile`, then `makefile`, then `Makefile`, so lowercase works — but macOS's case-insensitive filesystem hides the difference locally while Linux (CodeBuild) does not, so the glob is written to match either.

### C4 — `.github/`

GitHub's role in this design is source-only: CodeConnections grants CodePipeline read access, and a push to `main` filtered by path triggers a pipeline. GitHub executes no deployment. `.github/` therefore exists for **pull-request hygiene**, not delivery, and does not overlap with `pipelines/` — which holds CodeBuild buildspecs, a different format read by a different engine.

Landing in Phase 0:

- `CODEOWNERS` — assigns review to you, making the roadmap §2 rule that merging is always your action a repository setting rather than a convention.
- `pull_request_template.md` — its body is the phase exit-criteria checklist plus a "how each was verified" column, so roadmap §2 step 4 is prefilled on every phase PR.

Landing in Phase 1, once there is Python to check:

- `workflows/pr-validate.yml` — runs `ruff` and `pytest` on pull requests.

This closes a real gap the roadmap concedes in §2.1: pull requests do not trigger the pipelines, only the merge does, so pre-merge validation currently runs locally on the honour system. The workflow needs **no AWS credentials and no OIDC federation** — it lints and tests source, and touches nothing in the account. That keeps the "all deployment compute is CodeBuild in-account" story intact while making the pre-merge gate enforced rather than voluntary.

---

## 5. Task group D — Makefile and scripts

**Make is the discoverable front door; scripts hold the logic.** The rule, recorded in the Makefile header: *any recipe longer than three lines, or needing a conditional or a loop, becomes a script in `scripts/` and the target only calls it.* Phase 10's ordered teardown is the reason — it is real shell, not a Make recipe.

### D1 — `scripts/lib/common.sh`

Shared helpers every later script reuses: `info`, `ok`, `warn`, `die`, `require_cmd`, and a `version_gte` comparison. Written once here so Phases 4 and 10 inherit it.

### D2 — `scripts/verify-tools.sh`

Checks each tool against a documented minimum, prints a result table, exits non-zero if any fail. The minimums it enforces:

| Tool | Minimum | Why |
|---|---|---|
| terraform | ≥ 1.10.0 | `use_lockfile` on the S3 backend (design §1.8) |
| python3 | ≥ 3.14.0 | parity with the container (design §1.6) |
| docker | ≥ 24.0 | BuildKit |
| aws | ≥ 2.15.0 | recorded baseline |
| git | ≥ 2.39.0 | recorded baseline |
| make | ≥ 3.81 | see note below |
| jq | any | Terraform schema inspection |

Every minimum is met as of group B's resolution, so `make verify` is expected to pass.

The script checks `python3 --version` as resolved through `PATH`, deliberately — not `pyenv which python3`. The bug group B fixed was precisely a `PATH` resolution difference between shell kinds, and a check that bypasses `PATH` would not have caught it.

**A note on `make` 3.81.** macOS ships GNU Make 3.81, the last GPLv2 release. It supports everything this project needs — `.DEFAULT_GOAL`, `MAKEFILE_LIST`, pattern rules, `SHELL` override — but **not** `.ONESHELL` or `.RECIPEPREFIX`, both of which arrived in 3.82. `.ONESHELL` would matter for multi-line recipes that need shared shell state; the rule that recipes stay under three lines and logic lives in `scripts/` sidesteps it entirely. No upgrade required, and none recommended.

### D3 — `scripts/verify-aws.sh`

Confirms an active SSO session via `sts get-caller-identity`, prints account, ARN and region, and fails with the literal `aws sso login --profile …` command to run when the token is expired.

### D4 — `makefile`

Already present on disk as an empty file; this task fills it.

```make
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

AWS_PROFILE ?= bootcamp-administrator-access
AWS_REGION  ?= us-east-1
export AWS_PROFILE AWS_REGION

.PHONY: help verify verify-tools verify-aws

help: ## Show available commands
	@printf '\nUsage: make <target>\n\nAvailable now:\n'
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\nPlanned:\n'
	@sed -n 's/^# PLANNED: //p' $(MAKEFILE_LIST) | awk '{printf "  %-16s %s\n", $$1, substr($$0, index($$0," ")+1)}'
	@printf '\n'

verify: verify-tools verify-aws ## Run every Phase 0 verification check

verify-tools: ## Check the local toolchain against documented minimums
	@./scripts/verify-tools.sh

verify-aws: ## Confirm the AWS SSO session, account and region
	@./scripts/verify-aws.sh

# PLANNED: test            Run the application test suite (Phase 1)
# PLANNED: lint            Ruff lint and format check (Phase 1)
# PLANNED: run-local       docker compose up with DynamoDB Local (Phase 1)
# PLANNED: build           Build the container image (Phase 2)
# PLANNED: sbom            Generate the SBOM with syft (Phase 2)
# PLANNED: plan-<layer>    terraform plan for one layer (Phase 3)
# PLANNED: apply-<layer>   terraform apply for one layer (Phase 3)
# PLANNED: teardown        Destroy prod -> staging -> network (Phase 10)
# PLANNED: rebuild         Apply network -> staging -> prod (Phase 10)
```

Only three targets are real, per the "only what works today" decision. The `# PLANNED:` comments give `make help` the full intended vocabulary as text without declaring targets that would lie about working — which satisfies the roadmap's exit wording honestly.

---

## 6. Task group E — The written record

### E1 — `docs/2026-08-04-phase-00-verification-findings.md`

One section per verification task A1–A7, each with: the question, the exact command, the raw output verbatim, the answer, and the design consequence. Where group B changes something, both before and after states appear.

This is the phase's most valuable artefact. Phase 3 reads §A3 to know which hosted-zone path to take; Phase 6 reads §A7 to write HCL against real attribute names.

### E2 — `docs/naming-and-tagging-convention.md`

**Naming.** Pattern `bgd-<scope>-<resource>[-<qualifier>]`, lowercase and hyphen-separated, where `<scope>` is one of `foundation`, `network`, `staging`, `prod`.

| Resource type | Pattern | Example |
|---|---|---|
| S3 bucket | `bgd-<scope>-<purpose>-<account-id>` | `bgd-foundation-tfstate-123456789012` |
| ECR repository | `bgd/<service>` | `bgd/api` |
| IAM role | `bgd-<scope>-<function>-role` | `bgd-prod-task-execution-role` |
| CloudWatch log group | `/bgd/<scope>/<service>` | `/bgd/prod/api` |
| DynamoDB table | `bgd-<scope>-<entity>` | `bgd-prod-transactions` |
| ALB / target group | `bgd-<scope>-<role>` | `bgd-prod-api-blue` |

Two constraints the document states explicitly, because both are silent failures at apply time: S3 bucket names are **globally unique**, which is why the account ID is suffixed; and ALB and target-group names are capped at **32 characters** and reject underscores.

**Tagging.** Applied through the provider's `default_tags` block so no resource is tagged by hand:

```hcl
default_tags {
  tags = {
    Project     = "bluegreen-deployment"
    Layer       = var.layer          # foundation | network | staging | prod
    Environment = var.environment    # shared | staging | prod
    ManagedBy   = "terraform"
    Repository  = "carreque/bluegreenDeployment"
    Owner       = "carreque45@gmail.com"
    CostCenter  = "portfolio"
  }
}
```

The document also records the two known gaps: `default_tags` does not reach ECS **tasks** unless the service sets `propagate_tags = "SERVICE"`, and a handful of resource types accept no tags at all.

### E3 — Amend the roadmap's branch table

Roadmap §2 lists `phase-00-scaffolding` through `phase-11-evidence-docs`. Per your decision the existing branch name wins, so all twelve rows become `feat/PhaseNN_Name` — `feat/Phase0_Scaffolding`, `feat/Phase1_Application`, and so on. A one-line note records that the convention was changed in Phase 0 to match the branch already in flight.

---

## 7. Commit sequence

Each commit is **proposed for your approval, never made automatically** (roadmap §2).

| # | Commit | Contents |
|---|---|---|
| 1 | `docs: add implementation phase roadmap` | The roadmap file, currently staged in the index but never committed |
| 2 | `docs: record Phase 0 verification findings` | E1, after group A completes |
| 3 | `chore: pin and remediate local toolchain` | B1/B2 outputs — `.terraform-version`, `.python-version` (only if remediation is taken) |
| 4 | `docs: amend design for verified environment` | B4 amendments to design §1.6 / §1.8 (only if remediation is declined) |
| 5 | `chore: add repository skeleton, gitignore and editorconfig` | C1, C2, C3 |
| 6 | `chore: add CODEOWNERS and pull request template` | C4 |
| 7 | `chore: fill makefile and add verification scripts` | D1–D4 |
| 8 | `docs: record resource naming and tagging convention` | E2 |
| 9 | `docs: align roadmap branch table with feat/PhaseNN_Name` | E3 |

Commits 3 and 4 are mutually exclusive.

---

## 8. Exit criteria

Phase 0 is done when every line below is true and demonstrated:

1. All seven verification questions A1–A7 have a recorded answer with raw command output in `docs/2026-08-04-phase-00-verification-findings.md`.
2. A6 confirms `deployment_configuration` and `lifecycle_hook` exist in the installed provider — or, if not, Phase 0 is halted and the design is reopened.
3. The local toolchain either meets the design's stated versions, or the design has been amended to match reality. No silent contradiction remains between `docs/` and the machine.
4. The directory skeleton exists and matches §4 of this plan, every leaf carrying a `.gitkeep` and a README, and the five layer roots (`bootstrap`, `foundation`, `network`, `environments/staging`, `environments/prod`) are each present as a directory of their own.
5. `.gitignore` behaves as documented, demonstrated by `git check-ignore` output in the findings document; `CODEOWNERS` and the pull request template are in place.
6. `make help` runs and lists three working targets plus the planned vocabulary.
7. `make verify` runs and its result is consistent with criterion 3 — green if the toolchain was remediated, and if it was not, the lowered minimums are in place and it is green anyway.
8. `docs/naming-and-tagging-convention.md` is committed.
9. Roadmap §2's branch table matches the branch convention actually in use.
10. A pull request is open against `main`, its description listing these criteria and how each was verified.

---

## 9. Risks inside this phase

| Risk | Handling |
|---|---|
| **A6 finds no blue/green attributes in the provider** | Phase 0 halts. This is a design-level pivot to the CodeDeploy controller affecting Phases 6–8, not something to work around locally. The whole point of asking in Phase 0 is to find it now. |
| **SSO login is interactive** | Blocks A2, A3 and A4. You run `! aws sso login --profile bootcamp-administrator-access`; everything after it is automated. |
| **The hosted zone create path adds DNS propagation delay** | Discovered in A3, not in Phase 3. If the create path applies, Phase 3's estimate grows by up to 48 hours and its runbook documents the two-phase apply. |
| **Lambda has no `python3.14` runtime** | Not a blocker. Pin to the newest available and record the divergence from the container's 3.14. |
| **A toolchain upgrade disturbs other work on this machine** | `tfenv` and `pyenv` install shims that change what `terraform` and `python3` resolve to globally. Flagged before B1/B2 run so the choice is informed. |
| **`terraform providers schema -json` output is large** | Only the three relevant subtrees are extracted into the findings document, not the whole dump. |

---

## 10. What comes next

On completion, Phase 1 branches from `main` as `feat/Phase1_Application` and builds the FastAPI service test-first against DynamoDB Local. It depends on Phase 0 only for the skeleton and the Python version decision from B2.
