# Phase 3 — Terraform bootstrap and foundation: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-24
**Status:** Proposed, awaiting approval
**Branch:** `feat/Phase3_BootstrapFoundation`
**AWS cost incurred by this phase as planned:** **$0.** Every deliverable is written and verified locally against mocked providers. The applies that create the ~$1/month of real resources are handed to you as a runbook, not executed here — see §0.1 D1.
**Companion documents:**
[design research](../../2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 0 findings](../phase0/2026-08-04-phase-00-verification-findings.md) ·
[Phase 2 plan](../phase2/2026-08-12-phase-02-implementation-plan.md) ·
[naming and tagging convention](../../naming-and-tagging-convention.md)

**Goal:** Write the two Terraform layers that hold everything durable — the state backend, the DNS zone, the certificate, the registry, the artifact bucket, the alert topic and the GitHub connection — and prove them correct on this machine, without an AWS session, before a single resource is created.

**Architecture:** Two flat root modules. `infra/bootstrap` creates the S3 state bucket and keeps its own state on disk; `infra/foundation` stores its state in that bucket and creates the six durable resources every later layer reads through `terraform_remote_state`. Correctness is asserted by Terraform's native test framework with `mock_provider`, so the whole suite runs offline. A shell wrapper drives per-layer `terraform`, and a second script runs `fmt`, `tflint` and `checkov` from digest-pinned containers.

**Tech stack:** Terraform 1.15.7, AWS provider 6.61.0, tflint 0.60.0 with AWS ruleset 0.44.0, checkov 3.3.13 and skopeo 1.20.0 — the last three run from digest-pinned containers, installing nothing on the host.

---

## 0. Purpose and non-goals

Phase 3 is the first phase that can spend money, and the first whose mistakes are expensive to reverse: a bucket named wrongly is renamed by destroying it, and a cost allocation tag activated late loses data that cannot be recovered. Both are reasons to get the shape right before applying rather than after.

**This phase deliberately does not:**

- create any AWS resource, or make any AWS API call, in this session (D1)
- create the two CodePipelines — they live in `foundation` but arrive with Phases 7 and 8 (D2)
- create any IAM role — each of design §8.1's six roles lands in the phase whose resource requires it (D2)
- create the VPC, subnets, NAT or security groups — that is Phase 4
- change anything under `app/` — Phase 2's image is consumed here, not modified

### 0.1 Decisions taken before this plan was written

#### D1 — This session writes and verifies; you apply

Phase 3's exit criteria name live resources, and the SSO token on `bootcamp-administrator-access` had expired when work began. Rather than block, the phase splits: everything that can be built and proved without AWS is built and proved, and the applies become a runbook you execute.

**Consequences:**

- The verification story has to be real, not a promise. It is: `terraform init -backend=false`, `validate`, and a `terraform test` suite running against `mock_provider`, all of which work with no credentials and no bucket (F2, F3).
- The runbook in Task 9 is a deliverable of this phase, not documentation added afterwards. It carries the exact command sequence, the three manual steps, and what to do when each one goes wrong.
- **Phase 3's exit criteria are not met when this branch is written.** They are met when you run the runbook. The branch's own gate is the local one: fmt, validate, lint and test all green. This is stated plainly rather than left for the pull request to blur.

#### D2 — `foundation` gets the six durable resources and nothing else

Roadmap §1's layer diagram lists "both pipelines" and "shared IAM roles" in `foundation`; roadmap §3's Phase 3 task list does not. The task list is the one this plan follows.

**Consequences:**

- A role's policy cannot be scoped to resources that do not exist. A CodeBuild role written now would either be wildcarded — and then rewritten in Phase 7 anyway — or be a guess. Each role is created by the phase that creates the thing it acts on.
- The **CodeConnections link is still created here**, because it is not a role: it is free, it is the one resource in the project needing a human to click a console button, and Phase 7 cannot start until it is `AVAILABLE`. Creating it early converts a blocking manual step into a background one.
- `foundation` still *owns* the pipelines. Phases 7 and 8 add files to this layer; they do not create a new one.

#### D3 — `fmt`, `validate`, `tflint` and `checkov` all run locally, from containers

Roadmap §7 puts tflint and checkov in the Phase 7 pipeline's validate stage. Roadmap §2.1 requires pre-merge validation to run locally, because pull requests do not trigger the pipelines. Running the same four checks from the first line of HCL satisfies both.

**Consequences:**

- Both tools run from **digest-pinned containers**, the precedent Phase 2 §D3 set for syft. Nothing is installed on the host, `verify-tools.sh` gains no row, and the identical command works in Phase 7's CodeBuild.
- tflint's AWS ruleset is a plugin it downloads at `--init` time. The plugin cache is a mounted, gitignored directory (`infra/.tflint.d/`), so the download happens once rather than on every run (F5).
- checkov will report findings that are correct for a generic account and wrong for this project. Task 7 triages them into inline `#checkov:skip` comments **each carrying a reason**, and records the triage in the plan rather than silently suppressing them.

#### D4 — The state bucket is encrypted with SSE-S3, not KMS

**Consequences:**

- Every state read and write is a KMS API call under the alternative, on a bucket touched by every plan, every apply and every remote-state lookup in five layers. SSE-S3 is free and the bucket is already private to one account.
- checkov's `CKV_AWS_145` will flag this. It is skipped with this reason attached (Task 7).
- The same reasoning applies to the artifact bucket and the ECR repository, so all three use AES256 and the decision is made once.

#### D5 — The SNS topic is unencrypted, deliberately

**Consequences:**

- An AWS-managed key (`alias/aws/sns`) cannot have its key policy edited, and CloudWatch cannot publish to a topic encrypted with one. Phase 6's automatic-rollback alarms and Phase 9's failure alerts both publish from CloudWatch. Encrypting the topic with the managed key would break them, and doing it properly needs a customer-managed key with its own policy, rotation and monthly charge — for a topic whose payload is "a deployment failed".
- checkov's `CKV_AWS_26` is skipped with that reason.

#### D6 — ECR is seeded with skopeo, copying the OCI archive

**Consequences:**

- `skopeo copy oci-archive:app/dist/image.oci.tar docker://…` uploads the Phase 2 **artifact of record** byte-for-byte. The manifest digest ECR stores is the digest `app/dist/image-digest.txt` already names, so Phase 2 §F1's claim is carried through rather than re-argued.
- `docker push` of the daemon copy is rejected for the opposite reason: the daemon holds a re-imported convenience copy, and a push may re-encode it into a different digest. That would leave ECR holding an image whose digest matches nothing recorded anywhere.
- `scripts/seed-ecr.sh` **asserts** the digest ECR reports equals the recorded one, so the seed is verified rather than assumed.
- ECR tag immutability means a second seed of the same tag fails by design. The script detects an existing identical digest and reports success rather than erroring.

#### D7 — The provider pin moves to `~> 6.61`

Phase 0 recorded 6.57.1; the registry now resolves 6.61.0 (F1).

**Consequences:**

- `.terraform.lock.hcl` is committed for both layers, as `.gitignore` already promises.
- It is generated for **three platforms** — `darwin_arm64`, `linux_arm64`, `linux_amd64` — because Phase 8's CodeBuild runs `ARM_CONTAINER` (Phase 2 §D1) and a lock file written only on this Mac fails there with a missing-hash error that reads as a corrupt lock rather than a missing platform.

---

## 1. Findings recorded before this plan was written

Six probes were run on 2026-08-24 against real Terraform and real Docker. None touched AWS. Two changed the plan.

### F1 — The AWS provider resolves to 6.61.0, and every Phase 3 resource exists in it

```
$ terraform init            # required_providers { aws = "~> 6.4" }
- Installing hashicorp/aws v6.61.0...

$ terraform providers schema -json | jq …
data   aws_route53_zones                   yes
data   aws_route53_zone                    yes
resource aws_codeconnections_connection    yes
resource aws_codestarconnections_connection yes   (the superseded spelling, still present)
resource aws_acm_certificate_validation    yes
resource aws_ecr_repository                yes
resource aws_s3_bucket_versioning          yes

$ … .data_source_schemas.aws_route53_zones.block.attributes | keys[]
id
ids
```

**Consequences:** the pin moves to `~> 6.61` (D7); design §1.7's find-or-create is implementable exactly as written, since `aws_route53_zones` returns a plain `ids` list; and the connection resource uses the **`aws_codeconnections_connection`** spelling, not the older `aws_codestarconnections_connection`, which the provider keeps only for compatibility.

### F2 — `terraform init -backend=false` works with an S3 backend declared

The whole write-and-verify-without-AWS approach rests on this, so it was tested rather than assumed. A configuration with a full `backend "s3"` block, against no bucket and with no credentials:

```
$ terraform init -backend=false
Terraform has been successfully initialized!

$ terraform validate
Success! The configuration is valid.

$ terraform test
Success! 1 passed, 0 failed.
```

**Consequences:** `validate`, `test` and `fmt` need no AWS session at all. `scripts/tf.sh` therefore uses `-backend=false` for those three and a full `init` only for `plan`, `apply` and `destroy` — which is also what keeps `make tf-check` runnable on a machine that has never logged in.

### F3 — `terraform test` with `mock_provider` gives real assertions offline

```hcl
mock_provider "aws" {
  mock_data "aws_route53_zones" {
    defaults = { ids = ["Z01311493LQ7UOIRHM1H9"] }
  }
}
run "adopts_the_existing_zone" {
  command = plan
  assert {
    condition     = output.zone_was_created == false
    error_message = "expected the existing zone to be adopted, not created"
  }
}
```

**Consequences:** the test suite is Terraform-native rather than a shell script grepping plan output, and it runs in seconds with no network. Every assertion in this plan is written against `command = plan`; nothing in Phase 3's test suite ever calls `apply`.

**One honest limitation.** `mock_provider` mocks *every* data source in the layer, including `aws_iam_policy_document`. A rendered policy JSON under mock is a generated string, so no test asserts on policy contents — only on the resources' non-computed arguments. Policy correctness is verified by the runbook's apply, not by the suite.

### F4 — Design §1.7's find-or-create snippet aborts on a null

The snippet as published filters with `!z.private_zone`. Run under mock, it fails:

```
Error: Operation failed
  on main.tf line 17, in locals:
  17:   matched = [for z in data.aws_route53_zone.candidates : z.zone_id
                   if z.name == "${var.domain_name}." && !z.private_zone]
    │ z.private_zone is null
Error during operation: argument must not be null.
```

Changing the predicate to `z.private_zone != true` made the same test pass.

