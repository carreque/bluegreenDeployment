# app

The FastAPI service: domain logic, DynamoDB repository, tests, and the Dockerfile.

| Path | Contents |
|---|---|
| `src/` | Application code — domain layer, repository interface, endpoints |
| `tests/` | pytest suite, running against an in-memory repository fake |

## Commands

Run from the repository root. Every one of them uses `app/.venv/bin/python` by
absolute path, never `python3` on `PATH`.

| Command | What it does |
|---|---|
| `make run-local` | Starts DynamoDB Local, creates both tables, serves the API on `:8080` |
| `make test` | The whole suite with the 90% coverage gate; starts DynamoDB Local first |
| `make lint` | `ruff check` and `ruff format --check` |
| `make local-down` | Stops DynamoDB Local and discards its data |
| `make deps-compile` | Recompiles both hash-pinned requirements locks |

`make run-local` needs `app/.env`; copy it from `app/.env.example`. No AWS
credentials are involved — the repository supplies dummy ones when
`BGD_DYNAMODB_ENDPOINT_URL` is set, because DynamoDB Local accepts any
credentials and rejects none.

## Structure

Three layers with one-way dependencies. `domain/` is pure Python — frozen
dataclasses, invariants, and the use cases in `services.py` — with no boto3 and
no FastAPI import anywhere in it. `repository/` defines one `LedgerRepository`
Protocol with two implementations, an in-memory fake and a DynamoDB one, both
held to the single contract suite in `tests/contract/`; that shared suite is
what makes the fake trustworthy enough for every layer above it to use. `api/`
holds the FastAPI routers, the RFC 9457 error envelope and JSON access logging,
and receives its repository by injection, so no API test ever touches boto3.

One `LedgerRepository` rather than one per entity: posting a transaction writes
the transaction record and the account balance in a single atomic
`TransactWriteItems`, and neither half of a split interface could implement it.

## Endpoints

| Method | Path | Success | Errors |
|---|---|---|---|
| `GET` | `/health` | `200` | — liveness only, never touches DynamoDB |
| `GET` | `/ready` | `200` | `503` when DynamoDB is unreachable |
| `GET` | `/version` | `200` | — |
| `POST` | `/api/accounts` | `201` + `Location` | `422` validation |
| `GET` | `/api/accounts` | `200` | `422` bad `limit` |
| `GET` | `/api/accounts/{account_id}` | `200` | `404` |
| `POST` | `/api/transactions` | `201`, or `200` on an idempotent replay | `404` no such account, `409` insufficient funds, `422` currency mismatch or validation |
| `GET` | `/api/transactions?account_id=…` | `200` | `404` no such account, `422` missing `account_id` |

Every error is an `application/problem+json` document carrying `code`,
`instance` and `request_id`. A replayed `idempotency_key` returns `200` with the
original transaction and moves the balance exactly once.

`/health` and `/ready` differ on purpose: the ALB target group polls `/health`,
so a dependency check there would let one DynamoDB hiccup deregister every
healthy task at once.

`/version` is load-bearing: during a blue/green shift it is curled against the
`:443` and `:8443` listeners at the same time, and the two different SHAs are the
direct proof of which colour serves whom.

**Phase 2** adds the multi-stage Dockerfile, digest-pinned base image and SBOM.
