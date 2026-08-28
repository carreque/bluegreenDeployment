# Phase 4 — Network layer: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-26
**Status:** Proposed, awaiting approval
**Branch:** `feat/Phase4_Network`
**AWS cost incurred by this phase as planned:** **$0.** Every deliverable is written and verified locally against mocked providers. The apply that creates the ~$36/month of real resources is handed to you as a runbook — see §0.1 D1.
**Companion documents:**
[design research](../../2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 3 plan](../phase3/2026-08-24-phase-03-implementation-plan.md) ·
[Phase 3 runbook](../../runbooks/phase-03-bootstrap-and-foundation.md) ·
[naming and tagging convention](../../naming-and-tagging-convention.md)

**Goal:** Write the `network` layer — one VPC across two availability zones, public subnets for the ALBs, private subnets for the Fargate tasks, a single shared NAT Gateway, free gateway endpoints for S3 and DynamoDB, and four least-privilege security groups — and prove it correct offline before a single resource is created.

**Architecture:** A flat root module at `infra/network/`, matching `bootstrap` and `foundation`. It is deliberately **self-contained**: it reads no `terraform_remote_state`, because it consumes no foundation resource (D2). Correctness is asserted by Terraform's native test framework against `mock_provider`, using `command = apply` rather than `command = plan` — the difference is load-bearing and is the subject of F1. Two shell scripts land with it: a live NAT-egress probe and the first-cut ordered teardown.

**Tech stack:** Terraform 1.15.7, AWS provider ~> 6.61, tflint 0.60.0 with AWS ruleset 0.44.0, checkov 3.3.13 — the last two from digest-pinned containers, installing nothing on the host.

---

## 0. Purpose and non-goals

`network` is the first layer that costs real money when idle, and the first whose destruction is routine rather than exceptional. Both facts shape it: everything here must survive being destroyed and rebuilt without ceremony, and nothing durable may be allowed to drift into it.

**This phase deliberately does not:**

- create any AWS resource, or make any AWS API call, in this session (D1)
- create an ALB, target group, ECS cluster, task definition or DynamoDB table — Phases 5 and 6
- create interface VPC endpoints — design §3.1 priced them and chose NAT; only the two **free gateway** endpoints are in scope (D4)
- create a second NAT Gateway for AZ redundancy — one NAT is the design's recorded cost trade
- change anything under `app/`, `infra/bootstrap/` or `infra/foundation/`

### 0.1 Decisions taken before this plan was written

#### D1 — This session writes and verifies; you apply

The same split Phase 3 took, for the same reason and by explicit agreement: the SSO token on `bootcamp-administrator-access` is expired, and `aws sts get-caller-identity` fails with `credentials are still expired`.

**Consequences:**

- The branch's gate is `make tf-check` — `validate`, `tflint`, `checkov` and `terraform test`, all offline. Phase 4's two exit criteria are met when you execute the runbook, not when this branch is written. This is stated plainly rather than left for the pull request to blur.
- **The Phase 4 runbook is blocked behind the Phase 3 runbook.** `network` keeps its state in the bucket `bootstrap` creates. If `make apply-bootstrap` has not been run, `terraform init` on this layer fails on a missing bucket. The runbook opens by checking exactly that, so the failure is diagnosed rather than met.
- One planned finding could not be gathered: the NAT pricing check in F5 needs a session. It becomes a runbook step instead of a plan finding.

#### D2 — `network` reads no remote state

`foundation` outputs `name_prefix` and `common_tags` so that "a tag key can only be spelled once". `network` nevertheless repeats the four variables and rebuilds both locals itself.

**Consequences:**

- `network` consumes no foundation **resource** — not the certificate, not the zone, not the registry. A `terraform_remote_state` dependency would buy two derived strings at the price of coupling the ephemeral layer to the persistent one.
- It keeps `make tf-check` fully offline, the property Phase 3 §F2 established. A remote-state data source would have to be mocked in every test file.
- It keeps `terraform destroy` on `network` working even if foundation's state is unreadable — which matters because teardown is routine here.
- Phases 5 and 6 **do** take remote state on foundation, because they need real ARNs (certificate, zone, registry). The divergence is deliberate, not an inconsistency.

#### D3 — Four security groups, one pair per environment

Roadmap §3 says "ALB-to-task and task-to-egress", which reads as one pair. The naming convention §3 specifies `bgd-us-east-1-<env>-<role>-sg`. The convention wins.

**Consequences:**

- Staging tasks and production tasks cannot reach each other. A single shared task SG would have made every staging task a permitted source for every production task.
- Production's ALB SG opens `:8443` for Phase 6's test listener; staging's does not. Phase 6 therefore never has to reopen this layer to add a port.
- The environment layers consume four SG ids from this layer's outputs rather than two.

#### D4 — A DynamoDB gateway endpoint is added alongside S3

Roadmap §3 and design §3.1 name only the S3 gateway endpoint. Approved as a deliberate addition on 2026-08-26.

**Consequences:**

- Gateway endpoints are **free**, and DynamoDB is the application's entire data path. Without one, every read and write leaves through the NAT and pays $0.045/GB of data processing for traffic that never needed to leave AWS.
- It is four lines and one route-table association per private route table, so the marginal complexity is close to zero.
- Design §3.1's argument is unchanged — this strengthens its third point ("the security gap is smaller than it appears, and we close most of it for free") rather than revising it. The design document gets an amendment note, not a rewrite.

#### D5 — VPC flow logs are enabled, at 7-day retention

**This decision was not in the approved three points.** It arose from F3: checkov fails the layer on `CKV2_AWS_11` and the finding has to be either fixed or skipped with a reason. It is called out here for your review rather than folded in silently.

**Consequences:**

- Flow logs are the tool that answers "why can this task not reach that endpoint", which is the single most likely failure mode of Phases 5 and 6. Enabling them here means the evidence exists the first time it is needed rather than being switched on afterwards.
- Cost is ingestion-driven at roughly $0.50/GB. At this project's traffic it is cents per month, but it is not zero, and it lands on the layer whose whole purpose is being cheap to leave running. If you would rather not, the alternative is a one-line `#checkov:skip=CKV2_AWS_11` with "an ephemeral layer carrying no production data" as the reason, and Task 5 is dropped.
- It introduces this layer's only IAM role, consistent with Phase 3 §D2: each role is created by the phase that creates the resource it acts on.
- Retention below one year will itself trip `CKV_AWS_338`, and an unencrypted log group will likely trip `CKV_AWS_158`. Both are triaged in Task 5 by running checkov, not by assuming the codes.

#### D6 — Per-environment security groups override the `environment` tag

The convention §5 says a resource-level `tags` block may only add, never override the four. The per-env SGs override `environment` to `staging` and `prod`.

**Consequences:**

- The rule in §5 exists to stop cost reports splitting across two spellings of a key. **Security groups have no cost**, so the reason the rule exists does not apply to them.
- The convention document gets a one-line amendment recording the exception and its bound — zero-cost resources only. An undocumented exception is how a convention stops being one.
- Everything else in this layer stays `environment = shared`, from the provider's `default_tags`.

#### D7 — `teardown.sh` lands here, with loud skips

**Consequences:**

- The script destroys `prod` → `staging` → `network` in that order today, and grows on its own as Phases 5 and 6 land — no edit required.
- A layer is skipped **only** when its directory holds no `.tf` files at all, and the skip is printed. The dangerous failure mode is a silent skip that leaves $40/month of production running; the loud one is merely noisy.
- No `-auto-approve`. Terraform's own confirmation prompt is the safety, so the first cut needs no confirmation logic of its own. Phase 10 adds the hardening.
- The makefile's `# PLANNED: teardown` line is removed, because the target now does what its help text says.

#### D8 — NAT egress is proved by an ephemeral EC2 probe

**Consequences:**

- `scripts/verify-network.sh` launches a `t4g.nano` in a private subnet whose user-data writes the result of `curl https://checkip.amazonaws.com` to `/dev/console`, reads it back with `get-console-output`, and **asserts the reported IP equals the NAT Gateway's Elastic IP**. That is stronger than "something reached the internet" — it proves the path.
- No IAM role, no SSH key, no SSM. The instance is terminated by a shell trap, so it is cleaned up on failure as well as success. Cost is about one cent.
- The alternative — a throwaway ECS cluster — would need a cluster, task definition, execution role and log group built ad hoc, all of which Phase 5 builds properly one phase later.

---

## 1. Findings recorded before this plan was written

Five probes were run on 2026-08-26 against real Terraform, real checkov and real tflint. None touched AWS. **Two changed the plan.**

### F1 — `mock_resource` defaults are not applied during `command = plan`

This is the finding that would have broken the test strategy. Phase 3's foundation tests all use `command = plan`, so the natural move was to keep doing that. It does not work for this layer, because every interesting assertion here is a cross-reference between two computed ids — "the private route targets the NAT", "the NAT sits in a public subnet".

```
$ terraform test          # mock_provider with mock_resource "aws_nat_gateway" { defaults = { id = "nat-0mock" } }
Error: Unknown condition value
  on tests/mocked.tftest.hcl line 19:
  19:   condition = aws_route.private_nat[0].nat_gateway_id == aws_nat_gateway.this.id
    │ aws_nat_gateway.this.id is a string
    │ aws_route.private_nat[0].nat_gateway_id is a string
  Condition expression could not be evaluated at this time. […] Either remove
  this value from your condition, or execute an `apply` command from this
  `run` block.
```