**Consequences:** this is not merely a mock artifact. The `for_each` reads **every hosted zone in the account**, and each one's attributes must survive the expression before the `name` filter can exclude it. A boolean that arrives null — from a zone this project did not create, or from a future provider that widens the type — takes down the whole layer's plan with an error naming a line that looks correct. `!= true` is null-safe, means the same thing for every non-null value, and costs nothing.

**Design §1.7 is amended in Task 9** rather than followed into a latent failure.

### F5 — tflint and checkov run from pinned containers, and tflint's plugin cache must be mounted

```
$ docker run --rm -v "$PWD:/data" -v "$PWD/.tflint.d:/plugins" -e TFLINT_PLUGIN_DIR=/plugins \
    ghcr.io/terraform-linters/tflint@sha256:cef18122… --init
Installing "aws" plugin...
Installed "aws" (source: github.com/terraform-linters/tflint-ruleset-aws, version: 0.44.0)

$ … --version
TFLint version 0.60.0
+ ruleset.aws (0.44.0)
+ ruleset.terraform (0.13.0-bundled)

$ docker run --rm bridgecrew/checkov@sha256:c5fb7154… --version
3.3.13
```

**Consequences:** the tflint image ships **no** rulesets — without the mounted `TFLINT_PLUGIN_DIR` the AWS ruleset is re-downloaded on every invocation, and on a network failure `--init` fails the whole lint run. The mount makes it a one-time cost. `infra/.tflint.d/` is gitignored.

Pinned digests, recorded 2026-08-24:

| Tool | Tag | Index digest |
|---|---|---|
| tflint | `ghcr.io/terraform-linters/tflint:v0.60.0` | `sha256:cef181224b4a9cea521d8f785d50957ea3215b449e2d97e7793f222e2808d188` |
| checkov | `bridgecrew/checkov:3.3.13` | `sha256:c5fb7154bed784fc19a69779c308fddba564f19a37c25d306c0e9765c4f0aa1d` |
| skopeo | `quay.io/skopeo/stable:v1.20.0` | `sha256:47853bb9fb24202af9110531ebd6e43c5f97701254ca290596640290d17942f4` |

All three indexes carry a `linux/arm64` manifest, so all three run natively on this machine.

### F6 — There are three irreducibly manual steps, not two

Roadmap §3 and `infra/foundation/README.md` both say two: the CodeConnections click and the cost allocation tag activation. The SNS email subscription is a third.

`aws_sns_topic_subscription` with `protocol = "email"` is created by AWS in `PendingConfirmation` state and stays there until the recipient clicks the link in the confirmation email. Terraform reports the resource as created, `terraform plan` stays clean indefinitely, and nothing ever errors.

**Consequence:** an unconfirmed subscription is a silent failure whose symptom does not appear until Phase 9, as alerts that are never delivered. Both documents are amended in Task 9, and the runbook lists it as a step with its own verification command:

```bash
aws sns list-subscriptions-by-topic --topic-arn <arn> \
  --query 'Subscriptions[].SubscriptionArn'
# "PendingConfirmation" — not an ARN — means the click has not happened
```

### F7 — `make` gives an environment `AWS_PROFILE` precedence over the project's

Found while capturing the verification evidence, not before the plan — recorded
here because it changes a file this phase did not otherwise touch.

The shell this phase was worked in exports `AWS_PROFILE=rose-non-prod`, a live
session on a different account. The makefile has read
`AWS_PROFILE ?= bootcamp-administrator-access` since Phase 0, and **GNU Make
gives an environment variable precedence over `?=`**, so the project default
never applied.

Harmless through Phase 2, because no target reached AWS. Not harmless from
`apply-%` onward.

**Consequences:** the three AWS variables move from `?=` to `:=`, which
overrides the environment while still yielding to `make AWS_PROFILE=other`. And
`allowed_account_ids` on both providers — written before this was found — is
what would have caught it anyway. Full detail in
[the verification record](./2026-08-24-local-verification.md#f7--make-gave-an-unrelated-aws-account-precedence-over-the-projects).

---

## 2. Global constraints

Every task's requirements implicitly include this section, in addition to the [naming and tagging convention](../../naming-and-tagging-convention.md), which is normative and not restated here.

- **No AWS API call is made by any step of this plan.** A step that needs credentials belongs in the runbook, not in a task.
- **Terraform `>= 1.10`** in every layer's `required_version`, because `use_lockfile` needs it (design §1.8). The repository pins 1.15.7 in `.terraform-version`.
- **AWS provider `~> 6.61`**, locked for `darwin_arm64`, `linux_arm64` and `linux_amd64` (D7).
- **Account and region are asserted by the provider, not by convention.** Every layer sets `allowed_account_ids = [var.account_id]`, which fails at plan time when the session points somewhere else. `590184028094` and `us-east-1` are variable defaults, never literals in a resource.
- **Backend blocks cannot interpolate.** `bucket`, `key` and `region` in a `backend "s3"` block are literal strings; a variable there is a parse error. The bucket name therefore appears literally in each layer's `versions.tf`, and the naming convention is what keeps the literal and the variable default in agreement.
- **All four tags come from `default_tags`**, set once per layer from `local.common_tags`. No resource repeats them.
- **`environment = "shared"`** in both layers. `bootstrap` and `foundation` are not environments.
- **TDD.** Every task writes its `.tftest.hcl` assertions first and watches them fail before the HCL that satisfies them exists. Test files are committed before implementation files where the two are separable (roadmap §2).
- **Nothing is committed and nothing is pushed by this branch's work.** Each task ends with a *proposed* commit — the message and the exact `git add` set — for you to run or decline.

### 2.1 Two things this phase must not accidentally break

**The `make help` contract.** The makefile's own docstring forbids stub targets: a command listed under "Available now" must run. The four `PLANNED:` lines this phase consumes (`plan-LAYER`, `apply-LAYER`, `seed-ecr`) are deleted in the same commit that makes them real, and any target added here that cannot yet run stays a `PLANNED:` line.

**`.PHONY` does not accept pattern rules.** The makefile says so in a note addressed to this phase. `plan-%` and `apply-%` therefore depend on an empty `FORCE` target instead, or they silently stop running the moment a file of that name appears.

---

## 3. File structure

```
infra/
  .tflint.hcl                    NEW — AWS ruleset declaration, shared by every layer
  .tflint.d/                     NEW — gitignored plugin cache
  bootstrap/
    versions.tf                  NEW — required_version, provider pin; no backend block
    providers.tf                 NEW — region, allowed_account_ids, default_tags
    variables.tf                 NEW — project_name, region, account_id, owner
    locals.tf                    NEW — name_prefix, common_tags, bucket_name
    main.tf                      NEW — the state bucket and its six configuration resources
    outputs.tf                   NEW — bucket name and ARN
    terraform.tfvars.example     NEW — the shape of an override file
    tests/
      state_bucket.tftest.hcl    NEW — naming, versioning, encryption, access, lifecycle
    README.md                    MODIFIED — how to recreate the local state
  foundation/
    versions.tf                  NEW — required_version, provider pin, backend "s3"
    providers.tf                 NEW
    variables.tf                 NEW
    locals.tf                    NEW — name_prefix, common_tags, the two API domains
    route53.tf                   NEW — find-or-create, null-safe (F4)
    acm.tf                       NEW — certificate, validation records, optional wait
    ecr.tf                       NEW — repository and lifecycle policy
    artifacts.tf                 NEW — the versioned artifact bucket
    sns.tf                       NEW — topic and email subscription
    codeconnections.tf           NEW — the GitHub connection, created PENDING
    outputs.tf                   NEW — the contract Phases 4-8 read
    terraform.tfvars.example     NEW
    tests/
      naming_and_tags.tftest.hcl        NEW — the convention, asserted
      zone_and_certificate.tftest.hcl   NEW — both zone paths, both cert names
      registry_and_artifacts.tftest.hcl NEW — ECR, bucket, SNS, connection
    README.md                    MODIFIED — three manual steps, not two
scripts/
  tf.sh                          NEW — per-layer terraform driver
  lint-infra.sh                  NEW — fmt, tflint, checkov from pinned containers
  seed-ecr.sh                    NEW — skopeo copy of the Phase 2 artifact, digest-verified
  README.md                      MODIFIED — the three new scripts
makefile                         MODIFIED — tf-* targets, plan-%, apply-%, seed-ecr,
                                 and ?= to := on the three AWS variables (F7)
.gitignore                       MODIFIED — infra/.tflint.d/
docs/
  runbooks/
    phase-03-bootstrap-and-foundation.md   NEW — the apply sequence and three manual steps
  phases/phase3/
    2026-08-24-phase-03-implementation-plan.md   this document
    2026-08-24-local-verification.md             NEW — Task 9's completion record
  2026-08-04-implementation-phase-roadmap.md     MODIFIED — F6
  2026-08-04-blue-green-deployment-platform-design-research.md   MODIFIED — F4
```

### 3.1 Why two flat root modules and an empty `modules/`

Nothing in Phase 3 is instantiated twice. A module with one caller hides the resources it wraps behind a variable-passing layer, which makes the first `terraform plan` of the project harder to read and the first `terraform import` harder to write — both of which happen in this phase. `infra/modules/` stays empty until Phase 4, where the network layer is the first thing two environments genuinely share.

### 3.2 Why `bootstrap` keeps its state on disk

A bucket cannot store the state that describes it before it exists. The alternatives are a two-step migration — apply locally, then move the state into the bucket it just created — or leaving it local. Local wins because the state describes exactly one resource whose name is fixed by convention, so recreating it is one `terraform import` and the README says the command. `infra/bootstrap/terraform.tfstate*` is already in `.gitignore`.

### 3.3 Why `prevent_destroy` is on the state bucket and not the artifact bucket

`infra/bootstrap/README.md` says the state bucket is never destroyed. `prevent_destroy = true` makes that enforceable rather than advisory: `terraform destroy` fails with an error naming the resource instead of taking every layer's state with it.

The artifact bucket does not get it. It is destroyed only by destroying `foundation`, which the Phase 10 teardown explicitly does not do — and a lifecycle flag that has to be commented out to complete a legitimate operation trains people to comment out lifecycle flags.

---

## Task 1: `bootstrap` — the state backend, test-first

The layer every other layer depends on, and the only one whose state is local.

**Files:**
- Create: `infra/bootstrap/tests/state_bucket.tftest.hcl`
- Create: `infra/bootstrap/versions.tf`, `providers.tf`, `variables.tf`, `locals.tf`, `main.tf`, `outputs.tf`, `terraform.tfvars.example`
- Create: `scripts/tf.sh`
- Modify: `makefile`

**Interfaces:**
- Produces: an S3 bucket named `bgd-us-east-1-tfstate-590184028094`; outputs `state_bucket_name` and `state_bucket_arn`; the `scripts/tf.sh <command> <layer>` driver every later task and the runbook use.

- [ ] **Step 1: Write `scripts/tf.sh`**

This comes first because nothing else in the task can be run without it.

```bash
#!/usr/bin/env bash
#
# Per-layer terraform driver.
#
#   scripts/tf.sh <fmt|validate|test|plan|apply|destroy|init> <layer> [args...]
#
# Layer names are the ones the runbook and roadmap use — bootstrap, foundation,
# network, staging, prod — not directory paths, so a caller never has to know
# that the environment layers live one level deeper than the others.
#
# The init mode matters. fmt, validate and test need no AWS session and no state
# bucket, so they init with -backend=false and work on a machine that has never
# logged in (Phase 3 §F2). plan, apply and destroy need the real backend.
# Terraform re-initialises cleanly when switching between the two.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform

ROOT="$(repo_root)"

command="${1:-}"
layer="${2:-}"
[[ -n "$command" && -n "$layer" ]] || die "usage: tf.sh <command> <layer> [args...]"
shift 2

# Mapped inline rather than by a helper function, deliberately. lib/common.sh's
# die() writes to stdout, so a helper that died inside "$(...)" would have its
# error message captured into the variable being assigned and the script would
# exit 1 in silence.
case "$layer" in
  bootstrap | foundation | network) dir="$ROOT/infra/$layer" ;;
  staging | prod) dir="$ROOT/infra/environments/$layer" ;;
  *) die "unknown layer: $layer (expected bootstrap, foundation, network, staging or prod)" ;;
esac

[[ -d "$dir" ]] || die "layer '$layer' has no directory yet: ${dir#"$ROOT"/}"

case "$command" in
  fmt | validate | test) init_args=(-backend=false) ;;
  *) init_args=() ;;
esac

info "terraform $command — $layer"
terraform -chdir="$dir" init -input=false ${init_args[@]+"${init_args[@]}"} >/dev/null
terraform -chdir="$dir" "$command" ${@+"$@"}
```

Note the `${arr[@]+"${arr[@]}"}` form in both places: macOS ships bash 3.2, where expanding an empty array under `set -u` is itself an unbound-variable error. `scripts/README.md` already records this.

Make it executable: `chmod +x scripts/tf.sh`

- [ ] **Step 2: Add the makefile targets this task needs**

Insert after the Phase 2 block, before the `PLANNED:` lines:

```make
# ---------------------------------------------------------------------------
# Phase 3 — Terraform
#
# fmt, validate and test need no AWS session: they init with -backend=false, so
# the whole gate runs on a machine that has never logged in. Only plan and apply
# reach the account. See docs/phases/phase3/…-implementation-plan.md §F2.
# ---------------------------------------------------------------------------

TF_LAYERS := bootstrap foundation

.PHONY: tf-test
tf-test: ## Run the Terraform test suites against mocked providers
	@for l in $(TF_LAYERS); do ./scripts/tf.sh test $$l; done
```

- [ ] **Step 3: Write the failing test**

`infra/bootstrap/tests/state_bucket.tftest.hcl`:

```hcl
# The state bucket's properties, asserted at plan time against a mocked provider.
#
# Every assertion here is something that fails silently rather than loudly.
# A bucket without versioning applies cleanly and holds one recoverable copy of
# the state; a bucket missing one of the four public-access flags applies cleanly
# and is public. Neither shows up in a plan review as anything but a short diff.

mock_provider "aws" {}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
}

run "bucket_name_follows_the_naming_convention" {
  command = plan

  assert {
    condition     = aws_s3_bucket.tfstate.bucket == "bgd-us-east-1-tfstate-590184028094"
    error_message = "state bucket name must be <project>-<region>-tfstate-<accountId> — S3 names are globally unique and immutable"
  }
}

run "versioning_is_enabled" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.tfstate.versioning_configuration[0].status == "Enabled"
    error_message = "versioning is the only recovery path for a corrupted or truncated state file"
  }
}

run "encryption_is_server_side_and_free" {
  command = plan

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.tfstate.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "SSE-S3, not KMS: every state read and write would otherwise be a billed KMS request (plan §D4)"
  }
}

run "the_bucket_is_closed_to_the_public_four_ways" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.tfstate.block_public_acls,
      aws_s3_bucket_public_access_block.tfstate.block_public_policy,
      aws_s3_bucket_public_access_block.tfstate.ignore_public_acls,
      aws_s3_bucket_public_access_block.tfstate.restrict_public_buckets,
    ])
    error_message = "all four public access block flags must be true — three of four leaves a hole"
  }
}

run "old_state_versions_expire_but_not_immediately" {
  command = plan

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.tfstate.rule).noncurrent_version_expiration).noncurrent_days == 90
    error_message = "noncurrent state versions must be retained long enough to recover from a bad apply nobody noticed"
  }
}
```

- [ ] **Step 4: Run it to verify it fails**

Run: `./scripts/tf.sh test bootstrap`
Expected: FAIL — the directory has no `.tf` files, so Terraform reports no configuration and every `run` errors on an unknown resource reference.

- [ ] **Step 5: Write `infra/bootstrap/versions.tf`**

```hcl
terraform {
  # >= 1.10 for the S3 backend's native lockfile support, which is what makes
  # the DynamoDB lock table older guides mandate unnecessary (design §1.8).
  # This layer does not use a backend itself — see README.md — but every layer
  # that stores state in the bucket it creates does.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
  }
}
```

- [ ] **Step 6: Write `infra/bootstrap/variables.tf`**

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

variable "region" {
  description = "AWS region. Also a name segment and a tag value, not only a provider setting."
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "Expected AWS account. Asserted by the provider, and the suffix that makes the globally-unique bucket name unique."
  type        = string
  default     = "590184028094"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be twelve digits."
  }
}

