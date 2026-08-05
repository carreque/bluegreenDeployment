# app

The FastAPI service: domain logic, DynamoDB repository, tests, and the Dockerfile.

| Path | Contents |
|---|---|
| `src/` | Application code — domain layer, repository interface, endpoints |
| `tests/` | pytest suite, running against an in-memory repository fake |

**Phase 1** builds this test-first against DynamoDB Local, with no AWS involvement.
**Phase 2** adds the multi-stage Dockerfile, digest-pinned base image and SBOM.

Endpoints: `/health` (liveness only — never checks DynamoDB, because the ALB
health check must not fail when a dependency hiccups), `/ready` (DynamoDB
reachability), `/version` (version, git SHA, image digest), `/api/accounts`,
`/api/transactions`.

`/version` is load-bearing: during a blue/green shift it is curled against the
`:443` and `:8443` listeners at the same time, and the two different SHAs are the
direct proof of which colour serves whom.