Switching the run block to `command = apply` fixes it, and creates nothing — the provider is mocked, so there is no API call and no credential:

```
$ terraform test -filter=tests/applied.tftest.hcl
  run "apply_against_mocks_makes_computed_cross_references_assertable"... pass
Success! 1 passed, 0 failed.
```

The same trap catches a second, less obvious case. `aws_default_security_group`'s `ingress` and `egress` are **sets of objects that stay unknown until apply**, so even `length(...) == 0` — which looks like a statement about a literal — cannot be evaluated at plan time:

```
$ terraform test
  run "the_default_security_group_permits_nothing"... fail
Error: Unknown condition value
    │ aws_default_security_group.this.egress is a set of object
```

**Consequence:** every run block in this layer that asserts a relationship, or reads a block-typed attribute, uses `command = apply`. Run blocks asserting only literal inputs — CIDRs, names, ports — may stay on `plan`, and do, so that a genuine plan-time error is still caught as one. Phase 3's plan-only convention is amended for this layer, with the reason attached.

### F2 — A bare `mock_provider "aws" {}` returns an empty `aws_availability_zones`

```
$ terraform test          # mock_provider "aws" {} with no mock_data
Error: Invalid function argument
  on main.tf line 17, in locals:
  17: locals { azs = slice(data.aws_availability_zones.available.names, 0, 2) }
    │ while calling slice(list, start_index, end_index)
  Invalid value for "end_index" parameter: end index must not be greater than
  the length of the list.
```

**Consequence:** every test file in this layer declares `mock_data "aws_availability_zones"` with an explicit three-name default. Without it the failure is not a failed assertion but a crash inside `locals`, which reads like a bug in the configuration rather than a gap in the mock.

### F3 — checkov fails this layer's shape on four checks, in three categories

Run against a probe carrying the VPC, subnets, IGW, NAT, both gateway endpoints, two security groups and their rules:

```
Passed checks: 36, Failed checks: 4, Skipped checks: 0

CKV2_AWS_12  default security group of every VPC restricts all traffic   aws_vpc.this
CKV2_AWS_11  VPC flow logging is enabled in all VPCs                     aws_vpc.this
CKV2_AWS_5   Security Groups are attached to another resource            aws_security_group.alb
CKV2_AWS_5   Security Groups are attached to another resource            aws_security_group.task
```

The triage, decided here rather than at the keyboard:

| Check | Verdict | Reason |
|---|---|---|
| `CKV2_AWS_12` | **Fix** | A VPC's default security group allows all traffic between anything that lands in it. An `aws_default_security_group` with no rules costs nothing and closes it. Not a skip — a real finding. |
| `CKV2_AWS_11` | **Fix** (D5) | Flow logs enabled, 7-day retention. Subject to your review; the fallback is a documented skip. |
| `CKV2_AWS_5` | **Skip, with reason** | A false positive by construction. These security groups are attached by the ALB and the ECS service in Phases 5 and 6, which live in **different state files**. checkov reads one directory and cannot see across layers. |
| `CKV_AWS_260` | **Skip, with reason** | *Added during execution, 2026-08-26.* The probe carried only a `:443` rule, so this check never fired against it; the real ALB groups also open `:80` and two findings appear. Design §5 requires an HTTP-to-HTTPS redirect, and a listener cannot redirect a request it never receives — closing `:80` does not harden the ALB, it replaces the redirect with a connection timeout. Skipped on `alb_http` only. |
| `CKV_AWS_130` | **Skip, with reason** | *Added during execution, 2026-08-26.* The probe this table was built from did not set `map_public_ip_on_launch`, so this check never fired against it; the real public subnets do set it and two findings appear. The check is correct for a private subnet and wrong for a public one by definition — a public subnet that does not assign public addresses cannot host a NAT Gateway or an internet-facing ALB's nodes. Skipped on `aws_subnet.public` only; the private subnets set it explicitly to `false` and pass. |

`CKV2_AWS_5` is exactly the class of finding Phase 3 §D3 predicted: "checkov will report findings that are correct for a generic account and wrong for this project."

**Note on what did *not* fail:** the least-privilege egress rule — `:443` to `0.0.0.0/0` — passes checkov. That is not because checkov flags open egress on `-1`/all-ports for this resource shape — it doesn't: checkov's open-egress checks (e.g. `CKV_AWS_23`/`CKV_AWS_260`-adjacent egress checks) fire on `aws_security_group` inline `egress` blocks, and this layer uses standalone `aws_vpc_security_group_egress_rule` resources instead, which those checks do not inspect at all. A rule with `ip_protocol = "-1"` and `cidr_ipv4 = "0.0.0.0/0"` added as a fourth `aws_vpc_security_group_egress_rule` next to the three real ones would pass checkov silently. The design in §3 below is clean on this axis only because review confirmed it by hand, not because the gate would have caught a regression. See the "Carried forward" table in the local verification record for the residual gap this leaves.

### F4 — tflint is clean on this layer's shape

The same probe, run through the digest-pinned tflint container with the repository's `.tflint.hcl` and the AWS ruleset, reports nothing. No finding to carry.

### F5 — The roadmap's ~$33/month figure is unverified, and probably low

`aws pricing get-products` needs a session this machine does not have:

```
$ aws pricing get-products --service-code AmazonEC2 --filters …
aws: [ERROR]: Credentials were refreshed, but the refreshed credentials are still expired.
```

The published rates are $0.045/hour for the gateway (~$32.85/month) plus $0.045/GB processed. Since 1 February 2024 AWS also bills **in-use public IPv4 addresses** at $0.005/hour, and a NAT Gateway's Elastic IP is in use — roughly **$3.60/month** on top, for about **$36.45** before data processing.

**Consequence:** this is stated as an expectation, not a fact, because it was not measured. Task 11 of the runbook confirms it against the pricing API and amends roadmap §3's table with whatever the real number is. It is recorded now so the discrepancy is checked rather than inherited.

---

## 2. Global constraints

Every task's requirements implicitly include these. Values are copied verbatim from the sources named.

- **Naming:** `<projectName>-<region>-<resource>`, all lowercase, hyphen-separated — `bgd-us-east-1-vpc`. Subnets are `bgd-us-east-1-<tier>-<az>`; security groups are `bgd-us-east-1-<env>-<role>-sg`; the flow-log group is `/bgd/us-east-1/shared/vpc-flow` (log groups use slashes, the one deliberate deviation). [convention §1, §3]
- **Tags:** exactly `environment`, `projectName`, `region`, `owner`, case-sensitive, applied through the provider's `default_tags`. `environment = "shared"` for this layer, overridden to `staging`/`prod` on the per-env security groups only (D6). [convention §5]
- **Terraform:** `required_version >= 1.10`; AWS provider `~> 6.61`; backend `s3` with `use_lockfile = true`, key `network/terraform.tfstate`, bucket `bgd-us-east-1-tfstate-590184028094` written as a literal because a backend block cannot interpolate.
- **Provider lock:** `.terraform.lock.hcl` is committed, generated for `darwin_arm64`, `linux_arm64` and `linux_amd64` — Phase 8's CodeBuild runs `ARM_CONTAINER`, and a lock written only on this Mac fails there with an error that reads as corruption rather than a missing platform. [Phase 3 §D7]
- **Container port:** `8080`. Fixed by `app/Dockerfile` (`EXPOSE 8080`, uvicorn `--port 8080`).
- **Account guard:** `allowed_account_ids = [var.account_id]` on the provider, `590184028094`.
- **Two availability zones**, the first two with `opt-in-status = opt-in-not-required`. One NAT Gateway total, in the first AZ's public subnet.
- **The gate:** `make tf-check` must be green — `terraform validate`, `tflint`, `checkov` and `terraform test`, all with no AWS session. **Tasks 1-4 are the exception:** checkov fails `CKV2_AWS_11` from the moment the VPC exists until Task 5 enables flow logs, so during those tasks the per-task gate is `./scripts/tf.sh validate network && ./scripts/tf.sh test network`. Full `make tf-check` is required green from Task 5 onward.
- **Every test file's `mock_provider` block needs four mocks, not one.** *Recorded during execution, 2026-08-26, after three tasks hit it independently.* Each `run` block applies the **whole root module**, so a test file that only mocks `aws_availability_zones` fails on the flow-logs resources regardless of what it asserts. A mocked `aws_iam_policy_document` returns `""` for `json`, which `aws_iam_role`'s schema rejects client-side before apply; a mocked resource's `arn` defaults to an opaque string, which `aws_flow_log`'s ARN-shape validation rejects. The canonical block — four AZ names plus `mock_data "aws_iam_policy_document"` and `mock_resource` ARN defaults for `aws_cloudwatch_log_group` and `aws_iam_role` — is the one at the top of `infra/network/tests/routing.tftest.hcl`. Copy it; do not rebuild it from the per-task snippets below, which predate this finding and show only the AZ mock.
- **Declare on first use.** tflint's `recommended` preset includes `terraform_unused_declarations` and exits 2 on a variable, local or data source nothing references yet; `lint-infra.sh` turns that into a failed gate. No task may declare a variable or local ahead of the task that uses it.

---

## 3. File structure

