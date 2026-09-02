# infra/modules

Reusable Terraform called by the layer roots. Modules have no state of their own
and are never applied directly.

| Module | Phase |
|---|---|
| `lambda/` | 6, reused in 9 |

Modules are added by the phase that needs them rather than pre-created, so this
directory grows as the project does. Creating empty directories for `alb`,
`ecs-service` or `pipeline` now would assert a decomposition the project has not
made.

It still has not, and that is a decision. The 2026-09-02 environments merge
collapsed `environments/staging/` and `environments/prod/` into the single root
module at `infra/`, and the obvious next step — splitting that root into
`alb`, `ecs`, `dynamodb`, `iam` and so on — was considered and dropped. The
resources are wired tightly enough that the split creates a cycle rather than a
boundary: `iam.tf` needs the log group ARN, `ecs.tf` needs the role ARNs, and a
`modules/iam` and `modules/ecs` pair cannot resolve that without composing ARNs
by hand from names. A module boundary that has to be smuggled past with string
concatenation is not a boundary. One flat root module and one `enable_prod` flag
is the smaller thing.
