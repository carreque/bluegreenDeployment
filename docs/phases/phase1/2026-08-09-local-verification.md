# Phase 1 — local verification record

**Date:** 2026-08-09
**Status:** Complete
**Branch:** `feat/Phase1_application_development`
**Companion documents:**
[Phase 1 implementation plan](./2026-08-05-phase-01-implementation-plan.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 0 findings](../phase0/2026-08-04-phase-00-verification-findings.md)

Every command from Task 9 step 5, with its raw output, run against the service
started by `make run-local` on Python 3.14.6 with DynamoDB Local at
`localhost:8000`. Phase 5 compares a real deployment's responses against this
document.

> The plan named this file `2026-08-05-local-verification.md`, after the date
> the plan itself was written. It is dated by the day the verification actually
> ran instead, which is the repository's convention and the only date that means
> anything in an evidence document.

---

## 0. Environment

```
$ app/.venv/bin/python --version
Python 3.14.6

$ make verify-tools
==> Toolchain
  TOOL                REQUIRED   FOUND      STATUS
  terraform           >= 1.10.0  1.15.7     ✓
  python3             >= 3.12.0  3.12.3     ✓
  docker              >= 24.0.0  28.3.2     ✓
  aws                 >= 2.15.0  2.35.4     ✓
  git                 >= 2.39.0  2.50.1     ✓
  make                >= 3.81    3.81       ✓
  jq                  >= 1.6     1.7.1      ✓

==> Version pins
  FILE                PINNED     ON PATH    STATUS
  .terraform-version  1.15.7     1.15.7     ✓
  app/.venv           3.14.6     3.14.6     ✓

  ✓ toolchain verified
```

The `python3` row reads 3.12.3 and passes, which is the point of F1: the ambient
interpreter is now informational, and `app/.venv` is the row that must be right.

DynamoDB Local, digest-pinned:

```
$ make local-up && docker compose -f app/docker-compose.yml ps
NAME                 IMAGE                                            COMMAND                  STATUS         PORTS
bgd-dynamodb-local   amazon/dynamodb-local@sha256:ff89bd48ff32cd…     "java -jar DynamoDBL…"   Up 3 seconds   0.0.0.0:8000->8000/tcp
```

Startup, showing the table bootstrap is idempotent and runs before uvicorn:

```
$ cp app/.env.example app/.env && make run-local
 Container bgd-dynamodb-local  Running
created  bgd-us-east-1-local-accounts
created  bgd-us-east-1-local-transactions
tables ready
INFO:     Will watch for changes in these directories: ['…/app']
INFO:     Uvicorn running on http://127.0.0.1:8080 (Press CTRL+C to quit)
{"timestamp":"2026-08-09T15:49:47.948Z","level":"INFO","logger":"uvicorn.error","message":"Application startup complete.","request_id":"-"}
```

---

## 1. The eleven calls

| # | Call | Expected | Result |
|---|---|---|---|
| 1 | `GET /health` | `200 {"status":"ok"}` | ✓ |
| 2 | `GET /ready` | `200`, dynamodb ok | ✓ |
| 3 | `GET /version` | the four build fields | ✓ |
| 4 | `POST /api/accounts` | `201`, `acc_` id | ✓ |
| 5 | `GET /api/accounts` | the one account | ✓ |
| 6 | `GET /api/accounts/{id}` | the same resource | ✓ |
| 7 | `POST /api/transactions` | `201 Created` | ✓ |
| 8 | the identical request again | `200 OK`, balance moved once | ✓ |
| 9 | debit of 999999 | `409` problem, balance in body | ✓ |
| 10 | `GET /api/accounts/{id}` | balance still 7500 | ✓ |
| 11 | `GET /api/transactions` | exactly one item | ✓ |

### 1–3, the operational endpoints

```
$ curl -s localhost:8080/health
{"status":"ok"}

$ curl -s localhost:8080/ready
{"status":"ready","checks":{"dynamodb":"ok"}}

$ curl -s localhost:8080/version
{"version":"0.0.0-dev","git_sha":"local","image_digest":"none","built_at":"1970-01-01T00:00:00Z"}
```

`/version` returns all four fields Phase 6 curls against `:443` and `:8443`.
The values are the `.env.example` defaults; Phase 2 replaces them with real
build arguments.

### 4–6, accounts