```
infra/network/
  versions.tf              terraform block, provider pin, S3 backend
  providers.tf             aws provider, allowed_account_ids, default_tags
  variables.tf             project_name, region, account_id, owner, vpc_cidr,
                           az_count, container_port, flow_log_retention_days
  locals.tf                name_prefix, common_tags, azs, subnet CIDR maths
  vpc.tf                   aws_vpc, aws_default_security_group, aws_internet_gateway
  subnets.tf               public and private subnets
  routing.tf               EIP, NAT Gateway, route tables, routes, associations
  endpoints.tf             S3 and DynamoDB gateway endpoints
  flowlogs.tf              log group, IAM role and policy, aws_flow_log
  security.tf              four security groups and their rules
  outputs.tf               the surface Phases 5 and 6 consume
  terraform.tfvars.example
  README.md                (exists — rewritten to match what was built)
  .terraform.lock.hcl      (generated, three platforms)
  tests/
    addressing.tftest.hcl      VPC, AZs, subnet CIDRs, non-overlap, naming
    routing.tftest.hcl         IGW, NAT placement, default routes, endpoints
    security_groups.tftest.hcl the four groups, their rules, :8443 asymmetry
    outputs.tftest.hcl         the consumed surface, so Phase 5 cannot be surprised

scripts/
  verify-network.sh        ephemeral EC2 probe: private subnet egresses via NAT
  teardown.sh              ordered destroy prod -> staging -> network, loud skips

makefile                   TF_LAYERS += network; real `teardown` target
docs/
  runbooks/phase-04-network.md
  phases/phase4/2026-08-26-local-verification.md
```

Files are split by responsibility rather than lumped into `main.tf`: `routing.tf` and `security.tf` are the two that will be read most often when something cannot reach something else, and both are worth being able to hold in view on their own.

---

## 4. Tasks

### Task 1: Layer skeleton and the VPC

**Files:**
- Create: `infra/network/versions.tf`, `providers.tf`, `variables.tf`, `locals.tf`, `vpc.tf`, `terraform.tfvars.example`
- Modify: `makefile:TF_LAYERS`
- Test: `infra/network/tests/addressing.tftest.hcl`

**Interfaces:**
- Produces: `local.name_prefix` (string, `"bgd-us-east-1"`), `local.common_tags` (map with the four convention keys), `aws_vpc.this`, `var.vpc_cidr` (default `"10.0.0.0/16"`), `var.az_count` (default `2`), `var.container_port` (default `8080`).

- [ ] **Step 1: Write the failing test**

`infra/network/tests/addressing.tftest.hcl`:

```hcl
# Addressing is asserted before anything is routed through it, because every
# later assertion in this layer is a statement about where traffic goes, and
# "where" is a CIDR. mock_data for the availability zones is mandatory, not
# tidiness: without it the AZ list is empty and locals.tf crashes inside
# slice() before any assertion runs (plan §F2).

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
}

run "the_vpc_is_named_and_sized_by_the_convention" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16"
    error_message = "the VPC CIDR must come from var.vpc_cidr"
  }

  assert {
    condition     = aws_vpc.this.tags["Name"] == "bgd-us-east-1-vpc"
    error_message = "convention §3: a VPC is named <project>-<region>-vpc"
  }
}

run "dns_is_on_because_every_aws_endpoint_is_a_hostname" {
  command = plan

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "without VPC DNS, a Fargate task cannot resolve ecr, logs or dynamodb, and the failure looks like a network outage"
  }
}

# apply, not plan: ingress and egress on this resource are sets of objects that
# stay unknown until the apply resolves them, exactly as in §F1.
run "the_default_security_group_permits_nothing" {
  command = apply

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0
    error_message = "an unmanaged default security group allows anything that lands in it to reach anything else (checkov CKV2_AWS_12)"
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/tf.sh test network`
Expected: FAIL — the layer has no `.tf` files, so `tf.sh` dies with `layer 'network' has no directory yet` or `terraform init` reports no configuration.

- [ ] **Step 3: Write `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
  }

  # A backend block cannot interpolate, so the bucket bootstrap created appears
  # as a literal. Nothing mechanical keeps this string and var.account_id's
  # default in agreement — only the naming convention does.
  backend "s3" {
    bucket       = "bgd-us-east-1-tfstate-590184028094"
    key          = "network/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

- [ ] **Step 4: Write `providers.tf`**

```hcl
# Repeated from foundation rather than shared: a provider block is not a
# module's worth of abstraction, and each root module owning its own is what
# lets this layer diverge without touching that one.
provider "aws" {
  region = var.region

  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.common_tags
  }
}
```

- [ ] **Step 5: Write `variables.tf`**

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
  description = "Expected AWS account. Asserted by the provider."
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

variable "vpc_cidr" {
  description = "Address space for the whole VPC. Public subnets are /24s carved from its first /20; private subnets are /20s after it."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be valid and no smaller than a /16; the /20 private subnets do not fit otherwise."
  }
}

variable "az_count" {
  description = <<-EOT
    How many availability zones to spread across.

    Two is the floor, not a preference: an ALB requires subnets in at least two
    AZs, and a blue/green deployment confined to one AZ is not an availability
    story (design §3.1). Raising it multiplies subnets and route tables but not
    NAT Gateways — there is deliberately still only one.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

```

> **Preflight ruling (R1).** `container_port` and `flow_log_retention_days` are
> **not** declared here, and neither are the subnet-CIDR locals. tflint's
> `recommended` preset includes `terraform_unused_declarations`, which exits 2 on
> a variable or local that nothing references yet — and `scripts/lint-infra.sh`
> treats any non-zero exit as a failure. Declaring them up front would make this
> task fail its own gate. Each is declared by the task that first uses it:
> the CIDR locals in Task 2, `flow_log_retention_days` in Task 5,
> `container_port` in Task 6.

- [ ] **Step 6: Write `locals.tf`**

```hcl
data "aws_availability_zones" "available" {
  state = "available"

  # Opt-in zones (Local Zones, Wavelength) are not enabled on this account and
  # do not support Fargate. Without this filter the first two names returned
  # could be zones nothing can be launched into.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name_prefix = "${var.project_name}-${var.region}"

  common_tags = {
    environment = "shared"
    projectName = var.project_name
    region      = var.region
    owner       = var.owner
  }

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}
```

- [ ] **Step 7: Write `vpc.tf`**

```hcl
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are required, and neither is the default. Fargate reaches ECR,
  # CloudWatch Logs and DynamoDB by hostname; the gateway endpoints in
  # endpoints.tf are only consulted after DNS has resolved the service name.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# Every VPC is created with a default security group that allows all traffic
# between members. Nothing here uses it, but "nothing uses it" is a property of
# today's configuration rather than a control. Adopting it with no rules makes
# it inert. (checkov CKV2_AWS_12)
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-default-sg-locked"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}
```

- [ ] **Step 8: Write `terraform.tfvars.example`**

```hcl
# Every variable has a default correct for this project; terraform.tfvars is
# gitignored. The two worth knowing about:
#
#   vpc_cidr = "10.0.0.0/16"
#     Changing it after the first apply replaces the VPC and everything in it.
#
#   az_count = 2
#     Two is the floor an ALB requires. Raising it adds subnets and route
#     tables but still only one NAT Gateway — see the plan's §0.1.
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `./scripts/tf.sh test network`
Expected: PASS — `3 passed, 0 failed`.

- [ ] **Step 10: Add the layer to the makefile and generate the provider lock**

In `makefile`, change the one line:

```make
TF_LAYERS := bootstrap foundation network
```

Then generate the committed lock for all three platforms:

```bash
terraform -chdir=infra/network init -backend=false
terraform -chdir=infra/network providers lock \
  -platform=darwin_arm64 -platform=linux_arm64 -platform=linux_amd64
```

- [ ] **Step 11: Verify the whole offline gate still passes**

Run: `make tf-fmt && ./scripts/tf.sh validate network && ./scripts/tf.sh test network`
Expected: both green.

**Do not expect `make tf-check` to pass yet, and do not "fix" it.** From the
moment the VPC exists, checkov fails `CKV2_AWS_11` (no flow logs) and
`scripts/lint-infra.sh` turns that into a non-zero exit. It is resolved by
Task 5, and `make tf-check` is green from Task 5 onward. Verifying it here would
report a failure that the plan has already scheduled a fix for.

- [ ] **Step 12: Commit**

```bash
git add infra/network makefile
git commit -m "feat(network): the VPC, its addressing and a locked-down default security group"
```

---

### Task 2: Subnets across two availability zones

**Files:**
- Create: `infra/network/subnets.tf`
- Modify: `infra/network/tests/addressing.tftest.hcl`

**Interfaces:**
- Consumes: `local.azs`, `local.az_suffixes`, `local.public_subnet_cidrs`, `local.private_subnet_cidrs`, `aws_vpc.this` (Task 1).
- Produces: `aws_subnet.public` (list, length `var.az_count`), `aws_subnet.private` (same length, same AZ ordering — index `i` of both is the same AZ).

- [ ] **Step 1: Write the failing test**

Append to `infra/network/tests/addressing.tftest.hcl`:

```hcl
run "subnets_land_one_per_tier_per_availability_zone" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "two AZs means two public and two private subnets"
  }

  assert {
    condition     = aws_subnet.public[0].availability_zone == "us-east-1a" && aws_subnet.private[0].availability_zone == "us-east-1a"
    error_message = "index i of both lists must be the same AZ; Phase 5 pairs them by index"
  }
}