variable "owner" {
  description = "Value of the owner tag: who to contact, and who pays."
  type        = string
  default     = "carreque45@gmail.com"
}

variable "noncurrent_state_retention_days" {
  description = "How long superseded state versions are kept before expiry."
  type        = number
  default     = 90
}
```

- [ ] **Step 7: Write `infra/bootstrap/locals.tf`**

```hcl
locals {
  name_prefix = "${var.project_name}-${var.region}"

  # S3 bucket names are globally unique across every AWS account, so the
  # convention appends the account ID. See the naming convention, §4.
  bucket_name = "${local.name_prefix}-tfstate-${var.account_id}"

  common_tags = {
    environment = "shared"
    projectName = var.project_name
    region      = var.region
    owner       = var.owner
  }
}
```

- [ ] **Step 8: Write `infra/bootstrap/providers.tf`**

```hcl
provider "aws" {
  region = var.region

  # A hard stop, at plan time, when the session points at the wrong account.
  # Cheaper than discovering it from a bucket that appeared somewhere else.
  allowed_account_ids = [var.account_id]

  # The four tags of the naming and tagging convention, §5. Set once here so a
  # resource can add tags but never has to repeat these — which is what stops
  # the convention drifting into "documented but not applied".
  default_tags {
    tags = local.common_tags
  }
}
```

- [ ] **Step 9: Write `infra/bootstrap/main.tf`**

```hcl
# The bucket every other layer's state lives in.
#
# Seven resources rather than one: the modern AWS provider splits bucket
# configuration into separate resources, and a property that is simply absent
# is not an error — it is a default. That is why each one below has a test.

resource "aws_s3_bucket" "tfstate" {
  # Skips go INSIDE the resource block and are attributed to the resource
  # checkov names in its finding, which for every S3 rule is aws_s3_bucket
  # rather than the configuration resource that actually carries the setting.
  # A skip comment above the block is silently ignored — the run reports
  # "Skipped checks: 0" and the finding still fails. See §F7 of the
  # verification record for the full triage.
  # checkov:skip=CKV_AWS_145:SSE-S3 is deliberate. Every state read and write across five layers would otherwise be a billed KMS request, on a bucket already private to one account. Phase 3 plan §D4.
  # checkov:skip=CKV_AWS_144:Single-region project by design (design §5). The disaster model is "rebuild from code".
  # checkov:skip=CKV_AWS_18:Access logging needs a target bucket that needs a target bucket. CloudTrail records every configuration change; object-level reads are genuinely not logged, and that is accepted rather than argued away.
  # checkov:skip=CKV2_AWS_62:Nothing subscribes to S3 events. A notification with no consumer is configuration that does nothing but appear to.
  bucket = local.bucket_name

  # This bucket holds the state of every layer in the project. Losing it does
  # not lose the infrastructure, but it loses Terraform's knowledge of it, and
  # the recovery is importing every resource by hand. Never destroyed
  # (infra/bootstrap/README.md), and now enforceably so.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs are disabled outright rather than merely blocked. With BucketOwnerEnforced
# an ACL cannot be set at all, so there is no path by which a later apply, a
# console click or a CLI call re-introduces one.
resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-superseded-state-versions"
    status = "Enabled"

    # An empty filter means "every object". The provider requires filter or
    # prefix to be present; omitting both is a plan-time error.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_state_retention_days
    }

    # Native lockfile locking writes small .tflock objects. An interrupted
    # upload of any object otherwise accrues storage nobody can see.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Lifecycle rules referencing noncurrent versions are rejected on a bucket
  # where versioning has not yet been enabled, and the two resources have no
  # implicit dependency to order them.
  depends_on = [aws_s3_bucket_versioning.tfstate]
}

# Terraform sends state over TLS, but nothing stops something else from not
# doing so. A bucket policy is the only place that can be refused outright.
data "aws_iam_policy_document" "tfstate" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate.json

  # The policy denies non-TLS access to everyone including the account root.
  # Applying it before public access is blocked would briefly present a bucket
  # with a wildcard principal policy, which is exactly what block_public_policy
  # exists to refuse.
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}
```

- [ ] **Step 10: Write `infra/bootstrap/outputs.tf`**

```hcl
output "state_bucket_name" {
  description = "Name of the state bucket. The literal every other layer's backend block repeats."
  value       = aws_s3_bucket.tfstate.bucket
}

output "state_bucket_arn" {
  description = "ARN of the state bucket, for the IAM policies later phases attach to the pipelines."
  value       = aws_s3_bucket.tfstate.arn
}
```

- [ ] **Step 11: Write `infra/bootstrap/terraform.tfvars.example`**

```hcl
# Every variable in this layer has a default that is correct for the project's
# one account. This file exists to document the shape of an override, not
# because an override is needed.
#
#   cp terraform.tfvars.example terraform.tfvars
#
# terraform.tfvars is gitignored: variable files may carry account IDs and ARNs.

