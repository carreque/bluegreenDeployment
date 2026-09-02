# infra

Terraform, split into **five deployable layers across four root modules**. Each
layer has its own state file; `modules/` holds reusable code that is never
applied directly.

| Layer | Root module | Lifetime | Idle cost | Phase |
|---|---|---|---|---|
| `bootstrap/` | `infra/bootstrap` | never destroyed | $0 | 3 |
| `foundation/` | `infra/foundation` | persistent | ~$1/mo | 3 |
| `network/` | `infra/network` | ephemeral | ~$34/mo (unverified — pending [runbook §8](../docs/runbooks/phase-04-network.md)'s pricing-API check) | 4 |
| `staging` | `infra/` | ephemeral | ~$25/mo | 5 |
| `prod` | `infra/` | ephemeral | ~$40/mo | 6 |

The layer split exists because of the destroy-when-idle policy. The NAT Gateway
is the largest idle cost and lives in `network`; the hosted zone, ACM
certificate, ECR images and the CodeConnections link — which needs a manual
console click — live in `foundation`. Separate state files are what let
`terraform destroy` on `network` run without being able to reach any of that.

**Teardown** destroys `prod` → `staging` → `network`. **Rebuild** applies the
reverse. Layers read each other through `terraform_remote_state`.

## The environments share one root module

`staging` and `prod` are the same Terraform. They were two directories,
`environments/staging/` and `environments/prod/`, holding roughly 1,500 lines of
near-identical HCL that had to be edited twice and drifted in the comments; they
were merged on 2026-09-02.

What tells them apart is entirely in `environments/`:

```
infra/
  *.tf                        the environment layer: one copy, both shapes
  tests/
    staging_*.tftest.hcl      17 assertions, enable_prod = false
    prod_*.tftest.hcl         36 assertions, enable_prod = true
  environments/
    staging.tfvars            environment = "staging", enable_prod = false
    staging.backend.hcl       key = "staging/terraform.tfstate"
    prod.tfvars               environment = "prod",    enable_prod = true
    prod.backend.hcl          key = "prod/terraform.tfstate"
```

`var.enable_prod` gates the blue/green machinery and nothing else: the green
target group, the `:8443` test listener and the two listener rules in `alb.tf`;
`BLUE_GREEN` over `ROLLING`, the three `lifecycle_hook` blocks and
`advanced_configuration` in `ecs.tf`; the `bluegreen` and `hook_invoke` roles in
`iam.tf`; all of `hooks.tf`; and all of `alarms.tf`. `variables.tf` carries the
authoritative list.

`var.environment` is a separate question — what the environment is called and
which hostname it answers on — and the two are deliberately independent.

**Every env-varying default is staging's.** An apply that forgets its
`-var-file` under-provisions a staging-shaped environment rather than silently
building production's listeners, Lambdas and alarms.

## Running it

Always through `scripts/tf.sh`, never `terraform -chdir=infra` by hand:

```bash
make plan-staging      # -> scripts/tf.sh plan staging
make apply-prod        # -> scripts/tf.sh apply prod
```

The reason is the one cost of the merge. `backend "s3" {}` in `versions.tf` is
**partial**, because a backend block cannot interpolate and this root is applied
into two different state keys. Nothing in the Terraform binds `prod.tfvars` to
`prod/terraform.tfstate` — `tf.sh` does, by deriving the backend config *and*
the var file from one layer-name argument and re-running `init -reconfigure` on
every invocation. Typed by hand, initialising one environment's backend and then
applying the other's variables is a valid sequence of commands and a
catastrophic one.

`bootstrap`, `foundation` and `network` keep their literal backend blocks. They
are applied once each and have no environment to select.

## The offline gate

```bash
make tf-check          # validate + lint + test, no AWS session needed
```

`TF_ROOTS` in the makefile lists four names, not five: `staging` and `prod`
resolve to the same directory, and `infra/tests/` holds both suites, so one
`terraform test` runs all 53 assertions. Listing both would run all 53 twice.
