# infra/modules

Reusable Terraform called by the layer roots. Modules have no state of their own
and are never applied directly.

| Module | Phase |
|---|---|
| `lambda/` | 6, reused in 9 |

Modules are added by the phase that needs them rather than pre-created, so this
directory grows as the project does. Creating empty directories for `alb`,
`ecs-service` or `pipeline` now would assert a decomposition that Phases 5–9 have
not made yet.