# project_name = "bgd"
# region       = "us-east-1"
# account_id   = "590184028094"
# owner        = "carreque45@gmail.com"
```

- [ ] **Step 12: Run the test suite to verify it passes**

Run: `./scripts/tf.sh test bootstrap`
Expected: PASS — `Success! 5 passed, 0 failed.`

- [ ] **Step 13: Verify formatting and validity**

Run: `terraform -chdir=infra/bootstrap fmt -check -diff && ./scripts/tf.sh validate bootstrap`
Expected: no diff, and `Success! The configuration is valid.`

- [ ] **Step 14: Generate the multi-platform provider lock**

Run:
```bash
terraform -chdir=infra/bootstrap providers lock \
  -platform=darwin_arm64 -platform=linux_arm64 -platform=linux_amd64
```
Expected: `.terraform.lock.hcl` written, containing three `h1:` hash sets for `hashicorp/aws`. Confirm with `grep -c 'h1:' infra/bootstrap/.terraform.lock.hcl`.

- [ ] **Step 15: Proposed commit** *(not executed — roadmap §2)*

```bash
git add infra/bootstrap/tests scripts/tf.sh makefile
git commit -m "test(infra): assert the state bucket's properties before it exists"

git add infra/bootstrap
git commit -m "feat(infra): create the Terraform state backend"
```

---

## Task 2: `foundation` — the layer skeleton and the tagging contract

No AWS resource yet. This task establishes the backend wiring, the variables every later task reads, and the one assertion that protects a decision no later phase can undo.

**Files:**
- Create: `infra/foundation/tests/naming_and_tags.tftest.hcl`
- Create: `infra/foundation/versions.tf`, `providers.tf`, `variables.tf`, `locals.tf`, `outputs.tf`, `terraform.tfvars.example`
- Modify: `makefile`

**Interfaces:**
- Consumes: the bucket name Task 1 produces, as a literal in the backend block.
- Produces: `local.name_prefix`, `local.common_tags`, `local.api_domain`, `local.staging_api_domain`; outputs `name_prefix` and `common_tags`, which Phases 4-6 read through `terraform_remote_state` so every layer tags identically.

- [ ] **Step 1: Write the failing test**

`infra/foundation/tests/naming_and_tags.tftest.hcl`:

```hcl
# The tagging convention, asserted.
#
# Tag keys are case-sensitive and a misspelling is not an error: `Environment`
# and `environment` are two different tags, both apply cleanly, and the result
# is every future cost report silently split in two. Worse, cost allocation tag
# activation is not retroactive (naming convention §6.2), so the data lost
# between the mistake and its discovery never comes back.
#
# This is the one thing in Phase 3 that a plan review genuinely cannot catch,
# which is why it is a test.

mock_provider "aws" {}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
  domain_name  = "carloscloudengineer.com"
}

run "the_four_tag_keys_are_spelled_exactly_as_the_convention_requires" {
  command = plan

  assert {
    condition     = toset(keys(output.common_tags)) == toset(["environment", "owner", "projectName", "region"])
    error_message = "tag keys must be exactly environment, owner, projectName, region — case-sensitive, no extras, no omissions"
  }
}

run "shared_layers_tag_themselves_shared" {
  command = plan

  assert {
    condition     = output.common_tags["environment"] == "shared"
    error_message = "foundation is not an environment; it is used by both, so environment=shared"
  }
}

run "the_name_prefix_leaves_room_for_the_longest_alb_name" {
  command = plan

  assert {
    condition     = length("${output.name_prefix}-prod-api-blue") <= 32
    error_message = "ALB and target group names are capped at 32 characters and the cap is enforced at apply time"
  }
}

run "both_api_domains_derive_from_one_variable" {
  command = plan

  assert {
    condition     = output.api_domain == "api.carloscloudengineer.com"
    error_message = "production API hostname must be api.<domain_name>"
  }

  assert {
    condition     = output.staging_api_domain == "staging-api.carloscloudengineer.com"
    error_message = "staging API hostname must be staging-api.<domain_name>"
  }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/tf.sh test foundation`
Expected: FAIL — no configuration in the directory.

- [ ] **Step 3: Write `infra/foundation/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
  }

  # A backend block cannot interpolate: variables, locals and functions are all
  # parse errors here, so the bucket name Task 1's convention produces appears
  # as a literal. The naming convention is what keeps this string and
  # var.account_id's default in agreement; nothing mechanical can.
  #
  # use_lockfile is native S3 locking, available from Terraform 1.10 and the
  # reason this project has no DynamoDB lock table (design §1.8).
  backend "s3" {
    bucket       = "bgd-us-east-1-tfstate-590184028094"
    key          = "foundation/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

- [ ] **Step 4: Write `infra/foundation/variables.tf`**

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

variable "region" {
  description = "AWS region. Also a name segment and a tag value, not only a provider setting."
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "Expected AWS account. Asserted by the provider, and the suffix that makes globally-unique bucket names unique."
  type        = string
  default     = "590184028094"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be twelve digits."
  }
}

variable "owner" {
  description = "Value of the owner tag: who to contact, and who pays."
  type        = string
  default     = "carreque45@gmail.com"
}

variable "domain_name" {
  description = "Registered apex domain. Both API hostnames derive from it."
  type        = string
  default     = "carloscloudengineer.com"
}

variable "wait_for_validation" {
  description = <<-EOT
    Whether to block the apply until the ACM certificate is issued.

    True is correct here: Phase 0 confirmed the hosted zone already exists and is
    correctly delegated, so the validation CNAME resolves publicly within minutes.
    Set false only on the zone-create path, where the registrar's name servers do
    not yet point at the new zone and the wait would hang for its 75-minute
    default timeout before failing (design §1.7).
  EOT
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Address subscribed to the alert topic. Requires a manual confirmation click; see the Phase 3 runbook."
  type        = string
  default     = "carreque45@gmail.com"
}

variable "ecr_max_image_count" {
  description = "How many images the registry retains before the lifecycle policy expires the oldest."
  type        = number
  default     = 10
}

variable "noncurrent_artifact_retention_days" {
  description = "How long superseded artifact-bucket object versions are kept."
  type        = number
  default     = 90
}
```

- [ ] **Step 5: Write `infra/foundation/locals.tf`**

```hcl
locals {
  name_prefix = "${var.project_name}-${var.region}"

  api_domain         = "api.${var.domain_name}"
  staging_api_domain = "staging-api.${var.domain_name}"

  common_tags = {
    environment = "shared"
    projectName = var.project_name
    region      = var.region
    owner       = var.owner
  }
}
```

- [ ] **Step 6: Write `infra/foundation/providers.tf`**

Identical in shape to `infra/bootstrap/providers.tf`. Repeated rather than shared: a two-layer `provider` block is not a module's worth of abstraction, and each root module owning its own provider configuration is what lets a later layer diverge — Phase 4 will need a second, `us-east-1`-pinned alias if a CloudFront-style resource ever appears.

```hcl
provider "aws" {
  region = var.region

  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.common_tags
  }
}
```

- [ ] **Step 7: Write `infra/foundation/outputs.tf`**

Only the four this task can satisfy. Later tasks in this phase append to the file.

```hcl
output "name_prefix" {
  description = "The <project>-<region> prefix every resource name in every layer starts with."
  value       = local.name_prefix
}

output "common_tags" {
  description = "The four convention tags. Later layers read this so a tag key can only be spelled once."
  value       = local.common_tags
}

output "api_domain" {
  description = "Production API hostname."
  value       = local.api_domain
}

output "staging_api_domain" {
  description = "Staging API hostname."
  value       = local.staging_api_domain
}
```

- [ ] **Step 8: Write `infra/foundation/terraform.tfvars.example`**

```hcl
# Every variable has a default correct for this project. This file documents
# the shape of an override; terraform.tfvars itself is gitignored.
#
# The one worth knowing about:
#
#   wait_for_validation = false
#
# Set it only if the hosted zone had to be created rather than adopted, in which
# case the registrar's name servers must be repointed before a second apply with
# it back at true. Phase 0 confirmed the adopt path, so this should stay unset.
```

- [ ] **Step 9: Extend the makefile with the rest of the Phase 3 targets**

Replace the `TF_LAYERS` block from Task 1 Step 2 with the full set, and delete the three `PLANNED:` lines this task makes real (`plan-LAYER`, `apply-LAYER`, `seed-ecr` stays until Task 8).

```make
TF_LAYERS := bootstrap foundation

.PHONY: tf-fmt
tf-fmt: ## Format every Terraform file in place
	@terraform fmt -recursive infra

.PHONY: tf-validate
tf-validate: ## Validate every Terraform layer (no AWS session needed)
	@for l in $(TF_LAYERS); do ./scripts/tf.sh validate $$l; done

.PHONY: tf-test
tf-test: ## Run the Terraform test suites against mocked providers
	@for l in $(TF_LAYERS); do ./scripts/tf.sh test $$l; done

# Pattern rules cannot be declared .PHONY, so they depend on an always-missing
# target instead. Without FORCE, `make plan-foundation` would silently stop
# running the day a file named plan-foundation appears — reporting success.
FORCE:

plan-%: FORCE ## terraform plan for one layer (needs an AWS session)
	@./scripts/tf.sh plan $*

apply-%: FORCE ## terraform apply for one layer (needs an AWS session)
	@./scripts/tf.sh apply $*
```

Note: `make help` greps for `^[a-zA-Z0-9_-]+:.*?## `, which matches `plan-%` — the `%` is not in the character class, so the pattern rules will **not** appear in the help output. Add them to the help footer as a literal instead, replacing the two `PLANNED:` lines:

```make
# PLANNED: seed-ecr       Push the first real image to ECR (Phase 3)
```

and add above the `PLANNED` section, in the `help` recipe, after the "Available now" grep:

```make
	@printf '    \033[36m%-14s\033[0m %s\n' 'plan-LAYER' 'terraform plan for one layer'
	@printf '    \033[36m%-14s\033[0m %s\n' 'apply-LAYER' 'terraform apply for one layer'
```

- [ ] **Step 10: Run the test suite to verify it passes**

Run: `./scripts/tf.sh test foundation`
Expected: PASS — `Success! 4 passed, 0 failed.`

- [ ] **Step 11: Verify `make help` still tells the truth**

Run: `make help`
Expected: `tf-fmt`, `tf-validate`, `tf-test`, `plan-LAYER` and `apply-LAYER` under "Available now"; `seed-ecr` still under "Planned"; no target listed that does not run.