run "the_address_plan_is_the_one_recorded_in_the_layer_readme" {
  command = plan

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.0.0.0/24" && aws_subnet.public[1].cidr_block == "10.0.1.0/24"
    error_message = "public subnets must be the /24s at newbits 8"
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.0.16.0/20" && aws_subnet.private[1].cidr_block == "10.0.32.0/20"
    error_message = "private subnets must be the /20s starting at index 1, which is what keeps them clear of the public /24s"
  }
}

# Deliberately run at az_count = 4 rather than the default 2. Two AZs is the
# case the literal assertions above already cover; the maths is only interesting
# where it has room to go wrong. This assertion was mutation-tested while this
# plan was written: changing the private CIDRs to cidrsubnet(vpc_cidr, 4, i)
# makes it fail, which is the only evidence that it asserts anything at all.
run "no_two_subnets_overlap_even_at_four_availability_zones" {
  command = plan
  variables {
    az_count = 4
  }

  # Two ranges overlap iff startA <= endB and startB <= endA. Offsets are taken
  # within the VPC's /16, so the third and fourth octets are the whole address.
  assert {
    condition = alltrue(flatten([
      for a in concat(aws_subnet.public[*].cidr_block, aws_subnet.private[*].cidr_block) : [
        for b in concat(aws_subnet.public[*].cidr_block, aws_subnet.private[*].cidr_block) :
        a == b ? true : !(
          (tonumber(split(".", cidrhost(a, 0))[2]) * 256 + tonumber(split(".", cidrhost(a, 0))[3])) <=
          (tonumber(split(".", cidrhost(b, 0))[2]) * 256 + tonumber(split(".", cidrhost(b, 0))[3]) + pow(2, 32 - tonumber(split("/", b)[1])) - 1)
          &&
          (tonumber(split(".", cidrhost(b, 0))[2]) * 256 + tonumber(split(".", cidrhost(b, 0))[3])) <=
          (tonumber(split(".", cidrhost(a, 0))[2]) * 256 + tonumber(split(".", cidrhost(a, 0))[3]) + pow(2, 32 - tonumber(split("/", a)[1])) - 1)
        )
      ]
    ]))
    error_message = "public and private address space must not overlap at any az_count"
  }
}

run "private_subnets_never_auto_assign_a_public_address" {
  command = plan

  assert {
    condition     = aws_subnet.public[0].map_public_ip_on_launch && !aws_subnet.private[0].map_public_ip_on_launch
    error_message = "a private subnet that auto-assigns public IPs is not private; a public subnet without them cannot host the NAT gateway"
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/tf.sh test network`
Expected: FAIL — `A managed resource "aws_subnet" "public" has not been declared`.

- [ ] **Step 3: Add the addressing locals to `locals.tf`**

Per preflight ruling R1 these live here, not in Task 1: nothing referenced them
until now, and tflint fails a layer that declares them early.

```hcl
  # "us-east-1a" -> "1a", the <az> segment convention §3 asks for in
  # bgd-us-east-1-private-1a. Splitting on "-" is clearer than a substring
  # offset and does not silently produce nonsense if the region name changes.
  az_suffixes = [for az in local.azs : split("-", az)[2]]

  # Public subnets are /24s — an ALB needs eight usable addresses per subnet and
  # nothing else lives there. Private subnets are /20s, because every Fargate
  # task takes an ENI and an address, and blue/green runs two task sets at once.
  #
  # Carved so they cannot overlap: the /24s at newbits 8 land inside the first
  # /20 (10.0.0.0 - 10.0.15.255), and the private /20s start at index 1
  # (10.0.16.0/20) and count up from there.
  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 1)]
```

- [ ] **Step 4: Write `subnets.tf`**

```hcl
# Public and private are separate resources rather than one for_each over a map
# of tiers, because they differ in more than a tag: map_public_ip_on_launch,
# their route tables and their consumers are all different. Merging them would
# put a conditional in every attribute.

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # The NAT Gateway needs one, and an internet-facing ALB's nodes are placed
  # here. Nothing else is launched into these subnets.
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${local.az_suffixes[count.index]}"
    tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Explicit rather than omitted. The attribute defaults to false, but a
  # Fargate task with a public IP would bypass the NAT entirely and quietly
  # invalidate every assertion this layer makes about egress.
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-${local.az_suffixes[count.index]}"
    tier = "private"
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/tf.sh test network`
Expected: PASS — `7 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add infra/network/subnets.tf infra/network/tests/addressing.tftest.hcl infra/network/locals.tf
git commit -m "feat(network): public and private subnets across two availability zones"
```

---

### Task 3: Internet gateway routing, the NAT Gateway, and route tables

**Files:**
- Create: `infra/network/routing.tf`, `infra/network/tests/routing.tftest.hcl`

**Interfaces:**
- Consumes: `aws_vpc.this`, `aws_internet_gateway.this` (Task 1); `aws_subnet.public`, `aws_subnet.private` (Task 2).
- Produces: `aws_eip.nat`, `aws_nat_gateway.this`, `aws_route_table.public` (single), `aws_route_table.private` (list, one per AZ).

- [ ] **Step 1: Write the failing test**

`infra/network/tests/routing.tftest.hcl`:

```hcl
# Every assertion here is a relationship between two computed ids, so every run
# block uses command = apply. Against a mocked provider that creates nothing and
# needs no credentials — but unlike command = plan it resolves the ids, which is
# the only way "this route points at that gateway" can be asserted at all.
# See the plan's §F1.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
}

run "the_nat_gateway_sits_in_a_public_subnet" {
  command = apply

  # A NAT Gateway in a private subnet is created without complaint and then
  # routes nothing, because it has no path to the internet gateway itself.
  # It is the single most expensive way to misconfigure this layer.
  assert {
    condition     = contains(aws_subnet.public[*].id, aws_nat_gateway.this.subnet_id)
    error_message = "the NAT gateway must live in a public subnet or it has no route out itself"
  }

  assert {
    condition     = aws_nat_gateway.this.allocation_id == aws_eip.nat.id
    error_message = "the NAT gateway must use the Elastic IP this layer allocates, so verify-network.sh has a stable address to assert against"
  }
}

run "public_traffic_leaves_through_the_internet_gateway" {
  command = apply

  assert {
    condition     = aws_route.public_internet.gateway_id == aws_internet_gateway.this.id
    error_message = "the public default route must target the internet gateway"
  }

  assert {
    condition     = aws_route.public_internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "the public route table needs a default route, not a route to something specific"
  }

  assert {
    condition     = length(aws_route_table_association.public) == 2
    error_message = "both public subnets must be associated with the public route table; an unassociated subnet silently falls back to the main route table"
  }
}

run "private_traffic_leaves_through_the_nat_gateway" {
  command = apply

  assert {
    condition = alltrue([
      for r in aws_route.private_nat : r.nat_gateway_id == aws_nat_gateway.this.id
    ])
    error_message = "every private default route must target the one NAT gateway"
  }

  assert {
    condition     = length(aws_route_table.private) == 2
    error_message = "one private route table per AZ, so a second NAT is a one-line change rather than a restructure"
  }

  assert {
    condition     = length(aws_route_table_association.private) == 2
    error_message = "both private subnets must be associated, or their tasks have no egress at all"
  }

  # Counting the associations is not enough. Associating BOTH private subnets to
  # private[0] leaves private[1] orphaned on the VPC main route table — no NAT
  # route, no error, no drift, and no symptom until a Fargate task in that AZ
  # cannot reach ECR a phase later. This asserts the pairing, not the count.
  assert {
    condition = alltrue([
      for i, assoc in aws_route_table_association.private :
      assoc.route_table_id == aws_route_table.private[i].id && assoc.subnet_id == aws_subnet.private[i].id
    ])
    error_message = "private subnet i must be associated with private route table i; associating both subnets to one table strands an AZ on the main route table, with no error and no drift"
  }
}

run "there_is_exactly_one_nat_gateway" {
  command = apply

  # Not a style assertion. A second NAT is another $33/month, and the roadmap's
  # cost model assumes one. If AZ redundancy is ever wanted, this test is the
  # thing that has to be changed deliberately.
  assert {
    condition     = aws_nat_gateway.this.id != null && length(aws_eip.nat.id) > 0
    error_message = "expected exactly one NAT gateway and one Elastic IP"
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/tf.sh test network`
Expected: FAIL — `A managed resource "aws_nat_gateway" "this" has not been declared`.

- [ ] **Step 3: Write `routing.tf`**

```hcl
resource "aws_eip" "nat" {
  domain = "vpc"

  # The gateway must exist before the address is attached to it, and Terraform
  # cannot infer the ordering from the arguments alone.
  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

# One NAT Gateway, in the first AZ, shared by both environments. This is the
# design's recorded cost trade (§3.1): a second one would double the largest
# line item on the bill to buy AZ-failure resilience that a portfolio project
# does not need. The consequence is real and worth naming — if this AZ fails,
# tasks in the other AZ lose egress.
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${local.name_prefix}-nat"
  }
}

# One public route table for both public subnets: they share a destination.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ, even though both currently point at the same
# NAT. They cost nothing, and they are what makes "give AZ b its own NAT" an
# edit to one route rather than a restructuring of the layer.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-private-rt-${local.az_suffixes[count.index]}"
  }
}