```
$ ACC=$(curl -s -X POST localhost:8080/api/accounts \
    -H 'content-type: application/json' \
    -d '{"owner_name":"Ada Lovelace","currency":"EUR","initial_balance_minor":10000}' \
    | python -c 'import json,sys; print(json.load(sys.stdin)["account_id"])')
account: acc_7e841bbf60a746dab8ad8a6bf13971fc

$ curl -s localhost:8080/api/accounts
{"items":[{"account_id":"acc_7e841bbf60a746dab8ad8a6bf13971fc","owner_name":"Ada Lovelace","currency":"EUR","balance_minor":10000,"created_at":"2026-08-09T15:50:05.066765Z"}]}

$ curl -s "localhost:8080/api/accounts/$ACC"
{"account_id":"acc_7e841bbf60a746dab8ad8a6bf13971fc","owner_name":"Ada Lovelace","currency":"EUR","balance_minor":10000,"created_at":"2026-08-09T15:50:05.066765Z"}
```

### 7–8, idempotent replay

The same request twice. The status code is the whole result:

```
$ curl -s -i -X POST localhost:8080/api/transactions \
    -H 'content-type: application/json' \
    -d "{\"account_id\":\"$ACC\",\"type\":\"DEBIT\",\"amount_minor\":2500,\"currency\":\"EUR\",\"idempotency_key\":\"key-1\"}" | head -1
HTTP/1.1 201 Created

$ # …byte-for-byte the same request again
HTTP/1.1 200 OK
```

201 then 200, and the balance below shows the debit applied exactly once.

### 9, the overdraft path end to end

HTTP → router → service → `TransactWriteItems` `ConditionExpression` → decoded
`CancellationReasons` → RFC 9457 document:

```
$ curl -s -X POST localhost:8080/api/transactions \
    -H 'content-type: application/json' \
    -d "{\"account_id\":\"$ACC\",\"type\":\"DEBIT\",\"amount_minor\":999999,\"currency\":\"EUR\",\"idempotency_key\":\"key-2\"}"
{"type":"https://carloscloudengineer.com/problems/insufficient-funds","title":"Conflict","status":409,"detail":"the account balance is too low for this debit","instance":"/api/transactions","code":"INSUFFICIENT_FUNDS","request_id":"0de8921d63904335b0e9a065912642f8","account_id":"acc_7e841bbf60a746dab8ad8a6bf13971fc","balance_minor":7500,"requested_minor":999999}
```

`balance_minor` is 7500 — the balance the condition actually rejected, read out
of `ReturnValuesOnConditionCheckFailure` rather than from a follow-up `GetItem`
(§F3). No second read, and no race between the failure and the report.

### 10–11, nothing was written

```
$ curl -s "localhost:8080/api/accounts/$ACC"
{"account_id":"acc_7e841bbf60a746dab8ad8a6bf13971fc","owner_name":"Ada Lovelace","currency":"EUR","balance_minor":7500,"created_at":"2026-08-09T15:50:05.066765Z"}

$ curl -s "localhost:8080/api/transactions?account_id=$ACC"
{"items":[{"transaction_id":"txn_d1b33ff81ee159538cb975aeac588122","account_id":"acc_7e841bbf60a746dab8ad8a6bf13971fc","type":"DEBIT","amount_minor":2500,"currency":"EUR","idempotency_key":"key-1","description":null,"created_at":"2026-08-09T15:50:05.128870Z"}],"next_cursor":null}
```

Balance still 7500. One transaction, not three: the replay did not create a
second record and the rejected debit left no trace. That is the atomicity
guarantee, observed through HTTP rather than asserted in a unit test.

---

## 2. `/health` and `/ready` diverge when the dependency dies

The single most important behavioural difference in this phase. With the
application still running, the database is removed underneath it:

```
$ make local-down
 Container bgd-dynamodb-local  Removed
 Network bgd-local_default  Removed

$ curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/ready
503
   body: {"status":"not_ready","checks":{"dynamodb":"unavailable"}}

$ curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/health
200
   body: {"status":"ok"}
```

`/health` is 200 while `/ready` is 503, at the same moment, in the same process.
This is what stops a DynamoDB hiccup from deregistering every healthy task from
the ALB target group at once.

The failure is logged once, at WARNING, with the request id that links it to the
access line:

```
{"timestamp":"2026-08-09T15:50:45.380Z","level":"WARNING","logger":"bgd.repository.dynamodb","message":"dynamodb call failed","request_id":"2bb700bff313402da837aeeb0ab3484c","error":"Could not connect to the endpoint URL: \"http://localhost:8000/\""}
{"timestamp":"2026-08-09T15:50:45.381Z","level":"INFO","logger":"bgd.access","message":"request","request_id":"2bb700bff313402da837aeeb0ab3484c","method":"GET","path":"/ready","status":503,"duration_ms":25664.32}
```

Note that the error string reaches the log and never the response body.

---

## 3. Findings

### F7 — pip-tools 7.6.0 is broken against pip 26, and `make venv` installs pip 26

Discovered running Task 1 step 8. `make deps-compile` failed twice, in two
different places, for the same underlying reason: pip-tools calls pip's private
API, and pip 26 changed it.

```
ImportError: cannot import name 'stdlib_pkgs' from 'pip._internal.utils.compat'
    — piptools/sync.py, reached from piptools/__main__.py

TypeError: RequirementCommand.make_requirement_preparer() missing 1 required
keyword-only argument: 'allow_editables'
    — piptools/resolver.py, during resolution
```

pip-tools 7.6.0 is the newest release and has no fix. Verified by bisection that
**pip 25.3 is the newest pip that works**; the plan's F6 recorded pip-tools
*installing* cleanly on 3.14.6, which it does — the break is at run time, and
`create-venv.sh` upgrading pip to latest is what triggered it.

Handled in three places:

- `scripts/create-venv.sh` installs `pip<26`, stated as a constraint rather than
  an exact version so patch releases still arrive.
- `app/requirements-dev.in` carries the same `pip<26` line, because pip-tools
  pulls pip in as a dependency and the lock would otherwise pin the very version
  that breaks it.
- `scripts/compile-deps.sh` calls the `pip-compile` entry point instead of
  `python -m piptools compile`, and bootstraps pip-tools when the virtualenv
  does not have it yet — the lock it produces is the file that would install it,
  so on a fresh virtualenv there is nothing to run.

`--allow-unsafe` was added to the same script. Without it the dev lock left `pip`
and `setuptools` unpinned and pip-compile warned that
`pip install --require-hashes` may reject the result — which is precisely what
`make deps` and the CI workflow run.

### F8 — `pythonpath` in pyproject.toml is pytest's alone

`make run-local` failed on first use with
`ModuleNotFoundError: No module named 'bgd'`. `pythonpath = ["src"]` under
`[tool.pytest.ini_options]` is read by pytest and by nothing else, so
`python -m bgd.cli.create_tables` and uvicorn both failed to find the package.

Both recipes now set `PYTHONPATH=src`, which is the same thing Phase 2's image
does with `PYTHONPATH=/app/src`. The package is still never `pip install`-ed.

### F9 — `/ready` takes 25.7 seconds to report 503 (open, for Phase 5)

Visible in the access log above: `"path":"/ready","status":503,"duration_ms":25664.32`.

The status is correct and the body is correct. The latency is botocore's
defaults — connect timeout 60s, with retries — and nothing in Phase 1 overrides
them. Phase 1 is unaffected, and this is recorded rather than fixed here because
the tuning trades local responsiveness against resilience to normal AWS
latency, which is a Phase 5 decision made against a real endpoint rather than a
container on loopback.

It matters from Phase 5 onward: `/ready` is described as a deployment gate, and
a gate that takes 25 seconds to answer will be read as a hang or time out
against a shorter deadline. The fix is a `botocore.config.Config` on the client
built in `bgd.repository.dynamodb.build_client`, with an explicit
`connect_timeout`, `read_timeout` and `retries={"max_attempts": …}`. Phase 5
should set it and re-measure this number against the real service.

---

## 4. Test suite and lint

```
$ make test
…
TOTAL                                   540     30     84     18    92%
Required test coverage of 90.0% reached. Total coverage: 91.99%
130 passed in 1.37s

$ make lint
All checks passed!
39 files already formatted
```

130 tests: 4 lock, 5 config, 5 logging, 14 domain models, 12 domain services,
21 contract tests × 2 implementations, 5 DynamoDB characterisation tests,
2 table-bootstrap tests, and 28 API tests.

The contract suite runs against **both** repository implementations. The
`dynamodb` parametrisation fails loudly rather than skipping when DynamoDB Local
is not reachable, so the suite cannot go green having silently tested one
backend.

Neither lock contains an AWS mocking library:

```
$ grep -ciE '^(moto|localstack)' app/requirements.txt app/requirements-dev.txt
app/requirements.txt:0
app/requirements-dev.txt:0
```
