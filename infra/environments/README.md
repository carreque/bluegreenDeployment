# infra/environments — Phases 5 and 6

One root module per deployed environment. Both read `foundation` and `network`
through `terraform_remote_state`, and both are destroyed at teardown.

| | `staging/` | `prod/` |
|---|---|---|
| Phase | 5 | 6 |
| Deployment | rolling | **ECS-native blue/green** |
| Listeners | `:443` | `:443` production + `:8443` test |
| Target groups | one | two, blue and green |
| Tasks | 1 | 2 |
| Lifecycle hooks | none | three Lambdas |

Staging is deliberately the simpler of the two. Its job is to fail fast, not to
demonstrate blue/green — keeping it on rolling deployments is what keeps the cost
sane and the blue/green story focused on one place.

`prod/` is the technical centre of the project: the `:8443` test listener is what
makes a dark canary possible, validating the green revision with production-shaped
traffic at zero user impact before any real traffic shifts.