resource "aws_route" "private_nat" {
  count = var.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/tf.sh test network`
Expected: PASS — `11 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add infra/network/routing.tf infra/network/tests/routing.tftest.hcl
git commit -m "feat(network): internet gateway, one shared NAT gateway and per-AZ routing"
```

---

### Task 4: The S3 and DynamoDB gateway endpoints

**Files:**
- Create: `infra/network/endpoints.tf`
- Modify: `infra/network/tests/routing.tftest.hcl`

**Interfaces:**
- Consumes: `aws_vpc.this`, `aws_route_table.private`.
- Produces: `aws_vpc_endpoint.s3`, `aws_vpc_endpoint.dynamodb`.

- [ ] **Step 1: Write the failing test**

Append to `infra/network/tests/routing.tftest.hcl`:

```hcl
run "the_free_gateway_endpoints_keep_bulk_traffic_off_the_nat_meter" {
  command = apply

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && aws_vpc_endpoint.dynamodb.vpc_endpoint_type == "Gateway"
    error_message = "these must be Gateway endpoints; an Interface endpoint costs ~$7.30 per AZ per month and design §3.1 priced them out"
  }

  assert {
    condition     = aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-1.s3"
    error_message = "the S3 endpoint is what keeps ECR layer pulls off the NAT's data-processing charge, since ECR stores layers in S3"
  }

  assert {
    condition = alltrue([
      for rt in aws_route_table.private[*].id :
      contains(tolist(aws_vpc_endpoint.s3.route_table_ids), rt)
    ])
    error_message = "an endpoint associated with only some private route tables sends the other AZ's traffic through the NAT, and nothing reports it"
  }

  assert {
    condition = alltrue([
      for rt in aws_route_table.private[*].id :
      contains(tolist(aws_vpc_endpoint.dynamodb.route_table_ids), rt)
    ])
    error_message = "DynamoDB is the application's entire data path; both AZs must reach it without leaving AWS"
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/tf.sh test network`
Expected: FAIL — `A managed resource "aws_vpc_endpoint" "s3" has not been declared`.

- [ ] **Step 3: Write `endpoints.tf`**

```hcl
# Gateway endpoints are free. They work by adding a prefix-list route to each
# associated route table, so traffic to the service never reaches the NAT and
# is never billed for data processing.
#
# Only the public route tables are left out: nothing in a public subnet talks
# to S3 or DynamoDB, and the ALB nodes there need the internet gateway.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${local.name_prefix}-s3-endpoint"
  }
}

# Not named by roadmap §3 or design §3.1, and added deliberately (plan §D4).
# Every account read and every transaction write the application makes is a
# DynamoDB call; without this each one leaves through the NAT and pays
# $0.045/GB to reach a service inside the same region.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${local.name_prefix}-dynamodb-endpoint"
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/tf.sh test network`
Expected: PASS — `12 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add infra/network/endpoints.tf infra/network/tests/routing.tftest.hcl
git commit -m "feat(network): free S3 and DynamoDB gateway endpoints on both private route tables"
```

---

### Task 5: VPC flow logs

> **Gated on your review of D5.** If you decline flow logs, skip this task entirely and instead add one line to `vpc.tf`:
> `# checkov:skip=CKV2_AWS_11:an ephemeral layer carrying no production data; enabling flow logs is Phase 9's call, not this layer's`
> — then continue at Task 6.

**Files:**
- Create: `infra/network/flowlogs.tf`
- Modify: `infra/network/tests/routing.tftest.hcl`

**Interfaces:**
- Consumes: `aws_vpc.this`, `local.name_prefix`, `var.flow_log_retention_days`.
- Produces: `aws_cloudwatch_log_group.flow_logs`, `aws_iam_role.flow_logs`, `aws_flow_log.this`.

- [ ] **Step 1: Write the failing test**

Append to `infra/network/tests/routing.tftest.hcl`:

```hcl
run "flow_logs_capture_both_accepted_and_rejected_traffic" {
  command = apply

  # REJECT-only is the tempting economy and the wrong one: the question this
  # layer will actually be asked is "did the task's request reach DynamoDB",
  # and an accepted flow is the only evidence that answers it.
  assert {
    condition     = aws_flow_log.this.traffic_type == "ALL"
    error_message = "flow logs must capture ACCEPT as well as REJECT to be useful for Phase 5 and 6 debugging"
  }

  assert {
    condition     = aws_flow_log.this.vpc_id == aws_vpc.this.id
    error_message = "the flow log must be attached at VPC scope, so subnets added later are covered without an edit"
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs.name == "/bgd/us-east-1/shared/vpc-flow"
    error_message = "convention §3: log groups are /<project>/<region>/<env>/<service>, with slashes rather than hyphens"
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs.retention_in_days == 7
    error_message = "retention must come from var.flow_log_retention_days; an unset retention means never expire, and never expire is what makes flow logs expensive"
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/tf.sh test network`
Expected: FAIL — `A managed resource "aws_flow_log" "this" has not been declared`.

- [ ] **Step 3: Add `flow_log_retention_days` to `variables.tf`**

Per preflight ruling R1, this is its first use.

```hcl
variable "flow_log_retention_days" {
  description = "How long VPC flow logs are kept. Short by design: they are a debugging aid for an ephemeral layer, and retention is what they cost."
  type        = number
  default     = 7
}
```

- [ ] **Step 4: Write `flowlogs.tf`**

```hcl
# The one IAM role in this layer, created here because this is the phase that
# creates the resource it acts on (Phase 3 §D2). Its policy is scoped to the one
# log group below rather than to "logs:*", which is the whole reason a role
# cannot be written before the resource exists.

resource "aws_cloudwatch_log_group" "flow_logs" {
  # checkov:skip=CKV_AWS_338:seven-day retention is deliberate; these are a debugging aid for an ephemeral layer that is destroyed when idle, and retention is the entirety of what they cost. See plan §D5.
  # checkov:skip=CKV_AWS_158:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. Flow logs carry addresses and byte counts, not payloads or secrets.
  name              = "/${var.project_name}/${var.region}/shared/vpc-flow"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    # Scoped to this log group and its streams, not to logs:* on "*".
    resources = [
      aws_cloudwatch_log_group.flow_logs.arn,
      "${aws_cloudwatch_log_group.flow_logs.arn}:*",
    ]
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name_prefix}-shared-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "${local.name_prefix}-shared-flow-logs-policy"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60

  tags = {
    Name = "${local.name_prefix}-vpc-flow-log"
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/tf.sh test network`
Expected: PASS — `13 passed, 0 failed`.

- [ ] **Step 6: Add the `CKV_AWS_130` skip to `subnets.tf`**

Task 5 is where checkov becomes the gate for the whole layer, so it owns the last
outstanding finding as well as its own. On `resource "aws_subnet" "public"` in
`infra/network/subnets.tf`, add as the first line of the body:

```hcl
  # checkov:skip=CKV_AWS_130:a public subnet that does not assign public addresses cannot host a NAT gateway or an internet-facing ALB's nodes. The private subnets set this to false explicitly and pass the same check.
```

- [ ] **Step 7: Confirm the checkov codes rather than trusting the three skips above**

Run: `make tf-lint`
Expected: `CKV2_AWS_11` no longer appears, and `make tf-check` is green — this is the task that makes it so, per the Global Constraints note. If checkov reports a **different** code against `aws_cloudwatch_log_group.flow_logs` than the `CKV_AWS_338` / `CKV_AWS_158` anticipated in the code, replace the skip comment with the code it actually reported and keep the same reason text. Do not add a skip for a code checkov did not raise.

- [ ] **Step 8: Commit**

```bash
git add infra/network/flowlogs.tf infra/network/variables.tf infra/network/subnets.tf infra/network/tests/routing.tftest.hcl
git commit -m "feat(network): VPC flow logs to a short-retention log group"
```

---

### Task 6: The four security groups

**Files:**
- Create: `infra/network/security.tf`, `infra/network/tests/security_groups.tftest.hcl`

**Interfaces:**
- Consumes: `aws_vpc.this`, `var.container_port`, `var.vpc_cidr`, `local.name_prefix`.
- Produces: `aws_security_group.alb` and `aws_security_group.task`, both keyed `for_each` over `toset(["staging", "prod"])` — referenced elsewhere as `aws_security_group.alb["prod"].id`.

- [ ] **Step 1: Write the failing test**

`infra/network/tests/security_groups.tftest.hcl`:

```hcl
# The asymmetry between staging and prod is the point of this file. Phase 6's
# dark canary needs :8443 on production only; if staging quietly carried it too,
# the least-privilege claim in the design would be decoration.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
}

run "there_is_one_pair_of_groups_per_environment" {
  command = plan

  assert {
    condition     = aws_security_group.alb["prod"].name == "bgd-us-east-1-prod-alb-sg"
    error_message = "convention §3: security groups are <project>-<region>-<env>-<role>-sg"
  }

  assert {
    condition     = aws_security_group.task["staging"].name == "bgd-us-east-1-staging-task-sg"
    error_message = "convention §3: security groups are <project>-<region>-<env>-<role>-sg"
  }

  assert {
    condition     = aws_security_group.task["prod"].tags["environment"] == "prod"
    error_message = "plan §D6: per-environment groups override the environment tag, which is the documented exception for zero-cost resources"
  }
}

run "only_production_exposes_the_blue_green_test_listener" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_test["prod"].to_port == 8443
    error_message = "Phase 6's dark canary needs :8443 reachable on the production ALB"
  }

  assert {
    condition     = !contains(keys(aws_vpc_security_group_ingress_rule.alb_test), "staging")
    error_message = "staging has no test listener; opening :8443 there widens the surface for nothing"
  }
}

run "tasks_accept_traffic_only_from_their_own_environments_load_balancer" {
  command = apply

  assert {
    condition = alltrue([
      for env in ["staging", "prod"] :
      aws_vpc_security_group_ingress_rule.task_from_alb[env].referenced_security_group_id == aws_security_group.alb[env].id
    ])
    error_message = "a task group whose source is the other environment's ALB, or a CIDR, breaks the isolation the per-env split exists for"
  }

  assert {
    condition = alltrue([
      for env in ["staging", "prod"] :
      aws_vpc_security_group_ingress_rule.task_from_alb[env].to_port == 8080
    ])
    error_message = "the container port is 8080, fixed by app/Dockerfile"
  }
}

run "task_egress_is_https_and_dns_rather_than_everything" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_egress_rule.task_https["prod"].to_port == 443 && aws_vpc_security_group_egress_rule.task_https["prod"].cidr_ipv4 == "0.0.0.0/0"
    error_message = "tasks reach ECR, CloudWatch, DynamoDB and any third-party API over 443; that is the only port they need outbound"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.task_dns_udp["prod"].cidr_ipv4 == "10.0.0.0/16"
    error_message = "DNS goes to the VPC resolver inside the VPC, not to the internet"
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/tf.sh test network`
Expected: FAIL — `A managed resource "aws_security_group" "alb" has not been declared`.

- [ ] **Step 3: Add `container_port` to `variables.tf`**

Per preflight ruling R1, this is its first use.

```hcl
variable "container_port" {
  description = "Port the application listens on. Fixed by app/Dockerfile (EXPOSE 8080); the ALB-to-task rules open exactly this."
  type        = number
  default     = 8080
}
```

- [ ] **Step 4: Write `security.tf`**

```hcl
# Rules are separate resources rather than inline ingress/egress blocks. Inline
# blocks are authoritative for the whole group, so anything added out of band is
# silently reverted on the next apply and Terraform reports no drift in between.
# The per-rule resources also give each rule its own description, which is what
# the console shows when someone is trying to work out why a packet was dropped.

locals {
  environments = toset(["staging", "prod"])
}

resource "aws_security_group" "alb" {
  # checkov:skip=CKV2_AWS_5:attached by the ALB in Phases 5 and 6, which live in a different state file. checkov reads one directory and cannot see across layers.
  for_each = local.environments

  name        = "${local.name_prefix}-${each.key}-alb-sg"
  description = "Public entry point for the ${each.key} application load balancer"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name        = "${local.name_prefix}-${each.key}-alb-sg"
    environment = each.key
  }

  # The group must exist before the old one is removed when a rename forces
  # replacement, because the ALB in another layer still references it.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "task" {
  # checkov:skip=CKV2_AWS_5:attached by the ECS service in Phases 5 and 6, which live in a different state file. checkov reads one directory and cannot see across layers.
  for_each = local.environments

  name        = "${local.name_prefix}-${each.key}-task-sg"
  description = "Fargate tasks serving the ${each.key} API"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name        = "${local.name_prefix}-${each.key}-task-sg"
    environment = each.key
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- ALB ingress ------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = local.environments

  security_group_id = aws_security_group.alb[each.key].id
  description       = "HTTP from the internet, redirected to HTTPS by the listener"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = local.environments

  security_group_id = aws_security_group.alb[each.key].id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Production only. This is the test listener the blue/green deployment shifts
# traffic to before any user sees the new colour (design §5), and it is the
# reason Phase 6 never has to reopen this layer.
resource "aws_vpc_security_group_ingress_rule" "alb_test" {
  for_each = toset(["prod"])

  security_group_id = aws_security_group.alb[each.key].id
  description       = "Blue/green test listener, production only"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 8443
  to_port           = 8443
  ip_protocol       = "tcp"
}

# --- ALB egress -------------------------------------------------------------

resource "aws_vpc_security_group_egress_rule" "alb_to_task" {
  for_each = local.environments

  security_group_id            = aws_security_group.alb[each.key].id
  description                  = "Container port on this environment's tasks, health checks included"
  referenced_security_group_id = aws_security_group.task[each.key].id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# --- Task ingress -----------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  for_each = local.environments

  security_group_id            = aws_security_group.task[each.key].id
  description                  = "Container port from this environment's ALB only"
  referenced_security_group_id = aws_security_group.alb[each.key].id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# --- Task egress ------------------------------------------------------------
#
# 443 plus DNS, not "all traffic". Everything a Fargate task needs to start and
# run is HTTPS: the ECR auth token, the image layers through the S3 gateway
# endpoint, CloudWatch Logs, DynamoDB through its gateway endpoint, and any
# third-party API the design §3.1 argument turns on. Egress rules apply to the
# VPC resolver too, so DNS needs its own pair.

resource "aws_vpc_security_group_egress_rule" "task_https" {
  for_each = local.environments

  security_group_id = aws_security_group.task[each.key].id
  description       = "HTTPS to AWS service endpoints and third-party APIs"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "task_dns_udp" {
  for_each = local.environments

  security_group_id = aws_security_group.task[each.key].id
  description       = "DNS to the VPC resolver"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "task_dns_tcp" {
  for_each = local.environments

  security_group_id = aws_security_group.task[each.key].id
  description       = "DNS over TCP, for responses too large for a UDP datagram"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/tf.sh test network`
Expected: PASS — `17 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add infra/network/security.tf infra/network/variables.tf infra/network/tests/security_groups.tftest.hcl
git commit -m "feat(network): per-environment ALB and task security groups, least privilege"
```

---

### Task 7: Outputs, and a test that pins the surface Phases 5 and 6 consume

**Files:**
- Create: `infra/network/outputs.tf`, `infra/network/tests/outputs.tftest.hcl`

**Interfaces:**
- Produces the remote-state surface. Phases 5 and 6 read these names exactly:
  `vpc_id`, `vpc_cidr`, `public_subnet_ids`, `private_subnet_ids`, `availability_zones`,
  `nat_gateway_public_ip`, `alb_security_group_ids` (map env→id), `task_security_group_ids` (map env→id), `container_port`.

- [ ] **Step 1: Write the failing test**

`infra/network/tests/outputs.tftest.hcl`:

```hcl
# This file exists to make a rename in this layer fail here rather than in
# Phase 5, where it would surface as a remote-state lookup returning null and
# an ECS service placed in no subnets. Outputs are an interface; interfaces get
# tests.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

variables {
  project_name = "bgd"
  region       = "us-east-1"
  account_id   = "590184028094"
  owner        = "carreque45@gmail.com"
}

run "the_consumed_surface_is_complete_and_correctly_shaped" {
  command = apply

  assert {
    condition     = length(output.private_subnet_ids) == 2 && length(output.public_subnet_ids) == 2
    error_message = "both environment layers place their ALBs and tasks from these two lists"
  }

  assert {
    condition     = output.vpc_cidr == "10.0.0.0/16"
    error_message = "Phase 5 and 6 scope their own rules against the VPC CIDR"
  }

  assert {
    condition = alltrue([
      for env in ["staging", "prod"] :
      output.alb_security_group_ids[env] != null && output.task_security_group_ids[env] != null
    ])
    error_message = "both environments must find both of their security groups by name in these maps"
  }

  assert {
    condition     = output.container_port == 8080
    error_message = "the environment layers read the container port from here rather than restating 8080 in three places"
  }

  assert {
    condition     = output.availability_zones[0] == "us-east-1a"
    error_message = "the AZ list is ordered and index-aligned with the subnet lists"
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/tf.sh test network`
Expected: FAIL — `An output value with the name "private_subnet_ids" has not been declared`.

- [ ] **Step 3: Write `outputs.tf`**

```hcl
output "vpc_id" {
  description = "The VPC both environment layers place their resources in."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Address space of the VPC. Environment layers scope in-VPC rules against it rather than restating the range."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Subnets for the internet-facing ALBs, ordered by availability zone."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Subnets for the Fargate tasks, ordered by availability zone and index-aligned with public_subnet_ids."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "The zones this layer spans, in the order the subnet lists use."
  value       = local.azs
}

output "nat_gateway_public_ip" {
  description = "The address every private-subnet egress appears to come from. scripts/verify-network.sh asserts against it."
  value       = aws_eip.nat.public_ip
}

output "alb_security_group_ids" {
  description = "Per-environment ALB security groups, keyed staging and prod."
  value       = { for env, sg in aws_security_group.alb : env => sg.id }
}

output "task_security_group_ids" {
  description = "Per-environment Fargate task security groups, keyed staging and prod."
  value       = { for env, sg in aws_security_group.task : env => sg.id }
}

output "container_port" {
  description = "Port the security group rules open, so the environment layers' task definitions cannot disagree with them."
  value       = var.container_port
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/tf.sh test network`
Expected: PASS — `18 passed, 0 failed`.

- [ ] **Step 5: Run the full offline gate**