- [ ] **Step 12: Proposed commit** *(not executed)*

```bash
git add infra/foundation/tests
git commit -m "test(infra): assert the tagging convention before any resource carries it"

git add infra/foundation makefile
git commit -m "feat(infra): wire the foundation layer to the state backend"
```

---

## Task 3: Zone adoption and the ACM certificate

The two resources with the most ways to go subtly wrong: one reads every hosted zone in the account, the other blocks the apply for as long as DNS takes.

**Files:**
- Create: `infra/foundation/tests/zone_and_certificate.tftest.hcl`
- Create: `infra/foundation/route53.tf`, `infra/foundation/acm.tf`
- Modify: `infra/foundation/outputs.tf`

**Interfaces:**
- Consumes: `local.api_domain`, `local.staging_api_domain`, `var.domain_name`, `var.wait_for_validation`.
- Produces: `local.zone_id`; outputs `zone_id`, `zone_was_created`, `certificate_arn`.

- [ ] **Step 1: Write the failing test**

`infra/foundation/tests/zone_and_certificate.tftest.hcl`:

```hcl
# Both paths through find-or-create, and the certificate's two names.
#
# The adopt path is the one Phase 0 proved is real. The create path is tested
# anyway, because it is the path a fresh account takes and the one nobody will
# exercise before needing it to work.

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
  domain_name  = "carloscloudengineer.com"
}

# The account already holds the zone, delegated by the Route 53 registrar.
mock_provider "aws" {
  alias = "zone_present"

  mock_data "aws_route53_zones" {
    defaults = { ids = ["Z01311493LQ7UOIRHM1H9"] }
  }

  mock_data "aws_route53_zone" {
    defaults = {
      zone_id      = "Z01311493LQ7UOIRHM1H9"
      name         = "carloscloudengineer.com."
      private_zone = false
    }
  }
}

# A fresh account: no zones at all.
mock_provider "aws" {
  alias = "zone_absent"

  mock_data "aws_route53_zones" {
    defaults = { ids = [] }
  }
}

run "adopts_the_zone_the_registrar_created" {
  command = plan

  providers = {
    aws = aws.zone_present
  }

  assert {
    condition     = output.zone_was_created == false
    error_message = "the existing zone must be adopted; creating a second zone for the same domain breaks delegation"
  }

  assert {
    condition     = output.zone_id == "Z01311493LQ7UOIRHM1H9"
    error_message = "the adopted zone must be the one the registrar delegated to"
  }
}

run "creates_a_zone_when_the_account_has_none" {
  command = plan

  providers = {
    aws = aws.zone_absent
  }

  assert {
    condition     = output.zone_was_created == true
    error_message = "with no matching zone the layer must create one rather than fail"
  }
}

run "the_certificate_covers_both_environments" {
  command = plan

  providers = {
    aws = aws.zone_present
  }

  assert {
    condition     = aws_acm_certificate.api.domain_name == "api.carloscloudengineer.com"
    error_message = "the certificate's primary name must be the production hostname"
  }

  assert {
    condition     = aws_acm_certificate.api.subject_alternative_names == toset(["staging-api.carloscloudengineer.com"])
    error_message = "one certificate covers both environments; a second certificate is a second thing to renew"
  }

  assert {
    condition     = aws_acm_certificate.api.validation_method == "DNS"
    error_message = "DNS validation renews automatically; email validation does not"
  }
}

run "one_validation_record_per_name" {
  command = plan

  providers = {
    aws = aws.zone_present
  }

  assert {
    condition     = length(aws_route53_record.certificate_validation) == 2
    error_message = "each name on the certificate needs its own validation record, or issuance never completes"
  }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/tf.sh test foundation`
Expected: the four `naming_and_tags` runs pass; every run in `zone_and_certificate` fails on unknown resources.

- [ ] **Step 3: Write `infra/foundation/route53.tf`**

```hcl
# Find-or-create, per design §1.7.
#
# The singular aws_route53_zone data source errors at plan time when nothing
# matches, so "look it up, else create it" cannot be written with it. The plural
# aws_route53_zones takes no arguments and returns a plain list of ids, empty
# when the account has none — and because data sources resolve during plan, the
# for_each below receives known values.

data "aws_route53_zones" "all" {}

data "aws_route53_zone" "candidates" {
  for_each = toset(data.aws_route53_zones.all.ids)
  zone_id  = each.value
}

locals {
  # `private_zone != true` rather than `!private_zone`, deliberately. This reads
  # every hosted zone in the account, and each one's attributes must survive the
  # expression before the name filter can exclude it. A null boolean — from a
  # zone this project did not create, or a provider that widens the type — makes
  # the negation abort the whole plan with "argument must not be null", on a line
  # that looks correct. See the Phase 3 plan §F4.
  matched_zone_ids = [
    for zone in data.aws_route53_zone.candidates : zone.zone_id
    if zone.name == "${var.domain_name}." && zone.private_zone != true
  ]

  zone_exists = length(local.matched_zone_ids) > 0
  zone_id     = local.zone_exists ? local.matched_zone_ids[0] : aws_route53_zone.this[0].zone_id
}

resource "aws_route53_zone" "this" {
  count = local.zone_exists ? 0 : 1

  name    = var.domain_name
  comment = "Managed by Terraform — ${local.name_prefix}"
}
```

- [ ] **Step 4: Write `infra/foundation/acm.tf`**

```hcl
# One certificate covering both environments' hostnames, DNS-validated in the
# zone above. It lives in foundation rather than beside the load balancers
# because it must survive a teardown: re-issuing on every rebuild would make
# the certificate a rebuild cost and put it in the critical path of Phase 10.

resource "aws_acm_certificate" "api" {
  domain_name               = local.api_domain
  subject_alternative_names = [local.staging_api_domain]
  validation_method         = "DNS"

  # A certificate is replaced, not updated, when its names change. Without this
  # the old one is destroyed first — and it is still attached to two live ALB
  # listeners at that moment.
  lifecycle {
    create_before_destroy = true
  }
}

# for_each over the certificate's own domain_validation_options would be the
# obvious form, but that attribute is unknown until the certificate exists, and
# an unknown for_each is a plan-time error. Keying on the two hostnames — which
# are known from variables — lets the plan expand, with the record values filled
# in during apply.
resource "aws_route53_record" "certificate_validation" {
  for_each = toset([local.api_domain, local.staging_api_domain])

  zone_id = local.zone_id
  ttl     = 60

  name = one([
    for option in aws_acm_certificate.api.domain_validation_options :
    option.resource_record_name if option.domain_name == each.value
  ])

  type = one([
    for option in aws_acm_certificate.api.domain_validation_options :
    option.resource_record_type if option.domain_name == each.value
  ])

  records = [
    one([
      for option in aws_acm_certificate.api.domain_validation_options :
      option.resource_record_value if option.domain_name == each.value
    ])
  ]

  # ACM reuses a validation CNAME across certificates for the same name, so a
  # re-issue can produce a record that already exists. Without this, that is a
  # hard failure on a record whose value is identical to the one being written.
  allow_overwrite = true
}

# Not a resource in AWS — a wait. It blocks the apply until ACM reports the
# certificate ISSUED, so no later phase can attach a listener to a certificate
# that is still PENDING_VALIDATION.
#
# Gated on wait_for_validation because on the zone-create path the validation
# CNAME is not publicly resolvable until the registrar's name servers are
# repointed, and this would hang for its 75-minute default before failing.
resource "aws_acm_certificate_validation" "api" {
  count = var.wait_for_validation ? 1 : 0

  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]
}
```

- [ ] **Step 5: Append to `infra/foundation/outputs.tf`**

```hcl
output "zone_id" {
  description = "Hosted zone id, whether adopted or created. Phases 5 and 6 write their A records into it."
  value       = local.zone_id
}

output "zone_was_created" {
  description = "False when the registrar's zone was adopted. True means the registrar's name servers still need repointing."
  value       = !local.zone_exists
}

output "certificate_arn" {
  description = "ARN of the ACM certificate both environments' HTTPS listeners reference."
  value       = aws_acm_certificate.api.arn
}
```

- [ ] **Step 6: Run the test suite to verify it passes**

Run: `./scripts/tf.sh test foundation`
Expected: PASS — `Success! 8 passed, 0 failed.`

- [ ] **Step 7: Proposed commit** *(not executed)*

```bash
git add infra/foundation/tests/zone_and_certificate.tftest.hcl
git commit -m "test(infra): assert both find-or-create paths and the certificate's names"

git add infra/foundation/route53.tf infra/foundation/acm.tf infra/foundation/outputs.tf
git commit -m "feat(infra): adopt the hosted zone and issue the API certificate"
```

---

## Task 4: The registry, the artifact bucket, the alert topic and the connection

Four independent resources, one test file. They are grouped because none of them has enough behaviour to justify its own task, and all four are read by later phases through the same outputs block.

**Files:**
- Create: `infra/foundation/tests/registry_and_artifacts.tftest.hcl`
- Create: `infra/foundation/ecr.tf`, `artifacts.tf`, `sns.tf`, `codeconnections.tf`
- Modify: `infra/foundation/outputs.tf`

**Interfaces:**
- Consumes: `local.name_prefix`, `local.common_tags`, `var.account_id`, `var.ecr_max_image_count`, `var.alert_email`.
- Produces: outputs `ecr_repository_url`, `ecr_repository_arn`, `artifact_bucket_name`, `artifact_bucket_arn`, `alerts_topic_arn`, `github_connection_arn`.

- [ ] **Step 1: Write the failing test**

`infra/foundation/tests/registry_and_artifacts.tftest.hcl`:

```hcl
# ECR, the artifact bucket, the alert topic and the GitHub connection.
#
# The ECR assertions are the load-bearing ones. Tag immutability is what makes
# a deployed tag mean one image forever — without it, redeploying "the same"
# tag can quietly ship different bytes, which would make the blue/green
# evidence in Phase 11 worthless.

mock_provider "aws" {}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
  domain_name  = "carloscloudengineer.com"
}

run "the_registry_name_matches_the_image_phase_2_builds" {
  command = plan

  assert {
    condition     = aws_ecr_repository.api.name == "bgd-us-east-1-api"
    error_message = "the repository name must equal the image name build-image.sh produces, or seeding is a retag rather than a push"
  }
}

run "tags_in_the_registry_are_immutable_and_scanned" {
  command = plan

  assert {
    condition     = aws_ecr_repository.api.image_tag_mutability == "IMMUTABLE"
    error_message = "a mutable tag can point at different bytes over time, which makes every deployment record ambiguous"
  }

  assert {
    condition     = one(aws_ecr_repository.api.image_scanning_configuration).scan_on_push
    error_message = "scan on push is the only scan that happens without something else remembering to ask for one"
  }
}

run "the_registry_does_not_grow_without_bound" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_ecr_lifecycle_policy.api.policy).rules) == 2
    error_message = "expected two lifecycle rules: expire untagged, then cap the retained count"
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.api.policy).rules[1].selection.countNumber == 10
    error_message = "the retained image count must come from var.ecr_max_image_count"
  }
}

run "the_artifact_bucket_is_versioned_and_private" {
  command = plan

  assert {
    condition     = aws_s3_bucket.artifacts.bucket == "bgd-us-east-1-artifacts-590184028094"
    error_message = "artifact bucket name must be <project>-<region>-artifacts-<accountId>"
  }

  assert {
    condition     = aws_s3_bucket_versioning.artifacts.versioning_configuration[0].status == "Enabled"
    error_message = "design §4.2 requires versioning: build history is the point of this bucket"
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.artifacts.block_public_acls,
      aws_s3_bucket_public_access_block.artifacts.block_public_policy,
      aws_s3_bucket_public_access_block.artifacts.ignore_public_acls,
      aws_s3_bucket_public_access_block.artifacts.restrict_public_buckets,
    ])
    error_message = "test reports and SBOMs describe the application's dependencies; this bucket is not public"
  }
}

run "alerts_go_to_a_named_topic_by_email" {
  command = plan

  assert {
    condition     = aws_sns_topic.alerts.name == "bgd-us-east-1-alerts"
    error_message = "topic name must follow <project>-<region>-<purpose>"
  }

  assert {
    condition     = aws_sns_topic_subscription.alerts_email.protocol == "email"
    error_message = "the subscription protocol must be email"
  }

  assert {
    condition     = aws_sns_topic_subscription.alerts_email.endpoint == "carreque45@gmail.com"
    error_message = "the subscription endpoint must be the owner address"
  }
}

run "the_github_connection_is_a_github_connection" {
  command = plan

  assert {
    condition     = aws_codeconnections_connection.github.provider_type == "GitHub"
    error_message = "CodeCommit is closed to new customers (design §1.1); the source is GitHub"
  }

  assert {
    condition     = length(aws_codeconnections_connection.github.name) <= 32
    error_message = "CodeConnections names are capped at 32 characters"
  }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/tf.sh test foundation`
Expected: the eight earlier runs pass; the seven new ones fail on unknown resources.

- [ ] **Step 3: Write `infra/foundation/ecr.tf`**

```hcl
# The registry Phase 3 seeds and Phase 8 pushes to.
#
# The repository name is deliberately identical to the image name
# scripts/build-image.sh produces (Phase 2 §D5), so seeding is a push of the
# artifact of record rather than a retag of a copy.

resource "aws_ecr_repository" "api" {
  # checkov:skip=CKV_AWS_136:AES256 rather than KMS, for the reason recorded in §D4. Every ECS task start pulls layers from here; KMS would bill a decrypt request per layer per task.
  name = "${local.name_prefix}-api"

  # A mutable tag can be moved to different bytes later. Every deployment record,
  # every /version response and every rollback in Phase 11 would then name a tag
  # that no longer identifies what actually ran.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  # Order matters: rules are evaluated by ascending priority and an image is
  # acted on by the first rule that selects it. Untagged images are cleared
  # first so they do not occupy slots in the count-based rule below.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after one day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Retain the ${var.ecr_max_image_count} most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_max_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
```

- [ ] **Step 4: Write `infra/foundation/artifacts.tf`**

```hcl
# Build outputs, test reports and SBOMs (design §4.2).
#
# Versioned, because the point of the bucket is history: an SBOM for the image
# running in production three deployments ago is only available if the object
# that described it was not overwritten.
#
# No prevent_destroy, unlike the state bucket. This one is destroyed only by
# destroying foundation, which the Phase 10 teardown does not do — and a
# lifecycle flag that must be commented out to complete a legitimate operation
# teaches people to comment out lifecycle flags.

resource "aws_s3_bucket" "artifacts" {
  bucket = "${local.name_prefix}-artifacts-${var.account_id}"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-superseded-artifact-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_artifact_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.artifacts]
}
```

- [ ] **Step 5: Write `infra/foundation/sns.tf`**

```hcl
# One topic for every alert the project raises: pipeline failure, deployment
# failure and rollback (design §8).
#
# Unencrypted, deliberately. An AWS-managed key's policy cannot be edited, and
# CloudWatch cannot publish to a topic encrypted with one — which would break
# Phase 6's automatic-rollback alarms and Phase 9's failure alerts. Doing it
# properly needs a customer-managed key with its own policy, rotation and
# monthly charge, for a payload that says "a deployment failed".
# See the Phase 3 plan §D5.

resource "aws_sns_topic" "alerts" {
  # checkov:skip=CKV_AWS_26:Encrypting with the AWS-managed key breaks CloudWatch publishing, because that key's policy cannot be edited to allow it. §D5.
  name = "${local.name_prefix}-alerts"
}

# Created in PendingConfirmation state. AWS emails a confirmation link and the
# subscription does nothing until it is clicked — Terraform reports success,
# plan stays clean, and no error is ever raised. This is the third of the
# project's three manual steps; the Phase 3 runbook has the verification command.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
```

- [ ] **Step 6: Write `infra/foundation/codeconnections.tf`**

```hcl
# The link CodePipeline uses to read carreque/bluegreenDeployment.
#
# Created here rather than in Phase 7 because it is the one resource in the
# project that a human must finish. Terraform creates it PENDING; authorising it
# is a click in the console, and until that happens every pipeline sourcing from
# it fails. Creating it three phases early turns a blocking step into a
# background one.
#
# aws_codeconnections_connection, not aws_codestarconnections_connection: the
# service was renamed and the provider keeps the old spelling only for
# compatibility (Phase 3 plan §F1).
resource "aws_codeconnections_connection" "github" {
  name          = "${local.name_prefix}-github"
  provider_type = "GitHub"
}
```

- [ ] **Step 7: Append to `infra/foundation/outputs.tf`**

```hcl
output "ecr_repository_url" {
  description = "Registry URL the ECS task definitions pull from and the seed script pushes to."
  value       = aws_ecr_repository.api.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the registry, for the task execution role's pull policy in Phases 5 and 6."
  value       = aws_ecr_repository.api.arn
}

output "artifact_bucket_name" {
  description = "Versioned bucket for build outputs, test reports and SBOMs."
  value       = aws_s3_bucket.artifacts.bucket
}

output "artifact_bucket_arn" {
  description = "ARN of the artifact bucket, for the CodeBuild role's write policy in Phase 8."
  value       = aws_s3_bucket.artifacts.arn
}

output "alerts_topic_arn" {
  description = "Topic every alarm and pipeline failure notification publishes to."
  value       = aws_sns_topic.alerts.arn
}

output "github_connection_arn" {
  description = "CodeConnections ARN. Both pipelines source through it; unusable until authorised in the console."
  value       = aws_codeconnections_connection.github.arn
}
```

- [ ] **Step 8: Run the test suite to verify it passes**

Run: `./scripts/tf.sh test foundation`
Expected: PASS — `Success! 14 passed, 0 failed.`

- [ ] **Step 9: Verify the whole local gate**

Run: `make tf-fmt && make tf-validate && make tf-test`
Expected: no formatting diff, both layers valid, 19 assertions passing across both suites.

- [ ] **Step 10: Proposed commit** *(not executed)*

```bash
git add infra/foundation/tests/registry_and_artifacts.tftest.hcl
git commit -m "test(infra): assert registry immutability, artifact versioning and the alert path"

git add infra/foundation/ecr.tf infra/foundation/artifacts.tf \
        infra/foundation/sns.tf infra/foundation/codeconnections.tf \
        infra/foundation/outputs.tf
git commit -m "feat(infra): create the registry, artifact bucket, alert topic and GitHub connection"
```

---

## Task 5: Static analysis

`terraform validate` checks that the configuration parses and that types line up. It has no opinion about whether a bucket should be logged or a policy is too broad. tflint and checkov do.

**Files:**
- Create: `infra/.tflint.hcl`, `scripts/lint-infra.sh`
- Modify: `makefile`, `.gitignore`
- Modify (expected): the layer files, wherever a real finding is fixed rather than skipped

**Interfaces:**
- Produces: `make tf-lint`, and `make tf-check` as the single pre-merge gate.

- [ ] **Step 1: Write `infra/.tflint.hcl`**

```hcl
# Shared by every layer. tflint is invoked with --chdir per layer, and finds
# this file by walking upward.

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

- [ ] **Step 2: Add the plugin cache to `.gitignore`**

Under the Terraform section:

```gitignore
# tflint's AWS ruleset, downloaded once into a mounted cache rather than on
# every lint run. Regenerated by `make tf-lint`.
infra/.tflint.d/
```

- [ ] **Step 3: Write `scripts/lint-infra.sh`**

```bash
#!/usr/bin/env bash
#
# Static analysis for infra/, from digest-pinned containers.
#
# Nothing is installed on the host — the precedent generate-sbom.sh set for
# syft, for the same three reasons: there is no version for verify-tools.sh to
# drift against, the pin is a digest like every other dependency here, and the
# identical command works in Phase 7's CodeBuild.
#
# Pinned 2026-08-24. Re-record with:
#   docker buildx imagetools inspect <tag> --format '{{.Manifest.Digest}}'
#
#   tflint   ghcr.io/terraform-linters/tflint:v0.60.0
#   checkov  bridgecrew/checkov:3.3.13

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker

ROOT="$(repo_root)"
INFRA="$ROOT/infra"
PLUGINS="$INFRA/.tflint.d"

TFLINT="ghcr.io/terraform-linters/tflint@sha256:cef181224b4a9cea521d8f785d50957ea3215b449e2d97e7793f222e2808d188"
CHECKOV="bridgecrew/checkov@sha256:c5fb7154bed784fc19a69779c308fddba564f19a37c25d306c0e9765c4f0aa1d"

LAYERS=(bootstrap foundation)

mkdir -p "$PLUGINS"

tflint_run() {
  docker run --rm \
    --volume "$INFRA:/data" \
    --volume "$PLUGINS:/plugins" \
    --env TFLINT_PLUGIN_DIR=/plugins \
    "$TFLINT" "$@"
}

# The tflint image ships no rulesets. Without a mounted plugin directory the AWS
# ruleset is re-downloaded on every invocation, and a network failure then fails
# the lint run rather than the download.
info "tflint — installing rulesets"
tflint_run --init >/dev/null

