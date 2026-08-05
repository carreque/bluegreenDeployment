# Phase 0 — Verification Findings

**Date:** 2026-08-04
**Branch:** `feat/Phase0_Scaffolding`
**Status:** All seven questions answered
**Plan:** [Phase 0 implementation plan](./2026-08-04-phase-00-implementation-plan.md)

Every question the design rests on, with the command that answered it, the raw output, and what it changes. Where a finding contradicts a design document, the contradiction is stated and the amendment named.

**Headline:** the ECS-native blue/green path is confirmed implementable, and two of the design's carried risks are retired. Three design corrections and one new operational risk came out of it.

---

## A1 — Local toolchain

```bash
git --version; terraform version; python3 --version
docker --version; aws --version; make --version; jq --version
```

| Tool | Design §2 claimed | Actual | Minimum required | Status |
|---|---|---|---|---|
| git | 2.39.1.windows.1 | **2.50.1** (Apple Git-155) | 2.39.0 | ✅ |
| terraform | 1.15.7 | **1.15.7** | 1.10.0 | ✅ |
| python3 | 3.14.6 | **3.14.6** | 3.14.0 | ✅ |
| docker | 29.4.3 | **28.3.2** | 24.0.0 | ✅ |
| aws-cli | 2.15.19 | **2.35.4** | 2.15.0 | ✅ |
| make | not recorded | **3.81** | 3.81 | ✅ |
| jq | not recorded | **1.7.1** | 1.6 | ✅ |

**Answer:** design §2's table was captured on a different machine — the `windows.1` git string gives it away — and initially disagreed on Terraform (1.5.7 installed) and Python (3.12.3). Both were remediated; see the [pyenv finding](#b--the-pin-that-was-not-a-pin) below, which was not a simple install.

**Consequences:**

- Terraform 1.15.7 is above the 1.10 floor, so the S3 backend's `use_lockfile` is available and **design §1.8 stands unamended** — no DynamoDB lock table.
- Python 3.14.6 matches the container target, so **design §1.6's parity argument holds**.
- `make` 3.81 is the GPLv2 version macOS ships. It lacks `.ONESHELL` and `.RECIPEPREFIX` (both 3.82+). The plan's rule — recipes under three lines, logic in `scripts/` — means neither is needed. **No upgrade recommended.**
- Design §2's table should be replaced with the "Actual" column above.

---

## A2 — AWS identity and region

```bash
aws sts get-caller-identity --profile bootcamp-administrator-access
aws configure get region --profile bootcamp-administrator-access
```

```json
{
  "UserId": "AROAYS2NVS67OXH4F3WBU:Carlos",
  "Account": "590184028094",
  "Arn": "arn:aws:sts::590184028094:assumed-role/AWSReservedSSO_AdministratorAccess_3a013d1063b47157/Carlos"
}
```

| | |
|---|---|
| Account | **590184028094** |
| Region | **us-east-1** |
| Role | `AdministratorAccess` via SSO |
| SSO start URL | `https://bootcampblockstellartcq.awsapps.com/start` |

**Answer:** as assumed. Account and region match the design.

**Consequence:** `590184028094` is now a naming input. S3 bucket names are globally unique, so the convention suffixes it — `bgd-foundation-tfstate-590184028094`. It is also the expected-account default in `scripts/verify-aws.sh`.

---

## A3 — Does a hosted zone for `carloscloudengineer.com` already exist?

Three commands, because a zone existing is not the same as it being delegated, and neither is the same as it resolving publicly. All three must agree before ACM validation can succeed.

```bash
aws route53 list-hosted-zones-by-name --dns-name carloscloudengineer.com
aws route53domains get-domain-detail --domain-name carloscloudengineer.com --region us-east-1
dig NS carloscloudengineer.com +short
aws route53 list-resource-record-sets --hosted-zone-id Z01311493LQ7UOIRHM1H9
```

**The zone exists:**

```
Id                       /hostedzone/Z01311493LQ7UOIRHM1H9
Name                     carloscloudengineer.com.
Comment                  HostedZone created by Route53 Registrar
PrivateZone              false
ResourceRecordSetCount   2
```

**All three name-server views agree exactly:**

| Source | Name servers |
|---|---|
| The zone's own NS record set | `ns-450.awsdns-56.com`, `ns-930.awsdns-52.net`, `ns-1470.awsdns-55.org`, `ns-1787.awsdns-31.co.uk` |
| The registrar (`get-domain-detail`) | identical |
| Public DNS (`dig`) | identical |

**Answer: yes — created automatically by the Route 53 registrar, correctly delegated, resolving publicly.**

**Consequences:**