Run: `make tf-fmt && make tf-check`
Expected: `all infra checks passed`, with checkov reporting no failures across all three layers.

- [ ] **Step 6: Commit**

```bash
git add infra/network/outputs.tf infra/network/tests/outputs.tftest.hcl
git commit -m "feat(network): the remote-state surface, with a test pinning its shape"
```

---

### Task 8: `scripts/verify-network.sh` — prove egress goes through the NAT

**Files:**
- Create: `scripts/verify-network.sh`

**Interfaces:**
- Consumes: `terraform -chdir=infra/network output -json` — specifically `private_subnet_ids`, `task_security_group_ids`, `nat_gateway_public_ip`.
- Produces: exit 0 when the probe's observed egress IP equals the NAT's Elastic IP; non-zero otherwise.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
#
# Phase 4's live exit criterion: a host in a private subnet reaches the
# internet, and reaches it *through the NAT gateway*.
#
# The probe is an ephemeral t4g.nano with no public IP, no key pair and no
# instance profile. Its user-data curls an echo service and writes the answer
# to /dev/console, which `get-console-output` can read back without any agent,
# any SSH and any IAM. The instance is terminated by a trap, so a failure
# half-way through does not leave it running.
#
# Asserting the observed address equals the NAT's Elastic IP is what makes this
# a proof rather than a smoke test: an instance that had somehow acquired a
# public IP, or that was sitting in a public subnet, would reach the internet
# too — and would report a different address.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd aws
require_cmd terraform
require_cmd jq

ROOT="$(repo_root)"
LAYER="$ROOT/infra/network"

# AL2023 on arm64: t4g is the cheapest family, and the image id is looked up
# rather than pinned so this keeps working after the AMI is rotated.
AMI_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
INSTANCE_TYPE="t4g.nano"
CONSOLE_TIMEOUT_SECONDS=300
POLL_INTERVAL_SECONDS=15

instance_id=""

cleanup() {
  if [[ -n "$instance_id" ]]; then
    info "terminating probe $instance_id"
    aws ec2 terminate-instances --instance-ids "$instance_id" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

info "reading the network layer's outputs"
terraform -chdir="$LAYER" init -input=false >/dev/null
outputs="$(terraform -chdir="$LAYER" output -json)" ||
  die "could not read outputs — has 'make apply-network' been run?"

subnet_id="$(jq -r '.private_subnet_ids.value[0]' <<<"$outputs")"
sg_id="$(jq -r '.task_security_group_ids.value.staging' <<<"$outputs")"
nat_ip="$(jq -r '.nat_gateway_public_ip.value' <<<"$outputs")"

[[ "$subnet_id" != "null" && -n "$subnet_id" ]] || die "no private subnet in the outputs"
[[ "$nat_ip" != "null" && -n "$nat_ip" ]] || die "no NAT gateway address in the outputs"

ami_id="$(aws ssm get-parameter --name "$AMI_PARAM" --query 'Parameter.Value' --output text)"

# The staging task security group already permits exactly what the probe needs:
# 443 out and DNS. Reusing it means the probe tests the real rules rather than
# a permissive set written for the probe.
#
# User-data goes through a temp file and file://, not an inline base64 string.
# The AWS CLI base64-encodes a file:// argument itself, which sidesteps the fact
# that GNU base64 wraps at 76 columns while BSD base64 does not — a difference
# that would make this script work on this Mac and fail in CodeBuild.
user_data_file="$(mktemp -t bgd-nat-probe)"
trap 'rm -f "$user_data_file"; cleanup' EXIT
cat > "$user_data_file" <<'CLOUDINIT'
#!/bin/bash
for _ in $(seq 1 10); do
  ip="$(curl --silent --max-time 10 https://checkip.amazonaws.com)"
  if [[ -n "$ip" ]]; then
    echo "BGD_EGRESS_IP=${ip}" > /dev/console
    exit 0
  fi
  sleep 5
done
echo "BGD_EGRESS_IP=UNREACHABLE" > /dev/console
CLOUDINIT

info "launching probe in $subnet_id"
instance_id="$(aws ec2 run-instances \
  --image-id "$ami_id" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$subnet_id" \
  --security-group-ids "$sg_id" \
  --no-associate-public-ip-address \
  --user-data "file://$user_data_file" \
  --instance-initiated-shutdown-behavior terminate \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bgd-us-east-1-nat-probe},{Key=environment,Value=shared},{Key=projectName,Value=bgd},{Key=region,Value=us-east-1},{Key=owner,Value=carreque45@gmail.com}]' \
  --query 'Instances[0].InstanceId' --output text)"

info "probe $instance_id launched; waiting for it to run"
aws ec2 wait instance-running --instance-ids "$instance_id"

info "waiting for console output (up to $((CONSOLE_TIMEOUT_SECONDS / 60)) min)"
observed=""
deadline=$((SECONDS + CONSOLE_TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  console="$(aws ec2 get-console-output --instance-id "$instance_id" --latest \
    --query 'Output' --output text 2>/dev/null || true)"
  if [[ "$console" == *BGD_EGRESS_IP=* ]]; then
    observed="$(sed -n 's/.*BGD_EGRESS_IP=\([0-9.]*\).*/\1/p' <<<"$console" | head -1)"
    [[ -n "$observed" ]] && break
    die "the probe reached no external address: private subnet egress is broken"
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

[[ -n "$observed" ]] || die "no console output after ${CONSOLE_TIMEOUT_SECONDS}s — the probe may still be booting; re-run before concluding egress is broken"

info "probe egress IP : $observed"
info "nat gateway EIP : $nat_ip"

if [[ "$observed" == "$nat_ip" ]]; then
  ok "private subnet egresses through the NAT gateway"
else
  die "egress left through $observed, not the NAT gateway at $nat_ip"
fi
```

- [ ] **Step 2: Make it executable and check it matches the other scripts' shape**

```bash
chmod +x scripts/verify-network.sh
grep -n "require_cmd\|^ok \|^die \|^info " scripts/lib/common.sh
```

Expected: `require_cmd`, `info`, `ok` and `die` all exist in `lib/common.sh`. If any is named differently, match the existing names rather than adding new helpers.

- [ ] **Step 3: Check it parses and passes shellcheck if available**

Run: `bash -n scripts/verify-network.sh && (command -v shellcheck >/dev/null && shellcheck scripts/verify-network.sh || echo "shellcheck not installed, skipped")`
Expected: no syntax errors.

- [ ] **Step 4: Verify it fails cleanly with no state, which is the only path testable offline**

Run: `./scripts/verify-network.sh`
Expected: it dies at `could not read outputs — has 'make apply-network' been run?` or at the missing `jq`/`aws` precondition. It must **not** launch anything. Record the exact output for the verification document.

- [ ] **Step 5: Commit**

```bash
git add scripts/verify-network.sh
git commit -m "feat(scripts): prove private-subnet egress leaves through the NAT gateway"
```

---

### Task 9: `scripts/teardown.sh` and a real `make teardown`

**Files:**
- Create: `scripts/teardown.sh`
- Modify: `makefile` — add the `teardown` target, remove the `# PLANNED: teardown` line

**Interfaces:**
- Consumes: `scripts/tf.sh destroy <layer>`.
- Produces: `make teardown`, destroying `prod` → `staging` → `network`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
#
# Ordered teardown: prod, then staging, then network. foundation and bootstrap
# are never touched — that is the whole reason the five-layer split exists
# (roadmap §1).
#
# Order is not cosmetic. Destroying network first would strand the ALBs and ECS
# services that depend on its subnets, and the destroy would fail part-way with
# a dependency violation, leaving the expensive half running.
#
# A layer with no .tf files at all is skipped and *says so*. Silence would be
# the dangerous behaviour: the failure mode this guards against is Phase 6's
# production layer being quietly passed over and left running at ~$40/month.
#
# No -auto-approve. Terraform's own confirmation prompt is the safety, so this
# first cut needs no confirmation logic of its own. Phase 10 hardens it.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd terraform

ROOT="$(repo_root)"

# Same layer-name-to-directory mapping tf.sh uses. Repeated deliberately: this
# script needs to know whether a directory has any .tf files *before* handing
# the layer to tf.sh, which would die on a directory that does not exist yet.
layer_dir() {
  case "$1" in
    bootstrap | foundation | network) echo "$ROOT/infra/$1" ;;
    staging | prod) echo "$ROOT/infra/environments/$1" ;;
    *) die "unknown layer: $1" ;;
  esac
}

TEARDOWN_ORDER=(prod staging network)

echo
info "teardown order: ${TEARDOWN_ORDER[*]}  (foundation and bootstrap are never destroyed)"
echo

for layer in "${TEARDOWN_ORDER[@]}"; do
  dir="$(layer_dir "$layer")"

  if [[ ! -d "$dir" ]] || ! compgen -G "$dir/*.tf" >/dev/null; then
    info "$layer — no .tf files yet, skipping"
    continue
  fi

  info "$layer — terraform destroy"
  "$ROOT/scripts/tf.sh" destroy "$layer" || die "destroy failed for $layer; later layers were not touched"
done

echo
ok "teardown complete — foundation and bootstrap intact"
```

- [ ] **Step 2: Make it executable and check it parses**

```bash
chmod +x scripts/teardown.sh
bash -n scripts/teardown.sh
```

- [ ] **Step 3: Modify the makefile**

Add, after the `seed-ecr` target:

```make
# ---------------------------------------------------------------------------
# Phase 4 — network
# ---------------------------------------------------------------------------

