# infra/environments

Four files. No Terraform.

```
staging.tfvars        environment = "staging", enable_prod = false, desired_count = 1
staging.backend.hcl   key = "staging/terraform.tfstate"
prod.tfvars           environment = "prod",    enable_prod = true,  desired_count = 2
prod.backend.hcl      key = "prod/terraform.tfstate"
```

This directory used to hold two complete copies of the environment layer,
`staging/` and `prod/`, at roughly 1,500 lines of near-identical Terraform. They
were merged into the single root module at [`../`](../) on 2026-09-02; these four
files are the entire remaining difference between the two environments.

## Which file does what

The `.tfvars` files are the environment's **shape** — what gets built. They are
committed on purpose: nothing in them is a secret, and the shape of an
environment is source. `.gitignore` carries an explicit exception for
`infra/environments/*.tfvars` saying so.

The `.backend.hcl` files are the environment's **state key**. They exist because
`backend "s3"` cannot interpolate, so [`../versions.tf`](../versions.tf) declares
a partial `backend "s3" {}` and the bucket and key arrive as
`terraform init -backend-config=...`.

Neither file carries `image_tag`. That value changes with every build and is the
one input that decides what actually gets deployed, so committing it anywhere
would guarantee it goes stale — see [`../terraform.tfvars.example`](../terraform.tfvars.example).

## The pairing is the dangerous part

A `.tfvars` file and a `.backend.hcl` file must always be used together, and
nothing in Terraform enforces that. Initialising production's backend and then
applying staging's variables is a valid sequence of commands that would plan the
destruction of production.

[`../../scripts/tf.sh`](../../scripts/tf.sh) is what prevents it: it takes one
layer name, derives both files from it, and re-runs `init -reconfigure` on every
invocation. So use the make targets, which go through it:

```bash
make plan-staging
make apply-prod
```

rather than `terraform -chdir=infra ...` by hand. If you do run Terraform
directly, pass both flags together, every time:

```bash
terraform -chdir=infra init -reconfigure \
  -backend-config=environments/prod.backend.hcl
terraform -chdir=infra plan -var-file=environments/prod.tfvars
```

## Adding a third environment

Add `<name>.tfvars` and `<name>.backend.hcl` here, then add the name to
`layer_dir`, `layer_var_file` and `layer_backend_config` in
[`../../scripts/lib/common.sh`](../../scripts/lib/common.sh) and to `TF_LAYERS`
in the [`makefile`](../../makefile). `var.environment`'s validation block in
[`../variables.tf`](../variables.tf) also lists the accepted names, because
`foundation` exports one hostname output per environment.
