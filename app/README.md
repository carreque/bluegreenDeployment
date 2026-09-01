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
| `make build` | Builds the image reproducibly and records its digest in `dist/` |
| `make image-test` | Runs the `image`-marked suite against the built container |
| `make image-verify` | Two clean builds; proves they produce the same digest |
| `make sbom` | Writes `dist/sbom.spdx.json` with a digest-pinned syft |
| `make run-image` | Serves the built image on `:8081`, with the real digest injected |

`make test` never builds a container: the image suite carries an `image` marker
that `addopts` deselects by default.

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
| `GET` | `/` | `200` `text/html` | — the demonstration page; `/app.css` and `/app.js` beside it |
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

`/version` also reports `release_color`, which the page at `/` polls every two
seconds and tints itself from. **The colour names the build, not the ECS target
group** — which colour slot is serving is ECS's to assign, and nothing in a
task can read it. Two windows showing two colours during a shift is two
*builds* being reachable at two listeners, which is exactly what a blue/green
deployment is.

## The image

Two stages on `python:3.14.6-slim`, pinned by SHA256 digest — 3.14.6 exactly,
so the container, `app/.venv` and CI all run the interpreter named in
`.python-version`. The builder stage resolves a virtualenv at `/opt/venv` from
the hash-locked `requirements.txt`; the runtime stage copies it, adds `src/` at
`PYTHONPATH=/app/src`, and runs as the numeric UID `10001` with no account —
`useradd` would record the day it ran in `/etc/shadow` and break reproducibility
across a midnight boundary.

The target is **`linux/arm64`**, which Phases 5 and 6 must match with
`runtime_platform { cpu_architecture = "ARM64" }` on both task definitions.

Two clean builds of the same commit produce the **same manifest digest** — the
identifier ECR stores and ECS deploys against. That holds because every
timestamp derives from the commit rather than the clock, so the digest is a
function of the source; `make image-verify` proves it, and it only works through
`scripts/build-image.sh`, since the default buildx driver ignores
`rewrite-timestamp`.

`/version` reports `version`, `git_sha` and `built_at` from build arguments.
`image_digest` stays `unknown` in the image, because an image cannot contain its
own hash: the ECS task definition supplies it in Phases 5 and 6, and
`make run-image` supplies it locally.

`release_color` comes from `app/RELEASE_COLOR`, a file in the repository rather
than an environment variable, so the digest stays a function of the source and
a colour flip is a real commit through the real pipeline. To see two colours
locally: build with `blue`, run `scripts/run-image.sh`, edit the file to
`green`, `make build` again, and run the second one with
`PORT=8082 scripts/run-image.sh`. Compose cannot do this — it passes no build
arguments, so both services would report `slate`.

For the whole stack in containers, `make local-tables` once and then
`docker compose --profile app up`. The `app` profile keeps that container out of
`make test` and `make image-test`, which only need DynamoDB Local. Compose passes
no build arguments, so `/version` there reports its defaults.