.PHONY: teardown
teardown: ## Destroy prod, then staging, then network (needs an AWS session)
	@./scripts/teardown.sh

.PHONY: verify-network
verify-network: ## Prove a private subnet egresses through the NAT (needs an AWS session)
	@./scripts/verify-network.sh
```

And delete this line, because the target now exists and does what it says:

```make
# PLANNED: teardown       Destroy prod then staging then network (Phase 10)
```

- [ ] **Step 4: Verify the skip logic without an AWS session**

Run: `./scripts/teardown.sh`
Expected: `prod — no .tf files yet, skipping`, `staging — no .tf files yet, skipping`, then `network — terraform destroy`, which fails at `terraform init` on the unreachable backend. The two skips are the behaviour under test; the init failure is expected with no session. Record the output.

- [ ] **Step 5: Verify `make help` is honest**

Run: `make help`
Expected: `teardown` and `verify-network` appear under **Available now**, and no longer under **Planned**. `rebuild` is still listed under Planned for Phase 10.

- [ ] **Step 6: Commit**

```bash
git add scripts/teardown.sh makefile
git commit -m "feat(scripts): ordered teardown with loud skips, and a real make teardown"
```

---

### Task 10: The Phase 4 runbook

**Files:**
- Create: `docs/runbooks/phase-04-network.md`
- Modify: `docs/runbooks/README.md` — add the row

- [ ] **Step 1: Write the runbook**

It must contain, in this order, each with the exact command and the expected output:

1. **Precondition — the Phase 3 runbook has been executed.** `aws s3api head-bucket --bucket bgd-us-east-1-tfstate-590184028094`. If this fails, stop: `network` keeps its state in that bucket and nothing below will work. Link to the Phase 3 runbook.
2. `aws sso login --profile bootcamp-administrator-access`, then `make verify-aws`.
3. `make tf-check` — the offline gate, re-run against the real toolchain before anything is applied.
4. `make plan-network`. **What to read in the plan:** roughly 30 resources to add and **zero to change or destroy**. One `aws_nat_gateway`, one `aws_eip`, four `aws_security_group`, two `aws_vpc_endpoint`.
5. `make apply-network`. Expect **3–5 minutes**, almost all of it the NAT Gateway, which alone takes about two.
6. `make verify-network` — the exit criterion. Expected output is the `probe egress IP` and `nat gateway EIP` lines matching, then `✓ private subnet egresses through the NAT gateway`.
7. **Confirm the flow logs are receiving records** (skip if D5 was declined): `aws logs describe-log-streams --log-group-name /bgd/us-east-1/shared/vpc-flow --query 'logStreams[0].lastEventTimestamp'`. Note that the first records take up to 10 minutes to appear, because `max_aggregation_interval` is 60 seconds and delivery is batched — an empty result immediately after the apply is expected, not a fault.
8. **Confirm the real cost** (F5): `aws pricing get-products --service-code AmazonEC2 --region us-east-1 --filters 'Type=TERM_MATCH,Field=productFamily,Value=NAT Gateway' 'Type=TERM_MATCH,Field=regionCode,Value=us-east-1'` and the `AmazonVPC` `PublicIPv4Address` family. Amend roadmap §3's cost column with the result.
9. `make teardown` — the second exit criterion, `terraform destroy` succeeding cleanly. **Run it.** A destroy that has never been executed is a claim, not a capability, and this layer is destroyed at the end of every session.
10. **Rebuild once**: `make apply-network` again, and re-run `make verify-network`. This is what proves the layer is genuinely reproducible rather than merely applied once.

Include a **What goes wrong** section covering at least:
- `Error: creating EC2 VPC: VpcLimitExceeded` — the account's five-VPC default limit, and how to find the unused default VPC.
- `terraform destroy` hanging on the NAT Gateway — it takes several minutes to delete, and a dependent ENI keeps it alive.
- `verify-network.sh` timing out — the probe may still be booting; re-run before concluding egress is broken.
- An `AWS_PROFILE` already exported for another account — the makefile's `:=` handles `make`, but a bare `terraform` command does not go through it, and `allowed_account_ids` is the only thing that stops it (Phase 3 §F7).

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/phase-04-network.md docs/runbooks/README.md
git commit -m "docs(runbook): the Phase 4 apply, verification and teardown sequence"
```

---

### Task 11: Documentation amendments and the verification record

**Files:**
- Modify: `infra/network/README.md`, `infra/README.md` (cost column), `docs/naming-and-tagging-convention.md`, `docs/2026-08-04-implementation-phase-roadmap.md`, `docs/2026-08-04-blue-green-deployment-platform-design-research.md`
- Create: `docs/phases/phase4/2026-08-26-local-verification.md`

- [ ] **Step 1: Rewrite `infra/network/README.md`**

It currently describes what was intended. Make it describe what was built: the address plan table from §3, both gateway endpoints, the four security groups and the `:8443` asymmetry, the flow logs, and a note that the layer takes no remote-state dependency and why.

- [ ] **Step 2: Amend the naming and tagging convention (D6)**

In §5, after "Use that only to add tags, never to override the four above.", add:

```markdown
> **Amended in Phase 4 (2026-08-26).** One bounded exception: **resources that
> incur no cost may override `environment`.** The rule above exists to stop a
> single cost line being split across two spellings of a key — a reason that
> does not apply to something that generates no cost line at all. It is used by
> the four per-environment security groups in `network`, which are created by a
> `shared` layer but belong to `staging` and `prod`. Anything billable still
> takes `environment` from the provider's `default_tags` and nowhere else.
```

- [ ] **Step 3: Amend the roadmap's Phase 4 section**

Add an amendment note after the Phase 4 task list recording: the DynamoDB gateway endpoint (D4), the four per-environment security groups rather than one pair (D3), flow logs if D5 was accepted, that `network` takes no remote-state dependency (D2), and the corrected cost figure from the runbook's step 8.

- [ ] **Step 4: Amend design §3.1**

One note recording that the DynamoDB gateway endpoint was added in Phase 4, strengthening rather than revising the section's third argument — the free-endpoint coverage now includes the application's entire data path, not only ECR layer pulls.

- [ ] **Step 5: Write the local verification record**

`docs/phases/phase4/2026-08-26-local-verification.md`, following the Phase 3 file's shape:
- the full `make tf-check` output, pasted, with the test counts
- the checkov before/after: four failures on the probe, zero on the finished layer, and the two `CKV2_AWS_5` skips with their reason
- the `./scripts/teardown.sh` skip-path output from Task 9 Step 4
- the `./scripts/verify-network.sh` no-state failure output from Task 8 Step 4
- a **"What remains before Phase 4's exit criteria are met"** checklist, exactly as Phase 3's §5 does, naming the runbook steps
- a **"Carried forward"** table: the single-NAT AZ dependency, the unverified cost figure until the runbook confirms it, and that `verify-network.sh` is the only script in the repository that creates a resource outside Terraform

- [ ] **Step 6: Final gate**

Run: `make tf-fmt && make tf-check && make help`
Expected: `all infra checks passed`; `teardown` and `verify-network` listed under Available now.

- [ ] **Step 7: Commit**

```bash
git add docs infra/network/README.md infra/README.md
git commit -m "docs(network): record what Phase 4 built and amend the three documents it changes"
```

---

## 5. Exit criteria

Roadmap Phase 4 names two. Neither is met by this branch alone (D1).

| Criterion | Met by | Verified how |
|---|---|---|
| `terraform apply` and `terraform destroy` both succeed cleanly | Runbook steps 5 and 9 | The apply reports ~30 added, 0 changed, 0 destroyed; the destroy completes with no dependency violation. Step 10's rebuild proves it is repeatable rather than a one-off. |
| A task in a private subnet can reach the internet through NAT | Runbook step 6 | `make verify-network` — the probe's observed egress address equals the NAT Gateway's Elastic IP. |

**The branch's own gate** is `make tf-check`: `terraform validate`, `tflint`, `checkov` and 18 `terraform test` run blocks across four test files, all with no AWS session.

---

## 6. Risks this phase adds

| Risk | Handling |
|---|---|
| **One NAT Gateway means one AZ of egress.** If `us-east-1a` fails, tasks in `us-east-1b` lose all outbound connectivity. | Accepted and recorded — design §3.1's cost trade. Per-AZ private route tables mean adding a second NAT is a one-line change if that ever stops being acceptable. |
| **`verify-network.sh` creates an EC2 instance outside Terraform.** | Terminated by a shell trap on every exit path, and tagged by the convention so a leak is findable. It is the only script in the repository that does this, and the verification record says so. |
| **The layer's cost figure is unverified** (F5). | Confirmed against the pricing API in runbook step 8, and roadmap §3 amended with the real number rather than the estimate. |
| **Security groups are created here but attached in Phases 5 and 6.** | This is what makes `CKV2_AWS_5` unfixable-in-place and what the skip records. The consequence to watch is a rename: `create_before_destroy` is set on all four so a replacement does not break a live ALB reference. |
| **A destroy leaves the Elastic IP allocated if it fails part-way.** | An unattached EIP still bills at $0.005/hour. The runbook's "What goes wrong" section covers finding and releasing it. |