failures=0

for layer in "${LAYERS[@]}"; do
  info "tflint — $layer"
  if tflint_run --chdir="$layer" --format=compact; then
    ok "$layer clean"
  else
    failures=$((failures + 1))
  fi
done

# --quiet suppresses the per-check passed list; --compact drops the code
# snippets. Together they leave findings and nothing else, which is what makes
# the output readable when there are none.
info "checkov — infra/"
if docker run --rm --volume "$INFRA:/infra:ro" "$CHECKOV" \
  --directory /infra \
  --framework terraform \
  --quiet --compact; then
  ok "checkov clean"
else
  failures=$((failures + 1))
fi

echo
if ((failures > 0)); then
  die "$failures static analysis check(s) failed."
fi
ok "static analysis passed"
```

Make it executable: `chmod +x scripts/lint-infra.sh`

- [ ] **Step 4: Add the makefile targets**

```make
.PHONY: tf-lint
tf-lint: ## Run tflint and checkov from digest-pinned containers
	@./scripts/lint-infra.sh

.PHONY: tf-check
tf-check: tf-validate tf-lint tf-test ## The full pre-merge gate for infra/ (no AWS session)
	@printf '\n  all infra checks passed\n\n'
```

- [ ] **Step 5: Run it and record every finding**

Run: `make tf-lint`
Expected: findings. They are not failures to suppress on sight — each one is triaged into exactly one of three outcomes, and the outcome is recorded in Task 9's verification document:

1. **Real** — fix the configuration.
2. **Correct in general, wrong here** — add an inline `# checkov:skip=<ID>:<reason>` or `# tflint-ignore: <rule>` comment. The reason is mandatory and must name the decision it defends, not restate the rule.
3. **Not applicable to this project** — same as (2), with the reason saying why.

The skips already written into Tasks 1 and 4 cover the three findings predicted from D4 and D5 (`CKV_AWS_145` twice, `CKV_AWS_136`, `CKV_AWS_26`). Anything else is discovered here.

Findings expected but not pre-suppressed, so that the triage is done against real output rather than a guess:

| Likely ID | What it wants | Probable outcome |
|---|---|---|
| `CKV_AWS_18` | S3 access logging on both buckets | Skip — logging needs a target bucket which itself needs logging; the audit trail for this project is CloudTrail, which is account-wide and already on |
| `CKV_AWS_144` | Cross-region replication | Skip — single-region project by design |
| `CKV2_AWS_62` | S3 event notifications | Skip — nothing consumes them |
| `CKV_AWS_338` / log retention | CloudWatch retention | Not applicable — no log group in this layer |

- [ ] **Step 6: Re-run until clean**

Run: `make tf-check`
Expected: `all infra checks passed`.

- [ ] **Step 7: Proposed commit** *(not executed)*

```bash
git add infra/.tflint.hcl scripts/lint-infra.sh makefile .gitignore infra/bootstrap infra/foundation
git commit -m "build(infra): lint and scan every layer from digest-pinned containers"
```

---

## Task 6: The ECR seed script

Phase 5 and Phase 6 create ECS services, and an ECS service with nothing to pull does not start. This is what puts something there.

**Files:**
- Create: `scripts/seed-ecr.sh`
- Modify: `makefile`, `scripts/README.md`

**Interfaces:**
- Consumes: `app/dist/image.oci.tar`, `app/dist/image-digest.txt` and `app/dist/image-ref.txt` from `make build`; the `ecr_repository_url` output from `foundation`.
- Produces: `make seed-ecr`.

- [ ] **Step 1: Write `scripts/seed-ecr.sh`**

```bash
#!/usr/bin/env bash
#
# Push the Phase 2 image into ECR, so the ECS services in Phases 5 and 6 have
# something to run. Roadmap §0: seed with the real application image, built
# locally, before the first ECS apply.
#
# skopeo copies the OCI archive byte-for-byte, so the manifest digest ECR stores
# is the digest app/dist/image-digest.txt already names. `docker push` of the
# daemon's copy is not equivalent: the daemon holds a re-imported convenience
# copy, and a push may re-encode it into a digest that matches nothing recorded
# anywhere. See the Phase 3 plan §D6.
#
# Pinned 2026-08-24, quay.io/skopeo/stable:v1.20.0. Re-record with:
#   docker buildx imagetools inspect quay.io/skopeo/stable:v1.20.0 --format '{{.Manifest.Digest}}'

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker
require_cmd aws
require_cmd terraform

ROOT="$(repo_root)"
DIST="$ROOT/app/dist"
SKOPEO="quay.io/skopeo/stable@sha256:47853bb9fb24202af9110531ebd6e43c5f97701254ca290596640290d17942f4"

PROFILE="${AWS_PROFILE:-bootcamp-administrator-access}"
REGION="${AWS_REGION:-us-east-1}"

[[ -f "$DIST/image.oci.tar" ]] || die "no image archive — run 'make build' first"
[[ -f "$DIST/image-digest.txt" ]] || die "no recorded digest — run 'make build' first"
[[ -f "$DIST/image-ref.txt" ]] || die "no recorded image ref — run 'make build' first"

LOCAL_DIGEST="$(cat "$DIST/image-digest.txt")"
LOCAL_REF="$(cat "$DIST/image-ref.txt")"
TAG="${LOCAL_REF##*:}"

# A -dirty tag names a tree that is not any commit. Seeding one would put an
# unreproducible artifact in the registry every later phase deploys from.
if [[ "$TAG" == *-dirty ]]; then
  die "refusing to seed a dirty build ($TAG) — commit the tree and rebuild"
fi

REPO_URL="$(terraform -chdir="$ROOT/infra/foundation" output -raw ecr_repository_url)"
REPO_NAME="${REPO_URL##*/}"
DEST="${REPO_URL}:${TAG}"

info "seeding $DEST"
dim "  local digest  $LOCAL_DIGEST"

# ECR tags are immutable, so a second seed of the same tag is an error rather
# than a no-op. If the tag is already there with the digest we hold, the seed
# has already happened and this is a success, not a failure.
existing="$(aws ecr describe-images \
  --profile "$PROFILE" --region "$REGION" \
  --repository-name "$REPO_NAME" \
  --image-ids "imageTag=$TAG" \
  --query 'imageDetails[0].imageDigest' \
  --output text 2>/dev/null || true)"

if [[ -n "$existing" && "$existing" != "None" ]]; then
  if [[ "$existing" == "$LOCAL_DIGEST" ]]; then
    ok "already seeded — $TAG is $existing"
    exit 0
  fi
  die "tag $TAG already exists with a different digest ($existing); tags are immutable"
fi

password="$(aws ecr get-login-password --profile "$PROFILE" --region "$REGION")"

# The token goes in through the environment and is expanded by a shell *inside*
# the container, never as a docker run argument: arguments are visible to `ps`
# for the lifetime of the process, and an ECR token is a twelve-hour credential
# for the registry every later phase deploys from.
docker run --rm \
  --volume "$DIST:/work:ro" \
  --env "DEST_PASSWORD=$password" \
  --entrypoint sh \
  "$SKOPEO" -c \
  "skopeo copy --dest-creds \"AWS:\$DEST_PASSWORD\" \
     oci-archive:/work/image.oci.tar docker://$DEST"

pushed="$(aws ecr describe-images \
  --profile "$PROFILE" --region "$REGION" \
  --repository-name "$REPO_NAME" \
  --image-ids "imageTag=$TAG" \
  --query 'imageDetails[0].imageDigest' \
  --output text)"

# The whole reason for using skopeo rather than docker push is that this holds.
# Asserting it turns the claim into a check.
[[ "$pushed" == "$LOCAL_DIGEST" ]] ||
  die "digest mismatch — ECR holds $pushed, the artifact of record is $LOCAL_DIGEST"

ok "seeded $DEST"
dim "  digest  $pushed"
dim "  Phases 5 and 6 set BGD_IMAGE_DIGEST to this value in the task definition."
```

Note the `--entrypoint sh … -c` wrapper. `--dest-creds "AWS:$password"` written directly as a `docker run` argument would put a live ECR token in the host's process list, where `ps` shows it to every user on the machine. Passing it as `--env` and letting a shell *inside* the container expand it keeps it out of both the host's argument list and the shell history. The `\$DEST_PASSWORD` escape is what defers the expansion — an unescaped `$DEST_PASSWORD` would expand on the host to the empty string and skopeo would authenticate as `AWS:`.

Make it executable: `chmod +x scripts/seed-ecr.sh`

- [ ] **Step 2: Add the makefile target and remove the last `PLANNED` line**

```make
.PHONY: seed-ecr
seed-ecr: ## Push the built image into ECR (needs an AWS session)
	@./scripts/seed-ecr.sh
```

Delete: `# PLANNED: seed-ecr       Push the first real image to ECR (Phase 3)`

- [ ] **Step 3: Verify the script's guards without an AWS session**

Run: `./scripts/seed-ecr.sh`
Expected: it fails at the **first** guard it reaches and names the fix — `no image archive — run 'make build' first` on a clean tree, or the dirty-tag refusal if `app/dist/` is populated from a dirty build. It must not reach any AWS call before its local preconditions are satisfied. This is the only verification available in this session; the push itself is a runbook step.

- [ ] **Step 4: Update `scripts/README.md`**

Add three rows to the table:

```markdown
| `tf.sh` | 3 — per-layer terraform driver; `-backend=false` for fmt, validate and test |
| `lint-infra.sh` | 3 — tflint and checkov from digest-pinned containers |
| `seed-ecr.sh` | 3 — copy the Phase 2 OCI archive into ECR, digest verified |
```

- [ ] **Step 5: Proposed commit** *(not executed)*

```bash
git add scripts/seed-ecr.sh scripts/README.md makefile
git commit -m "feat(infra): seed ECR from the Phase 2 artifact of record"
```

---

## Task 7: The runbook

The deliverable that turns D1's split into a phase you can finish. Written to be executed by someone who has not read this plan.

**Files:**
- Create: `docs/runbooks/phase-03-bootstrap-and-foundation.md`
- Modify: `docs/runbooks/README.md`

- [ ] **Step 1: Write the runbook**

It must contain, in this order and with exact commands:

1. **Preconditions** — `aws sso login --profile bootcamp-administrator-access`, then `make verify-aws`; `make tf-check` green; a clean working tree (the seed refuses a dirty build).
2. **Apply bootstrap** — `make plan-bootstrap`, review, `make apply-bootstrap`. Expected: 8 resources created. Note that this layer's state is now a local file that is not in git and not in the bucket, and that it is recreatable with `terraform -chdir=infra/bootstrap import aws_s3_bucket.tfstate bgd-us-east-1-tfstate-590184028094`.
3. **Apply foundation** — `make plan-foundation`, review, `make apply-foundation`. Expected: the zone **adopted, not created** — confirm `zone_was_created = false` in the outputs, and stop if it says `true`, because that means the account does not hold the zone Phase 0 found and the registrar's name servers need repointing before the certificate can validate. The apply blocks on `aws_acm_certificate_validation.api` for a few minutes.
4. **Manual step 1 of 3 — authorise the GitHub connection.** Console → Developer Tools → Settings → Connections → `bgd-us-east-1-github` → Update pending connection. Verify:
   ```bash
   aws codeconnections get-connection --connection-arn "$(terraform -chdir=infra/foundation output -raw github_connection_arn)" --query 'Connection.ConnectionStatus'
   ```
   Expected `"AVAILABLE"`. Phase 7 cannot start until this says so.
5. **Manual step 2 of 3 — confirm the SNS subscription.** Click the link in the email AWS sends to `carreque45@gmail.com`. Verify:
   ```bash
   aws sns list-subscriptions-by-topic --topic-arn "$(terraform -chdir=infra/foundation output -raw alerts_topic_arn)" --query 'Subscriptions[].SubscriptionArn'
   ```
   Expected an ARN. `"PendingConfirmation"` means the click has not happened. **Nothing will ever error if this is skipped** — the symptom is Phase 9's alerts silently going nowhere.
6. **Manual step 3 of 3 — activate the cost allocation tags.** Billing → Cost allocation tags → activate `environment`, `projectName`, `region`, `owner`. **This has a deadline the other two do not.** It cannot be done before this phase, because a key only becomes activatable once AWS has observed it on a real resource; and it is not retroactive, so every day of delay is spend that stays permanently unattributed. Doing it late does not delay anything — it silently loses data.
7. **Seed the registry** — `make build` (clean tree), then `make seed-ecr`. Expected: the digest ECR reports equals `app/dist/image-digest.txt`.
8. **Exit criteria verification** — one command per criterion, with the expected output:
   - state backend live and locking: `aws s3api get-bucket-versioning --bucket bgd-us-east-1-tfstate-590184028094` → `"Enabled"`; and a `foundation` apply having succeeded is itself proof the backend and its lockfile work.
   - certificate issued: `aws acm describe-certificate --certificate-arn "$(terraform -chdir=infra/foundation output -raw certificate_arn)" --query 'Certificate.Status'` → `"ISSUED"`.
   - ECR holds the seeded image: `aws ecr list-images --repository-name bgd-us-east-1-api`.
   - SNS subscription confirmed: as in step 5.
9. **Repair notes** — what to do when the certificate validation times out (set `wait_for_validation = false`, apply, fix delegation, set it back); what to do when `allowed_account_ids` rejects the session (wrong profile, not wrong config); and the warning that `prevent_destroy` on the state bucket is intentional and must not be removed to make a `destroy` succeed.

- [ ] **Step 2: Add the runbook to `docs/runbooks/README.md`**

- [ ] **Step 3: Proposed commit** *(not executed)*

```bash
git add docs/runbooks
git commit -m "docs(infra): runbook for the bootstrap and foundation applies"
```

---

## Task 8: Document amendments

Three documents currently say something this phase found to be wrong. Amended in the style Phase 0 and Phase 2 established: an inline blockquote naming the phase and the date, not a silent edit.

**Files:**
- Modify: `docs/2026-08-04-implementation-phase-roadmap.md`
- Modify: `docs/2026-08-04-blue-green-deployment-platform-design-research.md`
- Modify: `infra/foundation/README.md`, `infra/bootstrap/README.md`

- [ ] **Step 1: Amend the roadmap — three manual steps, not two**

In §3's Phase 3 block, after "These are the **two irreducibly manual steps** in the whole project", add:

> **Amended in Phase 3 (2026-08-24).** There are **three**. The SNS email
> subscription is the third: `aws_sns_topic_subscription` with
> `protocol = "email"` is created `PendingConfirmation` and stays there until
> the recipient clicks the link AWS emails. Terraform reports the resource as
> created and `terraform plan` stays clean indefinitely, so an unconfirmed
> subscription is silent — its symptom is Phase 9's alerts never arriving. The
> Phase 3 runbook lists it as a step with its own verification command.

- [ ] **Step 2: Amend the roadmap — Phase 3's scope**

In the same block, after the CodeConnections bullet:

> **Amended in Phase 3 (2026-08-24).** §1's layer diagram lists both pipelines
> and the shared IAM roles under `foundation`; this task list does not, and the
> task list is what was built. `foundation` still owns the pipelines — Phases 7
> and 8 add files to this layer rather than creating a new one — and each of
> design §8.1's six IAM roles is created by the phase that creates the resource
> it acts on, because a role's policy cannot be scoped to resources that do not
> exist yet.

- [ ] **Step 3: Amend design §1.7 — the null-safe predicate**

After the code block:

> **Amended in Phase 3 (2026-08-24).** The filter reads `!z.private_zone`
> above; it must be `z.private_zone != true`. The `for_each` resolves **every**
> hosted zone in the account, so each zone's attributes have to survive the
> expression before the name filter can exclude it — and a null boolean makes
> the negation abort the entire plan with `argument must not be null`, on a line
> that looks correct. `!= true` is null-safe and identical for every non-null
> value. Found by the Phase 3 test suite before the first apply.

- [ ] **Step 4: Amend design §2 — the provider version**

Add after §1.4's existing Phase 0 amendment or in §2's audit table:

> **Amended in Phase 3 (2026-08-24).** The AWS provider now resolves to
> **6.61.0** (Phase 0 recorded 6.57.1). Both layers pin `~> 6.61` and commit
> `.terraform.lock.hcl` with hashes for `darwin_arm64`, `linux_arm64` and
> `linux_amd64` — the second because Phase 8's CodeBuild runs `ARM_CONTAINER`,
> and a lock file written only on this Mac fails there with a missing-hash error
> that reads as a corrupt lock rather than a missing platform.

- [ ] **Step 5: Amend `infra/foundation/README.md`**

Change "**Both irreducibly manual steps in the project live here:**" to three, adding the SNS confirmation as item 2 and renumbering. Also strike the "and both CodePipelines" from the bullet list, replacing it with a note that the pipelines arrive in Phases 7 and 8 in this same layer, and that no IAM role is created here.

- [ ] **Step 6: Amend `infra/bootstrap/README.md`**

Add the import command that recreates the local state, and note `prevent_destroy`.

- [ ] **Step 7: Proposed commit** *(not executed)*

```bash
git add docs/2026-08-04-implementation-phase-roadmap.md \
        docs/2026-08-04-blue-green-deployment-platform-design-research.md \
        infra/foundation/README.md infra/bootstrap/README.md
git commit -m "docs: record what Phase 3 found — three manual steps, a null-safe filter, a newer provider"
```

---

## Task 9: Verification record

**Files:**
- Create: `docs/phases/phase3/2026-08-24-local-verification.md`

- [ ] **Step 1: Run the full gate one last time and capture the raw output**

Run: `make tf-check`

- [ ] **Step 2: Write the record**

Following `docs/phases/phase2/2026-08-12-local-verification.md`'s shape. It must contain:

- the command, its raw output, and the assertion count for each of `tf-validate`, `tf-lint`, `tf-test`
- the full checkov and tflint triage table from Task 5 Step 5: every finding, its outcome, and the reason
- an explicit statement that **no AWS resource was created and no AWS API call was made**, with `make verify-aws` failing on an expired token as the evidence
- **what remains before Phase 3's exit criteria are met**, as a checklist pointing at the runbook — the state backend, the certificate, the seeded image and the confirmed subscription are all still pending

- [ ] **Step 3: Proposed commit** *(not executed)*

```bash
git add docs/phases/phase3
git commit -m "docs(infra): Phase 3 local verification record and implementation plan"
```

---

## 4. Exit criteria

Roadmap §3's four criteria for Phase 3 are:

| Criterion | Met by |
|---|---|
| State backend live and locking | The runbook, step 2. A successful `foundation` apply through the S3 backend is itself the proof. |
| Certificate issued and validated | The runbook, step 3, verified in step 8. |
| ECR holds the seeded image | The runbook, step 7, digest-verified by the script. |
| SNS email subscription confirmed | The runbook, step 5. |

**None of the four is met by this branch alone**, and D1 says so deliberately. What the branch is gated on is its own criterion:

- `make tf-check` passes: both layers valid, both lint clean, nineteen assertions green
- both layers' `.terraform.lock.hcl` carry hashes for three platforms
- `scripts/seed-ecr.sh` refuses to run without an artifact or on a dirty tree
- `make help` lists no target that does not run
- the runbook exists and every command in it is exact

---

## 5. What this phase hands to Phase 4

- `terraform_remote_state` against `bgd-us-east-1-tfstate-590184028094`, key `network/terraform.tfstate`, is the shape Phase 4 uses. `foundation`'s key is `foundation/terraform.tfstate`.
- `local.common_tags` is available as an output. Phase 4 sets `environment = "shared"` too; Phases 5 and 6 override it to `staging` and `prod`.
- `scripts/tf.sh` already resolves `network`, `staging` and `prod` to their directories. Adding a layer is a directory plus one entry in the makefile's `TF_LAYERS`.
- The certificate ARN is an output, so the ALBs in Phases 5 and 6 reference a certificate that outlives their own teardown.

---

## 6. Risks carried forward

| Risk | Handling |
|---|---|
| **The domain expires 2026-12-18 with auto-renew off** | Unchanged from Phase 0, and now closer. Every environment's TLS and DNS depends on it from Phase 5. Not something the IaC can fix. |
| **`bootstrap`'s state is a local file, not in git** | By design (§3.2). Losing it costs one `terraform import`, and the command is in `infra/bootstrap/README.md`. |
| **The literal bucket name in `foundation`'s backend block cannot be checked by Terraform** | A backend block cannot interpolate. Nothing mechanical keeps the literal and `var.account_id`'s default in agreement; the naming convention and the runbook's first apply do. |
| **checkov's rule set changes when the pinned digest is bumped** | New rules will appear as findings on unchanged code. That is the intent of pinning: the bump is a deliberate commit whose diff is the new triage. |
| **The seed depends on Phase 2's reproducibility claim holding across skopeo** | Asserted, not assumed: the script compares the digest ECR reports against `app/dist/image-digest.txt` and fails on a mismatch. |