- Phase 3 takes the **adopt** path. Terraform's find-or-create (design §1.7) matches the existing zone and creates nothing.
- `wait_for_validation` can be **`true` on the first apply**. The two-phase apply never happens, and no name servers need updating at the registrar.
- **Design §11's risk "ACM validation hangs on the zone-create path" is retired.** So is roadmap §4's equivalent row.
- No ACM certificates exist in `us-east-1` yet (`aws acm list-certificates` returned `[]`), so Phase 3 issues the first one.

### New risk found here

`get-domain-detail` also reported:

```
AutoRenew        false
ExpirationDate   2026-12-18T18:30:47+01:00
```

**The domain expires 2026-12-18 with auto-renew disabled.** Nothing in Phase 0 depends on it, but every environment's TLS and DNS does from Phase 5 onward. Expiry would take down both environments and invalidate the portfolio evidence. Either enable auto-renew or diarise the renewal — this is a decision for you, not something the IaC can fix.

---

## A4 — Which Python runtimes does Lambda offer?

There is no clean CLI enumeration of managed runtimes. `ListLayers` validates its `--compatible-runtime` argument server-side against the runtime enum, so a deliberately invalid value returns the full set without creating anything:

```bash
aws lambda list-layers --compatible-runtime python3.14   # -> {"Layers": []}, accepted
aws lambda list-layers --compatible-runtime python9.99   # -> ValidationException listing the enum
```

Python entries in the returned enum:

```
python2.7  python3.4  python3.6  python3.7  python3.8  python3.9
python3.10 python3.11 python3.12 python3.13 python3.14 python3.15
```

**Answer: `python3.14` is supported — and `python3.15` already exists.**

**Consequences:**

- The Phase 6 lifecycle hooks and the Phase 9 metrics collector pin to **`python3.14`**, matching the container and local interpreter exactly. No divergence to document.
- **Design §11's risk "Lambda may not offer a Python 3.14 managed runtime" is retired.** So is roadmap §4's equivalent row.

**Caveat, recorded honestly:** this enum includes long-deprecated runtimes (`python2.7`, `nodejs4.3`), so membership proves the identifier is *recognised*, not that it is *creatable for new functions*. `python3.14` sitting between `python3.13` and `python3.15` makes current support near-certain, and Phase 6 confirms it definitively at create time.

---

## A5 — Does AWS provider ≥ 6.4 resolve?

```bash
# throwaway dir, required_providers { aws = ">= 6.4" }
terraform init && terraform version
```

```
- Installing hashicorp/aws v6.57.1...
- Installed hashicorp/aws v6.57.1 (signed by HashiCorp)
Terraform v1.15.7
+ provider registry.terraform.io/hashicorp/aws v6.57.1
```

**Answer: yes — 6.57.1, well above the 6.4 floor** required by design §1.4.

---

## A6 — Does `aws_ecs_service` expose `deployment_configuration` and `lifecycle_hook`?

Checked against the **installed** provider, not the changelog:

```bash
terraform providers schema -json > schema.json
jq '...resource_schemas.aws_ecs_service.block.block_types | keys' schema.json
```

```
alarms                      load_balancer               service_connect_configuration
capacity_provider_strategy  network_configuration       service_registries
deployment_circuit_breaker  ordered_placement_strategy  timeouts
deployment_configuration    placement_constraints       volume_configuration
deployment_controller                                   vpc_lattice_configurations
```

**Answer: yes — but the nesting is not what design §1.4 describes.**

`lifecycle_hook` is **not** a top-level block. It nests **inside** `deployment_configuration`:

```hcl
deployment_configuration {
  strategy             = "BLUE_GREEN"
  bake_time_in_minutes = "5"          # string, not number

  lifecycle_hook {
    hook_target_arn  = "..."          # required
    role_arn         = "..."          # required
    lifecycle_stages = ["..."]        # required, list(string)
    hook_details     = "..."          # optional
  }

  canary_configuration { ... }        # optional, max 1
  linear_configuration { ... }        # optional, max 1
}
```

**Consequences:**

- **Design §1.4 correction.** It reads "`deployment_configuration { strategy = "BLUE_GREEN" }` **plus** `lifecycle_hook` blocks", implying siblings. They are parent and child. Phase 6 writes it as nested.
- Attribute names are **snake_case** (`hook_target_arn`, `role_arn`, `lifecycle_stages`), not the camelCase `hookTargetArn` / `roleArn` / `lifecycleStages` that §1.4 quotes from the changelog.
- `bake_time_in_minutes` is typed **string**, not number.
- `canary_configuration` and `linear_configuration` are present, confirming the October 2025 traffic-shifting strategies of design §1.2 exist in the provider rather than only in release notes. Not required by the current design, but available.

**This retires the highest-stakes risk in Phase 0.** The ECS-native path is implementable; no pivot to the CodeDeploy controller is needed.

---

## A7 — Are the blue/green attribute details present?

```bash
jq '...aws_ecs_service...load_balancer.block.block_types.advanced_configuration' schema.json
jq '...aws_ecs_service...block_types.alarms' schema.json
```

**`load_balancer.advanced_configuration`** (max 1):

| Attribute | Type | Required |
|---|---|---|
| `alternate_target_group_arn` | string | **yes** |
| `production_listener_rule` | string | **yes** |
| `role_arn` | string | **yes** |
| `test_listener_rule` | string | no |

**`alarms`** (max 1):

| Attribute | Type | Required |
|---|---|---|
| `alarm_names` | set(string) | **yes** |
| `enable` | bool | **yes** |
| `rollback` | bool | **yes** |

**Answer: present, with two additions to Phase 6 that the design does not mention.**

**Consequences:**

1. **Listener *rules*, not just listeners.** `production_listener_rule` requires a **rule** ARN. Design §5 specifies only that "the production ALB has two listeners: `:443` production and `:8443` test" — a default listener action is not sufficient. Phase 6 must create `aws_lb_listener_rule` resources on both listeners and pass their ARNs here.
2. **A sixth IAM role.** `advanced_configuration.role_arn` is required — the role the ECS deployment controller assumes to rewrite ALB rules during a traffic shift. Design §8.1 enumerates five roles (CodeBuild, CodePipeline, ECS task execution, ECS task, lifecycle Lambda). This is a sixth.
3. The `alarms` block supports design §7's bake-period automatic rollback exactly as written, via `alarm_names` + `rollback = true`.

---

## B — The pin that was not a pin

Not one of the seven questions, but the most instructive finding of the phase.

Installing Python 3.14.6 under pyenv was not sufficient. `pyenv init` lived in `~/.zshrc`, which zsh sources **only for interactive shells**, so the terminal and everything automated disagreed:

| Shell kind | Before | After |
|---|---|---|
| Interactive | 3.14.6 | 3.14.6 |
| Non-interactive (scripts, `make`) | **3.12.3** | 3.14.6 |
| Login non-interactive | **3.14.5** | 3.14.6 |
| bash launched from login zsh (what a `make` recipe runs in) | **3.12.3** | 3.14.6 |

Three shadowing layers, each fixed:

1. `~/.zprofile` prepended the python.org 3.12 framework to `PATH`.
2. `~/.zprofile` runs `brew shellenv`, which prepends `/opt/homebrew/bin` — and homebrew ships its own python3 (3.14.**5**) — *after* `.zshenv` had set the shims.
3. `~/.zshenv` set `PYTHON` to a file path and then appended `$PYTHON/bin`, producing a `PATH` entry built from a file rather than a directory.

The PATH export moved to `~/.zshenv`; `pyenv init` stays in `~/.zshrc` for the interactive shell function. Dotfiles backed up as `~/.{zshenv,zprofile,zshrc}.bak-phase0`.

### The part worth remembering

A `.python-version` naming a version pyenv does **not** have installed does not fail. The shim falls through to the next `python3` on `PATH` and **exits 0**:

```
$ echo 3.99.0 > .python-version
$ python3 --version
Python 3.14.5          # homebrew's, silently
$ echo $?
0
$ pyenv version
pyenv: version `3.99.0' is not installed (set by .../.python-version)
```

Only `pyenv version` reports it. A pin that reads as a guarantee but silently delivers something else is worse than no pin — which is why `scripts/verify-tools.sh` compares `.python-version` against **what `PATH` actually resolves**, never against `pyenv which python3`. A check that bypassed `PATH` would not have caught any of this.

---

## Summary of changes owed to the design documents

| Document | Section | Change |
|---|---|---|
| Design | §2 | Replace the environment audit table with A1's "Actual" column |
| Design | §1.4 | `lifecycle_hook` nests inside `deployment_configuration`; attributes are snake_case; `bake_time_in_minutes` is a string |
| Design | §5 | Production ALB needs listener **rules**, not only listeners |
| Design | §8.1 | Add a sixth IAM role for the ECS blue/green controller's ALB access |
| Design | §11 | Retire "ACM validation hangs" and "Lambda may not offer 3.14"; add "domain expires 2026-12-18, auto-renew off" |
| Roadmap | §4 | Same two risk retirements, same new risk |
| Roadmap | §2 | Branch table to `feat/PhaseNN_Name` |
