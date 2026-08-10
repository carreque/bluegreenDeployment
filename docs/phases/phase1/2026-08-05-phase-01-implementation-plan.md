# Phase 1 — Application (local, test-driven): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-05
**Status:** Proposed, awaiting approval
**Branch:** `feat/Phase1_Application`
**AWS cost incurred by this phase:** $0 — no AWS API call is made, and the test suite is actively prevented from making one (Task 1, F2)
**Companion documents:**
[design research](../../2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 0 findings](../phase0/2026-08-04-phase-00-verification-findings.md) ·
[naming and tagging convention](../../naming-and-tagging-convention.md)

**Goal:** A thin-but-real FastAPI accounts-and-transactions service, built test-first, running entirely locally against DynamoDB Local, with the `/version` endpoint that Phase 6 depends on for blue/green evidence.

**Architecture:** Three layers with one-way dependencies — `domain` (pure Python, no AWS, no HTTP), `repository` (a `LedgerRepository` Protocol with an in-memory fake and a boto3 DynamoDB implementation, both held to one shared contract test suite), and `api` (FastAPI routers, RFC 9457 error envelope, JSON access logging). The API layer receives its repository by injection, so every API test runs against the fake and never touches boto3.

**Tech Stack:** Python 3.14.6, FastAPI 0.141.1, Starlette 1.4.0, Pydantic 2.13.4, boto3 1.43.64, pytest 9.1.1, httpx2 2.9.1, ruff 0.16.1, pip-tools 7.6.0, and DynamoDB Local via docker compose. **No AWS mocking library** — see §0.

---

## 0. Purpose and non-goals

Phase 1 produces the artifact every later phase deploys. It is the last phase whose output can be verified completely on this machine, so it is worth verifying completely.

**This phase deliberately does not:**

- create any AWS resource, call any AWS API, or require an SSO session
- write a `Dockerfile`, build an image, or generate an SBOM — that is Phase 2
- write any Terraform
- implement authentication, authorisation, rate limiting, or a real ledger

**Two decisions taken before this plan was written** (asked and answered 2026-08-05):

| Question | Decision |
|---|---|
| Transaction semantics | **Balance-mutating with a conditional write.** `POST /api/transactions` debits or credits an account and updates its balance in a single DynamoDB `TransactWriteItems`, with a `ConditionExpression` that rejects overdrafts. Gives a genuine 409 path and a genuine atomicity story without becoming a double-entry ledger. |
| How the DynamoDB implementation is tested | **DynamoDB Local**, AWS's own implementation, run from `docker compose`. |

> **Amended 2026-08-05, before implementation started.** The original answer to the second question was *moto*, and comparing the two properly changed it.
>
> moto's advantage is **breadth** — it reimplements ~100 AWS services in-process, which is decisive when a test touches S3 *and* SNS *and* IAM. Phase 1 touches exactly one service, so that advantage is worth nothing here. What remains is **fidelity**, and there DynamoDB Local wins by being AWS's own artifact rather than a community reimplementation.
>
> The cost of switching is far smaller than it first appears: moto only ever backed the contract suite's second parametrisation — 25 of roughly 75 tests. The domain, service and API tests all run against the in-memory fake and need neither tool, so the fast, docker-free path stays fast and docker-free. **`moto` is dropped from the dependency set entirely.**
>
> Neither tool is the real service. AWS documents DynamoDB Local's own divergences — provisioned throughput is not enforced, table creation is instant instead of passing through `CREATING`, and some limits differ — so this buys the closest available approximation, not proof. What it does buy is recorded in §F3 below, where the switch also **removed a read and a race** from the repository.
>
> One thing neither tool tests, and which is worth stating plainly because it is a common source of false confidence: **neither validates infrastructure.** moto does not enforce IAM at all, so a call it accepts may still be denied by the real service. Terraform correctness and IAM sufficiency are proved by `tflint`, `checkov` and real applies in Phases 3–6, not here.

---

## 1. Findings recorded before this plan was written

Phase 0 set the precedent that assumptions get verified rather than recalled. Six were checked on 2026-08-05 against a real Python 3.14.6 environment before this plan was written. Three of them changed the plan.

### F1 — The Python pin holds only by inheritance, and `make` is where it breaks

**`make verify` currently fails.** `scripts/verify-tools.sh` reports:

```
  python3             >= 3.14.0  3.12.3     ✗ below minimum
  .python-version     3.14.6     3.12.3     ✗ pin not honoured
```

Phase 0's findings claim all shell kinds resolve 3.14.6, including "bash launched from login zsh". Measured now:

| Parent of the `make` process | `python3` resolves to |
|---|---|
| interactive zsh | `~/.pyenv/shims/python3` → **3.14.6** |
| login zsh | `~/.pyenv/shims/python3` → **3.14.6** |
| plain `zsh -c` | **3.14.6** |
| **plain `bash -c`, or any non-zsh parent** | `/Library/Frameworks/Python.framework/Versions/3.12/bin/python3` → **3.12.3** |

The cause is structural, not a leftover. Phase 0 moved the pyenv `PATH` export into `~/.zshenv` — but `~/.zshenv` is a **zsh** file. Bash reads `~/.bashrc` only when interactive and `~/.bash_profile` only when a login shell, so a plain `bash -c` reads neither and simply inherits its parent's `PATH`. The makefile sets `SHELL := /usr/bin/env bash`, so **`make test` gets 3.14.6 only when make's parent happened to be a zsh.** From CI, a git hook, an editor task, or an agent, it silently gets 3.12.3.

Proven directly:

```
$ make -f probe show          # from a non-zsh parent
Python 3.12.3
/Library/Frameworks/Python.framework/Versions/3.12/bin/python3

$ zsh -i -c 'make -f probe show'
Python 3.14.6
/Users/carlos.revueltoquero/.pyenv/shims/python3
```

**Consequence — this is the largest single change this plan makes.** More dotfile surgery would only move the boundary. Instead, Phase 1 stops depending on the ambient interpreter: `scripts/create-venv.sh` resolves the interpreter named by `.python-version` **by absolute path** (`$PYENV_ROOT/versions/3.14.6/bin/python3`), creates `app/.venv` from it, and every make target invokes `app/.venv/bin/python` explicitly. `PATH` stops mattering. Task 1 does this, and Task 1 also amends `verify-tools.sh` so `make verify` goes green for the right reason rather than by lowering a minimum.

### F2 — Ambient AWS credentials leak into the test suite, and `AWS_CREDENTIAL_EXPIRATION` is why

The first run failed before reaching a single assertion:

```
RuntimeError: Credentials were refreshed, but the refreshed credentials are still expired.
```

This environment exports `AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` **and `AWS_CREDENTIAL_EXPIRATION`**. Unsetting `AWS_PROFILE` and setting dummy keys was **not** sufficient: while `AWS_CREDENTIAL_EXPIRATION` is present, botocore treats the environment credentials as *refreshable*, sees an expiry in the past, and attempts an SSO refresh — which fails. Botocore also resolves credentials eagerly now, during endpoint construction, so this happens on `create_table`, not on first use.

The full neutralisation set that works:

```
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_CREDENTIAL_EXPIRATION
AWS_ACCESS_KEY_ID=testing  AWS_SECRET_ACCESS_KEY=testing  AWS_SESSION_TOKEN=testing
AWS_DEFAULT_REGION=us-east-1  AWS_REGION=us-east-1
AWS_CONFIG_FILE=/dev/null  AWS_SHARED_CREDENTIALS_FILE=/dev/null
```

**Consequence:** this becomes an `autouse`, session-scoped fixture in `app/tests/conftest.py` (Task 1).

After the switch to DynamoDB Local the *specific* failure above no longer triggers, because every test client is built with an explicit endpoint and explicit dummy credentials, which botocore prefers over anything in the environment. The fixture stays regardless, and earns its ten lines: it is what makes "no test can reach real AWS" true **by construction** rather than by every future test remembering to override the endpoint. Pointing `AWS_CONFIG_FILE` at `/dev/null` is what makes the suite independent of whatever profiles happen to be in `~/.aws/config`.

### F3 — `CancellationReasons` is positional, and `ReturnValuesOnConditionCheckFailure` resolves the ambiguity it leaves

Verified twice with the exact two-item `TransactWriteItems` this design uses: first against moto 5.2.2, then — after the decision in §0 changed — against DynamoDB Local, image digest `sha256:ff89bd48ff32cd8d9be5fee8873b65b8854dc408f1afe881be6eb00247bc0dab`. **Both agree on every row below.**

| Scenario | `Error.Code` | `CancellationReasons` codes |
|---|---|---|
| duplicate transaction (item 0 fails) | `TransactionCanceledException` | `['ConditionalCheckFailed', 'None']` |
| insufficient funds (item 1 fails) | `TransactionCanceledException` | `['None', 'ConditionalCheckFailed']` |
| **account does not exist** (item 1 fails) | `TransactionCanceledException` | `['None', 'ConditionalCheckFailed']` |

The reasons array is positional, so index 0 versus index 1 cleanly separates *duplicate* from *balance-or-missing-account*. But the last two rows are **identical**: one `ConditionExpression` yields one reason code, and ours combines `attribute_exists(account_id)` with `balance_minor >= :minimum`.

**The switch to DynamoDB Local bought a better answer than the follow-up read the moto draft used.** DynamoDB Local supports `ReturnValuesOnConditionCheckFailure`, which returns the item that failed the condition — and its *presence* is exactly the discriminator:

```
insufficient funds (account exists, balance 7500):
    [('None', False), ('ConditionalCheckFailed', True)]     <- Item returned
missing account:
    [('None', False), ('ConditionalCheckFailed', False)]    <- no Item
```

**Consequences:**

- No follow-up `GetItem`. The first draft re-read the account to decide between 404 and 409; the failure payload now carries the answer.
- **A race disappears.** That re-read could observe an account created, deleted or credited between the failed write and the read, and report a balance that was never the one the condition rejected. The payload is the state the condition actually saw.
- The 409 body reports the balance **at the moment of rejection**, which is the number the caller needs.

Atomicity confirmed on both: after the insufficient-funds failure the transaction item was **not** written and the balance was unchanged.

When *both* conditions fail — a replayed key against a since-deleted account — the codes are `['ConditionalCheckFailed', 'ConditionalCheckFailed']` and the repository reports `DuplicateTransactionError`, because it tests index 0 first. The in-memory fake checks for a duplicate first for the same reason, so the two implementations agree and the contract suite stays honest.

### F4 — The LSI query, reverse ordering and pagination all work

The transactions table needs newest-first listing. Verified on moto and re-verified on DynamoDB Local, with identical results:

```
page1: ['txn_4', 'txn_3']
LastEvaluatedKey keys: ['account_id', 'created_at', 'transaction_id']
page2: ['txn_2', 'txn_1']
```

DynamoDB Local also accepted the `LocalSecondaryIndexes` block at `create_table` and reported the table `ACTIVE` immediately — table creation there is instant rather than passing through `CREATING`, which is one of the divergences from the real service noted in §0. Phase 5's Terraform apply is the first place that transition is real.

**Consequence:** a Local Secondary Index (`account_id` / `created_at`) with `ScanIndexForward=False` gives correct reverse-chronological pagination, so `list_transactions` needs no client-side sorting and no "this would need an index in production" apology. Note `LastEvaluatedKey` carries **all three** keys — the index's two plus the table's sort key — so the pagination cursor must encode the whole dict, not just `created_at`. Phase 5 and Phase 6 must declare this LSI in Terraform; `bgd/repository/schema.py` is the single definition both the local bootstrap and the tests read from.

### F5 — Starlette 1.4 wants `httpx2`, not `httpx`

`fastapi.testclient` emits:

```
StarletteDeprecationWarning: Using `httpx` with `starlette.testclient` is deprecated;
install `httpx2` instead.
```

`httpx2` 2.9.1 installs cleanly and the warning disappears. **Consequence:** `requirements-dev.in` pins `httpx2`, not `httpx`, and pytest runs with `-W error::DeprecationWarning` so the next such deprecation is a red test rather than scrollback.

### F6 — The whole dependency set installs cleanly on 3.14.6

Installed into a fresh venv built from `~/.pyenv/versions/3.14.6/bin/python3`, no source builds, no failures:

| Package | Version | | Package | Version |
|---|---|---|---|---|
| fastapi | 0.141.1 | | pytest | 9.1.1 |
| starlette | 1.4.0 | | pytest-cov | latest |
| pydantic | 2.13.4 | | ruff | 0.16.1 |
| pydantic-settings | 2.14.2 | | pip-tools | 7.6.0 |
| boto3 / botocore | 1.43.64 | | httpx2 | 2.9.1 |
| uvicorn | 0.52.1 | | | |

These are the versions the locks in Task 1 are expected to resolve to. Design §1.6's claim about `pydantic-core` cp314 wheels is confirmed by the absence of any build step.

`moto` 5.2.2 also installed cleanly and was used for the first round of §F3 and §F4. It is **not** in the final dependency set — see the amendment in §0.

The one non-pip dependency, pulled and pinned on the same day:

```
amazon/dynamodb-local@sha256:ff89bd48ff32cd8d9be5fee8873b65b8854dc408f1afe881be6eb00247bc0dab
```

Its default entrypoint is `java -jar DynamoDBLocal.jar -inMemory` on port 8000. That matters for Task 10: GitHub Actions service containers cannot override a container's command, and this default is already the one CI wants. `docker compose` adds `-sharedDb` locally so that the AWS CLI and the application see the same tables regardless of which credentials each presents.

---

## 2. Global Constraints

Every task's requirements implicitly include this section.

- **Python 3.14.6**, the version in `.python-version`. Never invoked via bare `python3` — always `app/.venv/bin/python` (F1).
- **No AWS API calls, ever.** Tests talk to DynamoDB Local on `localhost:8000` and to nothing else. The conftest fixture of §F2 makes reaching real AWS impossible even by accident.
- **`ruff` is the only linter and the only formatter.** Line length 100. `ruff check` and `ruff format --check` must both pass.
- **Coverage gate: 90%** on `src/bgd`, branch coverage on, enforced by `--cov-fail-under` in `pyproject.toml`.
- **All dependencies hash-pinned** by `pip-compile --generate-hashes`, installed with `pip install --require-hashes` (design §4.1).
- **Money is integer minor units.** No `float`, no `Decimal`, anywhere in the money path. Currency is a 3-letter uppercase ISO 4217 code.
- **Resource names follow** `bgd-us-east-1-<env>-<entity>`. Locally `<env>` is `local`: `bgd-us-east-1-local-accounts`, `bgd-us-east-1-local-transactions`.
- **Configuration is environment variables only**, prefix `BGD_`. No config file is read at runtime.
- **`/health` never touches DynamoDB.** Liveness only. This is a hard rule, not a preference — the ALB target-group health check calls it, and a dependency hiccup must not deregister healthy tasks.
- **Structured JSON logging, one object per line.** A log record containing a newline breaks CloudWatch Logs Insights parsing.
- **TDD.** Every task writes the failing test first, runs it to watch it fail, then implements. Test commits precede implementation commits (roadmap §2).

---

## 3. File structure

```
app/
  pyproject.toml                    ruff, pytest, coverage config; no build backend
  requirements.in / .txt            runtime deps, hash-pinned
  requirements-dev.in / .txt        runtime + test/lint deps, hash-pinned
  docker-compose.yml                DynamoDB Local, digest-pinned. Needed by the contract
                                    suite, so it lands in Task 1 (Phase 2 adds an api service)
  .env.example                      documented shape of the BGD_ environment
  .venv/                            gitignored; created by scripts/create-venv.sh
  src/bgd/
    __init__.py
    config.py                       Settings (pydantic-settings), get_settings()
    logging.py                      JsonFormatter, request_id_var, configure_logging()
    domain/
      __init__.py
      errors.py                     DomainError hierarchy — no HTTP, no AWS
      models.py                     Money, Account, Transaction, id derivation, time helpers
      services.py                   LedgerService — the use cases
    repository/
      __init__.py
      base.py                       Page[T], LedgerRepository Protocol
      schema.py                     DynamoDB table + LSI definitions (single source of truth)
      memory.py                     InMemoryLedgerRepository — the fake
      dynamodb.py                   DynamoDbLedgerRepository — boto3, TransactWriteItems
    api/
      __init__.py
      main.py                       create_app() factory, lifespan, router wiring
      middleware.py                 RequestContextMiddleware (pure ASGI)
      errors.py                     RFC 9457 problem responses, exception handlers
      dependencies.py               ServiceDep, SettingsDep
      schemas.py                    Pydantic request/response models
      routers/
        __init__.py
        health.py                   /health, /ready, /version
        accounts.py                 /api/accounts
        transactions.py             /api/transactions
    cli/
      __init__.py
      create_tables.py              idempotent local table bootstrap
  tests/
    conftest.py                     AWS neutralisation, settings cache reset
    unit/
      test_requirements_lock.py     the two locks agree and are hash-pinned
      test_config.py
      test_logging.py
      test_domain_models.py
      test_domain_services.py
    contract/
      conftest.py                   parametrised repository fixture: memory | dynamodb
      test_ledger_repository.py     one suite, both implementations
    api/
      test_health.py
      test_errors.py
      test_accounts.py
      test_transactions.py
scripts/
  create-venv.sh                    resolves the pinned interpreter by absolute path
.github/workflows/
  pr-validate.yml                   ruff + pytest on pull requests (deferred here by Phase 0 §C4)
makefile                            new targets: venv, deps, deps-compile, lint, format,
                                    test, local-up, local-down, local-tables, run-local
```

**Why the package is `bgd` and not `src`.** Tests import `from bgd.domain.models import Account`. Top-level packages named `api`, `domain`, `repository` would collide with anything else on the path; one namespace package avoids it. Nothing is ever `pip install`-ed — `pytest` gets `pythonpath = ["src"]`, and Phase 2's image sets `PYTHONPATH=/app/src`.

**Why one `LedgerRepository` Protocol and not one per entity.** Posting a transaction writes the transaction *and* the account balance in a single atomic operation. Splitting them into an `AccountRepository` and a `TransactionRepository` would advertise an independence that does not exist, and neither half could implement `post_transaction` alone.

---

## Task 1: Python project scaffolding, deterministic interpreter, and hash-pinned locks

Establishes the toolchain the other nine tasks run on, and closes F1 and F2. Nothing here is application code, but nothing after it is trustworthy without it.

**Files:**
- Create: `scripts/create-venv.sh`, `scripts/compile-deps.sh`
- Create: `app/pyproject.toml`, `app/requirements.in`, `app/requirements-dev.in`
- Generate: `app/requirements.txt`, `app/requirements-dev.txt`
- Create: `app/docker-compose.yml`
- Create: `app/src/bgd/__init__.py` (empty), `app/tests/conftest.py`
- Create: `app/tests/unit/test_requirements_lock.py`
- Modify: `makefile` (add targets, remove three `# PLANNED:` lines)
- Modify: `scripts/verify-tools.sh` (add the venv pin check; demote the PATH row)

**Interfaces:**
- Produces: `app/.venv/bin/python` at exactly the version in `.python-version`; `make test`, `make lint`, `make deps-compile`, `make local-up`, `make local-down`; an `autouse` session fixture named `_neutralise_aws_environment` in `app/tests/conftest.py`.

> **Why `docker-compose.yml` lands here rather than in Task 9.** The contract suite in Task 6 runs against DynamoDB Local, so the container has to exist before that task, not after it. Task 9 still owns local *development* — the `.env` shape, the table bootstrap CLI, and `make run-local`.

- [ ] **Step 1: Write the failing lock test**

`app/tests/unit/test_requirements_lock.py`:

```python
"""The two locks must agree, and both must carry hashes.

requirements-dev.in includes requirements.in, so pip-compile resolves the two
files separately and could pin the same package to two different versions —
which would mean the boto3 the tests exercise is not the boto3 the image ships.
That drift is silent, so it is asserted rather than assumed.
"""

import re
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[2]
PIN = re.compile(r"^(?P<name>[A-Za-z0-9._-]+)==(?P<version>[^\s;\\]+)")


def _pins(path: Path) -> dict[str, str]:
    pins: dict[str, str] = {}
    for line in path.read_text().splitlines():
        match = PIN.match(line.strip())
        if match:
            pins[match["name"].lower().replace("_", "-")] = match["version"]
    return pins


def test_runtime_lock_is_populated() -> None:
    assert _pins(APP_ROOT / "requirements.txt"), "requirements.txt pins nothing"


def test_dev_lock_contains_every_runtime_package() -> None:
    missing = set(_pins(APP_ROOT / "requirements.txt")) - set(
        _pins(APP_ROOT / "requirements-dev.txt")
    )
    assert not missing, f"dev lock is missing runtime packages: {sorted(missing)}"


def test_dev_lock_agrees_with_the_runtime_lock() -> None:
    runtime = _pins(APP_ROOT / "requirements.txt")
    dev = _pins(APP_ROOT / "requirements-dev.txt")
    drifted = {n: (v, dev[n]) for n, v in runtime.items() if n in dev and dev[n] != v}
    assert not drifted, f"runtime/dev version drift (runtime, dev): {drifted}"


def test_both_locks_are_hash_pinned() -> None:
    for name in ("requirements.txt", "requirements-dev.txt"):
        text = (APP_ROOT / name).read_text()
        assert "--hash=sha256:" in text, f"{name} was compiled without --generate-hashes"
```

- [ ] **Step 2: Write `scripts/create-venv.sh`**

```bash
#!/usr/bin/env bash
#
# Phase 1 — create the project virtualenv on the interpreter named by
# .python-version, resolved by absolute path rather than through PATH.
#
# Phase 0 fixed pyenv's PATH export for every *zsh* invocation, but bash reads
# neither ~/.zshenv nor ~/.zprofile. A make recipe runs in bash and inherits
# whatever PATH its parent had: launched from a terminal it gets 3.14.6;
# launched from CI, a git hook or an editor task it silently gets the system
# 3.12. Addressing the interpreter by path removes the dependence entirely.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(repo_root)"
VENV="$ROOT/app/.venv"
PIN="$(tr -d '[:space:]' <"$ROOT/.python-version")"

# Ordered by how much they depend on the environment being set up correctly.
find_interpreter() {
  local candidate

  candidate="${PYENV_ROOT:-$HOME/.pyenv}/versions/$PIN/bin/python3"
  [[ -x "$candidate" ]] && {
    printf '%s' "$candidate"
    return 0
  }

  if command -v pyenv >/dev/null 2>&1; then
    candidate="$(pyenv root)/versions/$PIN/bin/python3"
    [[ -x "$candidate" ]] && {
      printf '%s' "$candidate"
      return 0
    }
  fi

  # PATH is accepted only when it is exactly the pinned version.
  if command -v python3 >/dev/null 2>&1; then
    candidate="$(command -v python3)"
    [[ "$(extract_version "$("$candidate" --version 2>&1)")" == "$PIN" ]] && {
      printf '%s' "$candidate"
      return 0
    }
  fi

  return 1
}

if [[ -x "$VENV/bin/python" ]]; then
  found="$(extract_version "$("$VENV/bin/python" --version 2>&1)")"
  if [[ "$found" == "$PIN" ]]; then
    ok "virtualenv already on $PIN"
    exit 0
  fi
  warn "virtualenv is on $found but the pin is $PIN — recreating"
  rm -rf "$VENV"
fi

interpreter="$(find_interpreter)" ||
  die "no Python $PIN on this machine. Install it with: pyenv install $PIN"

info "creating $VENV on $interpreter"
"$interpreter" -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet --upgrade pip
ok "virtualenv ready — $("$VENV/bin/python" --version)"
```

Then `chmod +x scripts/create-venv.sh`.

- [ ] **Step 3: Write `app/pyproject.toml`**

```toml
[project]
name = "bgd-api"
version = "0.0.0"
description = "Blue/green deployment platform — accounts and transactions API"
requires-python = ">=3.14"

# No [build-system]: this package is never pip-installed. Tests reach it via
# pytest's pythonpath below, and Phase 2's image sets PYTHONPATH=/app/src.

[tool.pytest.ini_options]
pythonpath = ["src"]
testpaths = ["tests"]
addopts = "-q --strict-markers --strict-config --cov --cov-report=term-missing"
filterwarnings = [
    "error::DeprecationWarning",
    # Starlette 1.4 deprecated httpx in the TestClient in favour of httpx2
    # (F5). We ship httpx2; this keeps any *new* deprecation loud.
]

[tool.coverage.run]
source = ["src/bgd"]
branch = true

[tool.coverage.report]
fail_under = 90
show_missing = true
exclude_lines = [
    "pragma: no cover",
    "if TYPE_CHECKING:",
    "raise NotImplementedError",
    "^\\s*\\.\\.\\.$",
]

[tool.ruff]
line-length = 100
src = ["src", "tests"]
# target-version is deliberately omitted: ruff infers it from
# project.requires-python above, so the Python version is stated once.

[tool.ruff.lint]
select = ["E", "F", "I", "N", "UP", "B", "A", "C4", "SIM", "RUF", "ASYNC", "S", "T20"]

[tool.ruff.lint.per-file-ignores]
# S101 assert-used: asserts are the point of a test.
# S105/S106 hardcoded passwords: the AWS neutralisation fixture uses literals.
"tests/**" = ["S101", "S105", "S106"]
# T201 print: create_tables is a CLI whose output is the user interface.
"src/bgd/cli/*" = ["T201"]
```

- [ ] **Step 4: Declare the dependencies — the pip inputs and the DynamoDB Local container**

`app/requirements.in`:

```
# Runtime dependencies. Compiled to requirements.txt with:
#   make deps-compile
fastapi
uvicorn[standard]
pydantic
pydantic-settings
boto3
```

`app/requirements-dev.in`:

```
# Test and lint dependencies. Includes the runtime set so a single install
# gives a working test environment, and so test_requirements_lock.py can
# assert the two resolutions agree.
#
# No AWS mocking library. The real backend is exercised against DynamoDB
# Local, which is a container rather than a package — see §0. Everything
# above the repository layer runs against the in-memory fake.
-r requirements.in

pytest
pytest-cov
httpx2          # Starlette 1.4 deprecated httpx in the TestClient (F5)
ruff
pip-tools
```

`app/docker-compose.yml` — the one dependency pip cannot install:

```yaml
# Local development and test dependencies.
#
# Phase 1 runs only DynamoDB Local here; the API runs on the host through
# uvicorn, because the Dockerfile does not exist until Phase 2, which adds an
# `api` service to this file.
#
# Pinned by digest rather than tag, per design §4.1. Recorded 2026-08-05 —
# re-record with:
#   docker pull amazon/dynamodb-local:latest
#   docker image inspect amazon/dynamodb-local:latest --format '{{index .RepoDigests 0}}'
name: bgd-local

services:
  dynamodb-local:
    image: amazon/dynamodb-local@sha256:ff89bd48ff32cd8d9be5fee8873b65b8854dc408f1afe881be6eb00247bc0dab
    container_name: bgd-dynamodb-local
    # -sharedDb: one database regardless of which credentials or region the
    #   caller presents, so the AWS CLI and the application see the same
    #   tables. Without it DynamoDB Local partitions by access key and region.
    # -inMemory: nothing survives a restart, which is what makes every test
    #   run start from a known state.
    command: ["-jar", "DynamoDBLocal.jar", "-sharedDb", "-inMemory"]
    ports:
      - "8000:8000"
```

> No container healthcheck: the image's tooling is not ours to rely on, and the test fixture and the table bootstrap both retry the connection themselves, which is a more reliable readiness signal than probing a port.

- [ ] **Step 5: Write `app/tests/conftest.py` (AWS neutralisation)**

```python
"""Test-wide fixtures.

The AWS neutralisation below is load-bearing, not hygiene. This machine
exports AWS_PROFILE, live session keys and AWS_CREDENTIAL_EXPIRATION. While
AWS_CREDENTIAL_EXPIRATION is set, botocore treats the environment credentials
as refreshable, sees an expiry in the past and attempts an SSO refresh — which
fails before a single assertion runs. Botocore resolves credentials eagerly
during endpoint construction, so this happens on the first API call, not on
first use of a credential.

Pointing AWS_CONFIG_FILE at /dev/null is what makes the suite independent of
whatever profiles happen to be in ~/.aws/config.
"""

import os

import pytest

_FAKE_AWS_ENVIRONMENT = {
    "AWS_ACCESS_KEY_ID": "testing",
    "AWS_SECRET_ACCESS_KEY": "testing",
    "AWS_SESSION_TOKEN": "testing",
    "AWS_SECURITY_TOKEN": "testing",
    "AWS_DEFAULT_REGION": "us-east-1",
    "AWS_REGION": "us-east-1",
    "AWS_CONFIG_FILE": os.devnull,
    "AWS_SHARED_CREDENTIALS_FILE": os.devnull,
    "AWS_EC2_METADATA_DISABLED": "true",
}

_BANNED_AWS_ENVIRONMENT = (
    "AWS_PROFILE",
    "AWS_DEFAULT_PROFILE",
    "AWS_CREDENTIAL_EXPIRATION",
)


@pytest.fixture(scope="session", autouse=True)
def _neutralise_aws_environment() -> None:
    for name in _BANNED_AWS_ENVIRONMENT:
        os.environ.pop(name, None)
    os.environ.update(_FAKE_AWS_ENVIRONMENT)


@pytest.fixture(autouse=True)
def _clear_settings_cache() -> None:
    """get_settings is lru_cached; a test that sets BGD_* must not leak."""
    from bgd.config import get_settings

    get_settings.cache_clear()
    yield
    get_settings.cache_clear()
```

- [ ] **Step 6: Add the make targets**

Insert after the `verify-aws` target in `makefile`:

```make
# ---------------------------------------------------------------------------
# Phase 1 — application
#
# Every recipe calls the virtualenv's interpreter by path. `python3` on PATH is
# 3.14.6 only when make's parent was a zsh; from CI, a git hook or an editor
# task it is the system 3.12. See docs/phases/phase1/…-implementation-plan.md §F1.
# ---------------------------------------------------------------------------

APP_DIR := app
VENV    := $(CURDIR)/$(APP_DIR)/.venv
PY      := $(VENV)/bin/python
PIP     := $(VENV)/bin/pip
RUFF    := $(VENV)/bin/ruff

$(VENV)/bin/python:
	@./scripts/create-venv.sh

.PHONY: venv
venv: $(VENV)/bin/python ## Create the virtualenv on the pinned interpreter

$(VENV)/.deps-stamp: $(APP_DIR)/requirements-dev.txt | $(VENV)/bin/python
	@$(PIP) install --require-hashes --quiet -r $(APP_DIR)/requirements-dev.txt
	@touch $@

.PHONY: deps
deps: $(VENV)/.deps-stamp ## Install hash-pinned dependencies into the virtualenv

.PHONY: deps-compile
deps-compile: venv ## Recompile both requirements locks with hashes
	@./scripts/compile-deps.sh

.PHONY: local-up
local-up: ## Start DynamoDB Local
	@cd $(APP_DIR) && docker compose up -d

.PHONY: local-down
local-down: ## Stop DynamoDB Local and discard its data
	@cd $(APP_DIR) && docker compose down -v

# Depends on local-up because the contract suite runs against DynamoDB Local.
# `docker compose up -d` is idempotent and returns in milliseconds when the
# container is already running, so this costs nothing on repeat runs.
.PHONY: test
test: deps local-up ## Run the application test suite with coverage
	@cd $(APP_DIR) && $(PY) -m pytest

.PHONY: lint
lint: deps ## Ruff lint and format check
	@cd $(APP_DIR) && $(RUFF) check . && $(RUFF) format --check .

.PHONY: format
format: deps ## Apply ruff formatting and safe fixes
	@cd $(APP_DIR) && $(RUFF) check --fix . && $(RUFF) format .
```

Delete these three lines from the `# PLANNED:` block, since they now exist:

```
# PLANNED: test           Run the application test suite (Phase 1)
# PLANNED: lint           Ruff lint and format check (Phase 1)
```

(Keep `# PLANNED: run-local` — Task 9 adds it.)

- [ ] **Step 7: Write `scripts/compile-deps.sh`**

A loop and a conditional, so it is a script rather than a recipe (the makefile's own three-line rule):

```bash
#!/usr/bin/env bash
#
# Recompile the requirements locks with hashes. Runs pip-compile from inside
# the virtualenv so the resolution happens on the pinned interpreter — a lock
# compiled on 3.12 can select different wheels than 3.14 would.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(repo_root)"
APP="$ROOT/app"
PY="$ROOT/app/.venv/bin/python"

[[ -x "$PY" ]] || die "virtualenv missing — run 'make venv' first"

for input in requirements.in requirements-dev.in; do
  info "compiling $input"
  (cd "$APP" && "$PY" -m piptools compile \
    --generate-hashes \
    --strip-extras \
    --quiet \
    --output-file "${input%.in}.txt" \
    "$input")
done

ok "locks recompiled"
```

Then `chmod +x scripts/compile-deps.sh`.

- [ ] **Step 8: Create the venv and compile the locks**

```bash
make venv
make deps-compile
```

Expected: `app/.venv/bin/python --version` reports `Python 3.14.6`; `app/requirements.txt` and `app/requirements-dev.txt` exist and contain `--hash=sha256:` lines. Confirm the resolved versions match F6.

- [ ] **Step 9: Run the lock test to verify it passes**

Run: `make test`
Expected: 4 passed. Coverage will report 0% over an empty package and the `--cov-fail-under=90` gate will fail the run — that is correct and expected at this point. Confirm the four lock tests themselves pass, then temporarily run `cd app && ../app/.venv/bin/python -m pytest --no-cov tests/unit/test_requirements_lock.py -v` to see them green in isolation.

- [ ] **Step 10: Amend `scripts/verify-tools.sh`**

`make verify` currently fails (F1). The fix is not to lower the 3.14.0 minimum — it is to check the thing that now actually matters. Add this function after `check_pin` (around line 100):

```bash
# check_venv_pin — the authoritative Python check from Phase 1 onward.
#
# Phase 0 deliberately checked python3 through PATH, because a PATH resolution
# difference between shell kinds was the bug it was hunting. That check is kept
# below, but demoted to a warning: Phase 1 stopped using the ambient
# interpreter altogether. What must be right now is the virtualenv every make
# target invokes by absolute path.
check_venv_pin() {
  local pinned actual venv="$ROOT/app/.venv/bin/python"
  pinned="$(tr -d '[:space:]' <"$ROOT/.python-version")"

  if [[ ! -x "$venv" ]]; then
    printf "$ROW" "app/.venv" "$pinned" "-"
    mark_warn "not created yet — run 'make venv'"
    return 0
  fi

  actual="$(extract_version "$("$venv" --version 2>&1)")"
  printf "$ROW" "app/.venv" "$pinned" "${actual:-?}"
  if [[ "$pinned" == "$actual" ]]; then
    mark_ok
  else
    mark_fail "virtualenv is $actual, not $pinned — run 'make venv'"
    failures=$((failures + 1))
  fi
}
```

Change the `python3` row in the `TOOLS` array (line 21) so a stale ambient interpreter warns instead of failing. Replace:

```bash
  "python3|3.14.0|parity with the container (design §1.6)"
```

with:

```bash
  "python3|3.12.0|informational only — make uses app/.venv, see Phase 1 §F1"
```

Replace the `check_pin ".python-version" python3 pyenv version` call (line 106) with:

```bash
check_venv_pin
```

- [ ] **Step 11: Run the verification**

Run: `make verify`
Expected: exit 0, with the `app/.venv` row reporting `3.14.6 ✓`.

- [ ] **Step 12: Commit**

```bash
git add app/pyproject.toml app/requirements.in app/requirements-dev.in \
        app/requirements.txt app/requirements-dev.txt app/src/bgd/__init__.py \
        app/tests/conftest.py app/tests/unit/test_requirements_lock.py \
        scripts/create-venv.sh scripts/compile-deps.sh scripts/verify-tools.sh makefile
git commit -m "build: pin the toolchain to a project virtualenv and hash-locked deps

The .python-version pin held only when make's parent was a zsh; bash reads
neither ~/.zshenv nor ~/.zprofile, so make recipes silently resolved the system
3.12. Every make target now calls app/.venv/bin/python by path."
```

---

## Task 2: Configuration and structured logging

The two cross-cutting modules everything else imports. No domain logic.

**Files:**
- Create: `app/src/bgd/config.py`, `app/src/bgd/logging.py`
- Test: `app/tests/unit/test_config.py`, `app/tests/unit/test_logging.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `bgd.config.Settings` — pydantic-settings model, env prefix `BGD_`
  - `bgd.config.get_settings() -> Settings` — `lru_cache`d
  - `bgd.logging.request_id_var: ContextVar[str]` — default `"-"`
  - `bgd.logging.JsonFormatter` — `logging.Formatter` subclass
  - `bgd.logging.configure_logging(level: str) -> None`

- [ ] **Step 1: Write the failing tests**

`app/tests/unit/test_config.py`:

```python
from bgd.config import Settings, get_settings


def test_defaults_are_local_development_values() -> None:
    settings = Settings(_env_file=None)
    assert settings.environment == "local"
    assert settings.app_version == "0.0.0-dev"
    assert settings.git_sha == "unknown"
    assert settings.image_digest == "unknown"
    assert settings.dynamodb_endpoint_url is None
    assert settings.aws_region == "us-east-1"


def test_table_names_follow_the_naming_convention() -> None:
    settings = Settings(_env_file=None)
    assert settings.accounts_table == "bgd-us-east-1-local-accounts"
    assert settings.transactions_table == "bgd-us-east-1-local-transactions"


def test_settings_read_the_bgd_prefixed_environment(monkeypatch) -> None:
    monkeypatch.setenv("BGD_GIT_SHA", "abc1234")
    monkeypatch.setenv("BGD_ENVIRONMENT", "prod")
    monkeypatch.setenv("BGD_DYNAMODB_ENDPOINT_URL", "http://localhost:8000")
    settings = Settings(_env_file=None)
    assert settings.git_sha == "abc1234"
    assert settings.environment == "prod"
    assert settings.dynamodb_endpoint_url == "http://localhost:8000"


def test_unprefixed_environment_is_ignored(monkeypatch) -> None:
    """AWS_REGION must not be mistaken for BGD_AWS_REGION."""
    monkeypatch.setenv("AWS_REGION", "eu-west-1")
    assert Settings(_env_file=None).aws_region == "us-east-1"


def test_get_settings_is_cached() -> None:
    assert get_settings() is get_settings()
```

`app/tests/unit/test_logging.py`:

```python
import json
import logging
import sys

from bgd.logging import JsonFormatter, request_id_var


def _record(message: str = "hello", **extra: object) -> logging.LogRecord:
    record = logging.LogRecord("bgd.test", logging.INFO, __file__, 10, message, None, None)
    for key, value in extra.items():
        setattr(record, key, value)
    return record


def test_formatter_emits_one_json_object() -> None:
    payload = json.loads(JsonFormatter().format(_record()))
    assert payload["level"] == "INFO"
    assert payload["logger"] == "bgd.test"
    assert payload["message"] == "hello"
    assert payload["timestamp"].endswith("Z")


def test_formatter_includes_the_request_id() -> None:
    token = request_id_var.set("req-123")
    try:
        payload = json.loads(JsonFormatter().format(_record()))
    finally:
        request_id_var.reset(token)
    assert payload["request_id"] == "req-123"


def test_formatter_promotes_extra_fields_to_top_level_keys() -> None:
    payload = json.loads(JsonFormatter().format(_record("request", status=201, duration_ms=4.2)))
    assert payload["status"] == 201
    assert payload["duration_ms"] == 4.2


def test_formatter_renders_exceptions() -> None:
    try:
        raise ValueError("boom")
    except ValueError:
        record = logging.LogRecord(
            "bgd.test", logging.ERROR, __file__, 10, "failed", None, sys.exc_info()
        )
    payload = json.loads(JsonFormatter().format(record))
    assert "ValueError: boom" in payload["exception"]


def test_a_multiline_message_never_produces_a_multiline_record() -> None:
    """CloudWatch Logs Insights parses one JSON object per line. A record split
    across lines is silently unparseable, so the formatter must escape it."""
    formatted = JsonFormatter().format(_record("line one\nline two"))
    assert "\n" not in formatted
    assert json.loads(formatted)["message"] == "line one\nline two"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/unit/test_config.py tests/unit/test_logging.py --no-cov -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'bgd.config'`

- [ ] **Step 3: Write `app/src/bgd/config.py`**

```python
"""Runtime configuration.

Environment variables only, prefix BGD_. No file is read at runtime: the
container gets its configuration from the ECS task definition, and reading a
file would create a second, invisible source of truth.

The build-metadata fields keep local-development defaults. Phase 2 injects the
real values as Docker build arguments and Phase 6 reads them back off /version
during a blue/green shift, which is how a running task announces which colour
it is.
"""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="BGD_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    environment: str = "local"
    log_level: str = "INFO"

    # Build metadata, surfaced by /version. Overwritten at image build time.
    app_version: str = "0.0.0-dev"
    git_sha: str = "unknown"
    image_digest: str = "unknown"
    built_at: str = "unknown"

    aws_region: str = "us-east-1"
    # Set to http://localhost:8000 for DynamoDB Local. None means real AWS.
    dynamodb_endpoint_url: str | None = None

    accounts_table: str = "bgd-us-east-1-local-accounts"
    transactions_table: str = "bgd-us-east-1-local-transactions"


@lru_cache
def get_settings() -> Settings:
    return Settings()
```

- [ ] **Step 4: Write `app/src/bgd/logging.py`**

```python
"""Structured JSON logging.

One JSON object per line, because CloudWatch Logs Insights parses line by line
and a record split across lines is silently dropped from every query.

Written against the standard library rather than structlog: the whole
requirement is a formatter and a context variable, and design §4.1's
reproducibility argument is easier to make with a smaller dependency set.
"""

import json
import logging
import sys
import time
from contextvars import ContextVar

request_id_var: ContextVar[str] = ContextVar("request_id", default="-")

# Everything LogRecord sets on itself. Anything else came from `extra=` and is
# promoted to a top-level key. Snapshotted from a real record so it cannot
# drift as the standard library adds attributes.
_RESERVED = frozenset(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {
    "asctime",
    "message",
    "taskName",
}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        created = time.gmtime(record.created)
        payload: dict[str, object] = {
            "timestamp": f"{time.strftime('%Y-%m-%dT%H:%M:%S', created)}.{int(record.msecs):03d}Z",
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "request_id": request_id_var.get(),
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED:
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str, separators=(",", ":"))


def configure_logging(level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level.upper())

    # uvicorn.access duplicates the access line RequestContextMiddleware emits,
    # in a different format. Silence it rather than log every request twice.
    logging.getLogger("uvicorn.access").handlers = []
    logging.getLogger("uvicorn.access").propagate = False
    logging.getLogger("uvicorn.error").handlers = [handler]
    logging.getLogger("uvicorn.error").propagate = False
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/unit/test_config.py tests/unit/test_logging.py --no-cov -q`
Expected: 10 passed

- [ ] **Step 6: Commit**

```bash
git add app/src/bgd/config.py app/src/bgd/logging.py \
        app/tests/unit/test_config.py app/tests/unit/test_logging.py
git commit -m "feat(app): add settings and structured JSON logging"
```

---

## Task 3: Domain models and errors

Pure Python. No boto3 import, no FastAPI import, no I/O. This is the layer the roadmap describes as "kept free of AWS specifics".

**Files:**
- Create: `app/src/bgd/domain/__init__.py`, `errors.py`, `models.py`
- Test: `app/tests/unit/test_domain_models.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `bgd.domain.errors.DomainError(message: str, **details)` with class attribute `code: str`, instance attributes `.message`, `.details`
  - Subclasses: `InvariantViolationError`, `AccountNotFoundError`, `AccountAlreadyExistsError`, `InsufficientFundsError`, `CurrencyMismatchError`, `DuplicateTransactionError`, `RepositoryUnavailableError`
  - `bgd.domain.models.TransactionType` — `StrEnum` with `CREDIT`, `DEBIT`
  - `Money(amount_minor: int, currency: str)` — frozen dataclass
  - `Account(account_id: str, owner_name: str, balance: Money, created_at: datetime)` — frozen
  - `Transaction(transaction_id, account_id, type, amount, idempotency_key, description, created_at)` — frozen
  - `new_account_id() -> str`, `transaction_id_for(account_id: str, idempotency_key: str) -> str`
  - `utcnow() -> datetime`, `to_iso(dt: datetime) -> str`, `from_iso(value: str) -> datetime`

- [ ] **Step 1: Write the failing tests**

`app/tests/unit/test_domain_models.py`:

```python
from datetime import UTC, datetime

import pytest

from bgd.domain.errors import DomainError, InvariantViolationError
from bgd.domain.models import (
    Account,
    Money,
    Transaction,
    TransactionType,
    from_iso,
    new_account_id,
    to_iso,
    transaction_id_for,
    utcnow,
)

WHEN = datetime(2026, 8, 5, 10, 0, 0, 123456, tzinfo=UTC)


def test_domain_error_carries_a_code_and_details() -> None:
    error = DomainError("nope", account_id="acc_1")
    assert error.code == "DOMAIN_ERROR"
    assert error.message == "nope"
    assert error.details == {"account_id": "acc_1"}


def test_money_rejects_a_lowercase_currency() -> None:
    with pytest.raises(InvariantViolationError):
        Money(amount_minor=100, currency="eur")


def test_money_rejects_a_currency_that_is_not_three_letters() -> None:
    with pytest.raises(InvariantViolationError):
        Money(amount_minor=100, currency="EURO")


def test_money_rejects_a_boolean_amount() -> None:
    """bool is a subclass of int; True would otherwise become 1 minor unit."""
    with pytest.raises(InvariantViolationError):
        Money(amount_minor=True, currency="EUR")


def test_money_allows_a_zero_and_a_negative_balance() -> None:
    """Money models an amount, not a rule. Only transactions must be positive."""
    assert Money(amount_minor=0, currency="EUR").amount_minor == 0
    assert Money(amount_minor=-1, currency="EUR").amount_minor == -1


def test_account_rejects_a_blank_owner_name() -> None:
    with pytest.raises(InvariantViolationError):
        Account(
            account_id="acc_1",
            owner_name="   ",
            balance=Money(0, "EUR"),
            created_at=WHEN,
        )


def test_transaction_rejects_a_non_positive_amount() -> None:
    with pytest.raises(InvariantViolationError):
        Transaction(
            transaction_id="txn_1",
            account_id="acc_1",
            transaction_type=TransactionType.DEBIT,
            amount=Money(0, "EUR"),
            idempotency_key="k1",
            description=None,
            created_at=WHEN,
        )


def test_transaction_signed_amount_follows_its_type() -> None:
    def build(kind: TransactionType) -> Transaction:
        return Transaction(
            transaction_id="txn_1",
            account_id="acc_1",
            type=kind,
            amount=Money(2500, "EUR"),
            idempotency_key="k1",
            description=None,
            created_at=WHEN,
        )

    assert build(TransactionType.CREDIT).signed_amount_minor == 2500
    assert build(TransactionType.DEBIT).signed_amount_minor == -2500


def test_transaction_minimum_balance_is_the_amount_only_for_a_debit() -> None:
    """This is the value that becomes the DynamoDB ConditionExpression bound."""

    def build(kind: TransactionType) -> Transaction:
        return Transaction(
            transaction_id="txn_1",
            account_id="acc_1",
            type=kind,
            amount=Money(2500, "EUR"),
            idempotency_key="k1",
            description=None,
            created_at=WHEN,
        )

    assert build(TransactionType.DEBIT).minimum_balance_minor == 2500
    assert build(TransactionType.CREDIT).minimum_balance_minor == 0


def test_transaction_id_is_derived_from_the_account_and_the_idempotency_key() -> None:
    first = transaction_id_for("acc_1", "key-1")
    assert first == transaction_id_for("acc_1", "key-1")
    assert first != transaction_id_for("acc_1", "key-2")
    assert first != transaction_id_for("acc_2", "key-1")
    assert first.startswith("txn_")


def test_account_ids_are_unique_and_prefixed() -> None:
    ids = {new_account_id() for _ in range(100)}
    assert len(ids) == 100
    assert all(value.startswith("acc_") for value in ids)


def test_timestamps_serialise_to_a_fixed_width_sortable_string() -> None:
    """Fixed width is what makes the DynamoDB LSI sort chronologically —
    the index sorts strings, so a variable-length format would misorder."""
    early = to_iso(datetime(2026, 1, 2, 3, 4, 5, 6, tzinfo=UTC))
    late = to_iso(datetime(2026, 1, 2, 3, 4, 5, 7, tzinfo=UTC))
    assert len(early) == len(late) == 27
    assert early.endswith("Z")
    assert early < late


def test_timestamps_round_trip() -> None:
    assert from_iso(to_iso(WHEN)) == WHEN


def test_utcnow_is_timezone_aware() -> None:
    assert utcnow().tzinfo is not None
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/unit/test_domain_models.py --no-cov -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'bgd.domain'`

- [ ] **Step 3: Write `app/src/bgd/domain/errors.py`**

```python
"""Domain errors.

These carry a stable machine-readable `code` and a `details` mapping, and know
nothing about HTTP. bgd.api.errors is the only place that maps a code to a
status, so the domain can be reused unchanged by a Lambda or a CLI.
"""

from typing import Any


class DomainError(Exception):
    code = "DOMAIN_ERROR"

    def __init__(self, message: str, **details: Any) -> None:
        super().__init__(message)
        self.message = message
        self.details = details


class InvariantViolationError(DomainError):
    """A value that cannot exist in the model was constructed."""

    code = "INVARIANT_VIOLATION"


class AccountNotFoundError(DomainError):
    code = "ACCOUNT_NOT_FOUND"


class AccountAlreadyExistsError(DomainError):
    code = "ACCOUNT_ALREADY_EXISTS"


class InsufficientFundsError(DomainError):
    code = "INSUFFICIENT_FUNDS"


class CurrencyMismatchError(DomainError):
    code = "CURRENCY_MISMATCH"


class DuplicateTransactionError(DomainError):
    """The same idempotency key was already used on this account."""

    code = "DUPLICATE_TRANSACTION"


class RepositoryUnavailableError(DomainError):
    """The store could not be reached, or failed in a way we do not model."""

    code = "REPOSITORY_UNAVAILABLE"
```

- [ ] **Step 4: Write `app/src/bgd/domain/models.py`**

```python
"""The domain model.

Frozen dataclasses rather than pydantic models, deliberately. Pydantic lives at
the API boundary in bgd.api.schemas, where parsing untrusted input is the job.
Down here the objects are already trusted and the invariants are the point, so
the two are kept as separate types rather than one model doing both.

Money is always integer minor units. No float, no Decimal, anywhere in this
package.
"""

import re
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum

from bgd.domain.errors import InvariantViolationError

_CURRENCY = re.compile(r"^[A-Z]{3}$")

# Fixed namespace so a transaction id is reproducible across processes and
# restarts. Changing it would orphan every existing idempotency key.
_TXN_NAMESPACE = uuid.UUID("6f1d5b0e-0f0a-4a9b-8f2a-6d5f9c3b1a77")

_ISO_FORMAT = "%Y-%m-%dT%H:%M:%S.%f"


class TransactionType(StrEnum):
    CREDIT = "CREDIT"
    DEBIT = "DEBIT"


@dataclass(frozen=True, slots=True)
class Money:
    amount_minor: int
    currency: str

    def __post_init__(self) -> None:
        # bool is a subclass of int, so `isinstance(True, int)` is True and
        # True would silently become one minor unit.
        if isinstance(self.amount_minor, bool) or not isinstance(self.amount_minor, int):
            raise InvariantViolationError(
                "amount_minor must be an integer number of minor units",
                amount_minor=repr(self.amount_minor),
            )
        if not _CURRENCY.match(self.currency):
            raise InvariantViolationError(
                "currency must be a three-letter uppercase ISO 4217 code",
                currency=self.currency,
            )


@dataclass(frozen=True, slots=True)
class Account:
    account_id: str
    owner_name: str
    balance: Money
    created_at: datetime

    def __post_init__(self) -> None:
        if not self.account_id:
            raise InvariantViolationError("account_id must not be empty")
        if not self.owner_name.strip():
            raise InvariantViolationError("owner_name must not be blank")

    @property
    def currency(self) -> str:
        return self.balance.currency


@dataclass(frozen=True, slots=True)
class Transaction:
    transaction_id: str
    account_id: str
    type: TransactionType
    amount: Money
    idempotency_key: str
    description: str | None
    created_at: datetime

    def __post_init__(self) -> None:
        if self.amount.amount_minor <= 0:
            raise InvariantViolationError(
                "a transaction amount must be positive; direction is carried by `type`",
                amount_minor=self.amount.amount_minor,
            )
        if not self.idempotency_key.strip():
            raise InvariantViolationError("idempotency_key must not be blank")

    @property
    def signed_amount_minor(self) -> int:
        """The delta this transaction applies to the account balance."""
        if self.type is TransactionType.DEBIT:
            return -self.amount.amount_minor
        return self.amount.amount_minor

    @property
    def minimum_balance_minor(self) -> int:
        """The balance the account must already hold for this to be allowed.

        Becomes the bound in the repository's ConditionExpression, so the
        overdraft rule is stated once, here, rather than in each backend.
        """
        if self.type is TransactionType.DEBIT:
            return self.amount.amount_minor
        return 0


def new_account_id() -> str:
    return f"acc_{uuid.uuid4().hex}"


def transaction_id_for(account_id: str, idempotency_key: str) -> str:
    """Derive the transaction id from the account and the idempotency key.

    Because the id is deterministic, idempotency needs no separate guard item
    and no secondary index: the transactions table's sort key *is* the
    idempotency check, enforced by attribute_not_exists on the write.
    """
    return f"txn_{uuid.uuid5(_TXN_NAMESPACE, f'{account_id}:{idempotency_key}').hex}"


def utcnow() -> datetime:
    return datetime.now(UTC)


def to_iso(value: datetime) -> str:
    """Fixed-width UTC ISO-8601, always 27 characters ending in Z.

    Fixed width is a correctness requirement, not cosmetics: this string is the
    sort key of the transactions LSI, DynamoDB sorts it as a string, and a
    variable-length rendering would order 10:00:00.5 before 10:00:00.05.
    """
    return value.astimezone(UTC).strftime(_ISO_FORMAT)[:26] + "Z"


def from_iso(value: str) -> datetime:
    return datetime.strptime(value, _ISO_FORMAT + "Z").replace(tzinfo=UTC)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/unit/test_domain_models.py --no-cov -q`
Expected: 14 passed

- [ ] **Step 6: Commit**

```bash
git add app/src/bgd/domain/ app/tests/unit/test_domain_models.py
git commit -m "feat(app): add the domain model and error hierarchy"
```

---

## Task 4: Repository protocol, in-memory fake, and the shared contract suite

The contract suite is the important part. A fake that drifts from the real implementation is worse than no fake, because every test above it keeps passing while production breaks. One suite, run against both, is what prevents that. Task 6 adds the second implementation to the same fixture.

**Files:**
- Create: `app/src/bgd/repository/__init__.py`, `base.py`, `memory.py`
- Test: `app/tests/contract/conftest.py`, `app/tests/contract/test_ledger_repository.py`

**Interfaces:**
- Consumes: `bgd.domain.models.{Account, Transaction, Money, TransactionType}`, `bgd.domain.errors.*`
- Produces:
  - `bgd.repository.base.Page[T]` — frozen dataclass `(items: list[T], next_cursor: str | None)`
  - `bgd.repository.base.LedgerRepository` — Protocol:
    - `create_account(account: Account) -> None` — raises `AccountAlreadyExistsError`
    - `get_account(account_id: str) -> Account | None`
    - `list_accounts(limit: int = 50) -> list[Account]`
    - `post_transaction(transaction: Transaction) -> Account` — raises `DuplicateTransactionError`, `InsufficientFundsError`, `AccountNotFoundError`; returns the account after the write
    - `get_transaction(account_id: str, transaction_id: str) -> Transaction | None`
    - `list_transactions(account_id: str, limit: int = 50, cursor: str | None = None) -> Page[Transaction]`
    - `ping() -> None` — raises `RepositoryUnavailableError`
  - `bgd.repository.memory.InMemoryLedgerRepository()`

- [ ] **Step 1: Write the failing contract fixture and suite**

`app/tests/contract/conftest.py`:

```python
"""One repository fixture, parametrised over every implementation.

Task 6 appends the DynamoDB implementation to `params`. Until then the suite
runs against the fake alone — but it is written as a contract from the start,
so adding the second backend requires no test changes.
"""

import pytest

from bgd.repository.memory import InMemoryLedgerRepository


@pytest.fixture(params=["memory"])
def repository(request: pytest.FixtureRequest):
    if request.param == "memory":
        return InMemoryLedgerRepository()
    raise AssertionError(f"unknown repository implementation: {request.param}")
```

`app/tests/contract/test_ledger_repository.py`:

```python
"""The LedgerRepository contract.

Every implementation must satisfy all of this. The fake exists so the API tests
never touch boto3; this suite is what makes the fake trustworthy.
"""

from datetime import UTC, datetime, timedelta

import pytest

from bgd.domain.errors import (
    AccountAlreadyExistsError,
    AccountNotFoundError,
    DuplicateTransactionError,
    InsufficientFundsError,
)
from bgd.domain.models import (
    Account,
    Money,
    Transaction,
    TransactionType,
    to_iso,
    transaction_id_for,
    utcnow,
)

BASE_TIME = datetime(2026, 8, 5, 10, 0, 0, tzinfo=UTC)


def at(seconds: int) -> datetime:
    """Explicit, well-separated timestamps for the ordering tests.

    utcnow() would be correct but flaky here: these calls are direct dict
    operations, so two can land in the same microsecond, and the sort tiebreak
    is a uuid5 hash rather than anything chronological.
    """
    return BASE_TIME + timedelta(seconds=seconds)


def make_account(account_id: str = "acc_1", balance_minor: int = 10_000) -> Account:
    return Account(
        account_id=account_id,
        owner_name="Ada Lovelace",
        balance=Money(balance_minor, "EUR"),
        created_at=utcnow(),
    )


def make_transaction(
    account_id: str = "acc_1",
    kind: TransactionType = TransactionType.DEBIT,
    amount_minor: int = 2_500,
    key: str = "key-1",
    created_at: datetime | None = None,
) -> Transaction:
    return Transaction(
        transaction_id=transaction_id_for(account_id, key),
        account_id=account_id,
        type=kind,
        amount=Money(amount_minor, "EUR"),
        idempotency_key=key,
        description="rent",
        created_at=created_at if created_at is not None else utcnow(),
    )


# --- accounts ---------------------------------------------------------------


def test_an_account_round_trips(repository) -> None:
    account = make_account()
    repository.create_account(account)
    fetched = repository.get_account("acc_1")
    assert fetched is not None
    assert fetched.account_id == "acc_1"
    assert fetched.owner_name == "Ada Lovelace"
    assert fetched.balance == Money(10_000, "EUR")


def test_an_unknown_account_is_none(repository) -> None:
    assert repository.get_account("acc_missing") is None


def test_creating_the_same_account_twice_is_rejected(repository) -> None:
    repository.create_account(make_account())
    with pytest.raises(AccountAlreadyExistsError):
        repository.create_account(make_account())


def test_accounts_can_be_listed(repository) -> None:
    repository.create_account(make_account("acc_1"))
    repository.create_account(make_account("acc_2"))
    assert {a.account_id for a in repository.list_accounts()} == {"acc_1", "acc_2"}


def test_listing_accounts_honours_the_limit(repository) -> None:
    for index in range(5):
        repository.create_account(make_account(f"acc_{index}"))
    assert len(repository.list_accounts(limit=3)) == 3


# --- posting transactions ---------------------------------------------------


def test_a_credit_increases_the_balance(repository) -> None:
    repository.create_account(make_account(balance_minor=10_000))
    account = repository.post_transaction(
        make_transaction(kind=TransactionType.CREDIT, amount_minor=1_500)
    )
    assert account.balance.amount_minor == 11_500


def test_a_debit_decreases_the_balance(repository) -> None:
    repository.create_account(make_account(balance_minor=10_000))
    account = repository.post_transaction(
        make_transaction(kind=TransactionType.DEBIT, amount_minor=2_500)
    )
    assert account.balance.amount_minor == 7_500


def test_a_debit_may_bring_the_balance_exactly_to_zero(repository) -> None:
    repository.create_account(make_account(balance_minor=2_500))
    account = repository.post_transaction(
        make_transaction(kind=TransactionType.DEBIT, amount_minor=2_500)
    )
    assert account.balance.amount_minor == 0


def test_a_debit_beyond_the_balance_is_rejected(repository) -> None:
    repository.create_account(make_account(balance_minor=1_000))
    with pytest.raises(InsufficientFundsError):
        repository.post_transaction(
            make_transaction(kind=TransactionType.DEBIT, amount_minor=2_500)
        )


def test_a_rejected_debit_writes_nothing_at_all(repository) -> None:
    """The atomicity guarantee. If the balance condition fails, the transaction
    record must not survive — otherwise the history shows a payment that never
    happened."""
    repository.create_account(make_account(balance_minor=1_000))
    transaction = make_transaction(kind=TransactionType.DEBIT, amount_minor=2_500)
    with pytest.raises(InsufficientFundsError):
        repository.post_transaction(transaction)

    assert repository.get_account("acc_1").balance.amount_minor == 1_000
    assert repository.get_transaction("acc_1", transaction.transaction_id) is None
    assert repository.list_transactions("acc_1").items == []


def test_posting_to_an_unknown_account_is_rejected(repository) -> None:
    with pytest.raises(AccountNotFoundError):
        repository.post_transaction(make_transaction(account_id="acc_missing"))


def test_the_same_transaction_id_is_rejected_and_applied_once(repository) -> None:
    repository.create_account(make_account(balance_minor=10_000))
    transaction = make_transaction(amount_minor=2_500)
    repository.post_transaction(transaction)

    with pytest.raises(DuplicateTransactionError):
        repository.post_transaction(transaction)

    assert repository.get_account("acc_1").balance.amount_minor == 7_500


# --- reading transactions ---------------------------------------------------


def test_a_transaction_round_trips(repository) -> None:
    repository.create_account(make_account())
    transaction = make_transaction()
    repository.post_transaction(transaction)

    fetched = repository.get_transaction("acc_1", transaction.transaction_id)
    assert fetched is not None
    assert fetched.amount == Money(2_500, "EUR")
    assert fetched.type is TransactionType.DEBIT
    assert fetched.idempotency_key == "key-1"
    assert fetched.description == "rent"


def test_an_unknown_transaction_is_none(repository) -> None:
    assert repository.get_transaction("acc_1", "txn_missing") is None


def test_transactions_are_listed_newest_first(repository) -> None:
    repository.create_account(make_account(balance_minor=100_000))
    for index in range(3):
        repository.post_transaction(
            make_transaction(amount_minor=100 + index, key=f"k{index}", created_at=at(index))
        )

    listed = repository.list_transactions("acc_1").items
    assert [t.amount.amount_minor for t in listed] == [102, 101, 100]


def test_listing_transactions_paginates_with_an_opaque_cursor(repository) -> None:
    repository.create_account(make_account(balance_minor=100_000))
    for index in range(5):
        repository.post_transaction(
            make_transaction(amount_minor=100 + index, key=f"k{index}", created_at=at(index))
        )

    first = repository.list_transactions("acc_1", limit=2)
    assert len(first.items) == 2
    assert isinstance(first.next_cursor, str)

    second = repository.list_transactions("acc_1", limit=2, cursor=first.next_cursor)
    assert len(second.items) == 2

    seen = [t.amount.amount_minor for t in first.items + second.items]
    assert seen == [104, 103, 102, 101]
    assert len(set(seen)) == 4


def test_the_last_page_reports_no_cursor(repository) -> None:
    repository.create_account(make_account(balance_minor=100_000))
    repository.post_transaction(make_transaction(key="k0"))
    assert repository.list_transactions("acc_1", limit=10).next_cursor is None


def test_listing_transactions_for_an_unknown_account_is_empty(repository) -> None:
    page = repository.list_transactions("acc_missing")
    assert page.items == []
    assert page.next_cursor is None


def test_transactions_of_other_accounts_are_not_returned(repository) -> None:
    repository.create_account(make_account("acc_1"))
    repository.create_account(make_account("acc_2"))
    repository.post_transaction(make_transaction(account_id="acc_1", key="k1"))
    repository.post_transaction(make_transaction(account_id="acc_2", key="k2"))

    assert len(repository.list_transactions("acc_1").items) == 1


# --- health -----------------------------------------------------------------


def test_ping_succeeds_when_the_store_is_reachable(repository) -> None:
    repository.ping()


def test_created_at_is_stored_as_a_fixed_width_string(repository) -> None:
    """Guards the LSI sort key format across both backends."""
    repository.create_account(make_account())
    transaction = make_transaction()
    repository.post_transaction(transaction)
    fetched = repository.get_transaction("acc_1", transaction.transaction_id)
    assert len(to_iso(fetched.created_at)) == 27
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/contract --no-cov -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'bgd.repository'`

- [ ] **Step 3: Write `app/src/bgd/repository/base.py`**

```python
"""The repository contract.

One Protocol covering both entities, not one per entity. Posting a transaction
writes the transaction record and the account balance in a single atomic
operation; splitting the interface would advertise an independence that does
not exist, and neither half could implement post_transaction alone.
"""

from dataclasses import dataclass
from typing import Protocol

from bgd.domain.models import Account, Transaction


@dataclass(frozen=True, slots=True)
class Page[T]:
    items: list[T]
    next_cursor: str | None = None


class LedgerRepository(Protocol):
    def create_account(self, account: Account) -> None:
        """Raise AccountAlreadyExistsError if the id is taken."""
        ...

    def get_account(self, account_id: str) -> Account | None: ...

    def list_accounts(self, limit: int = 50) -> list[Account]: ...

    def post_transaction(self, transaction: Transaction) -> Account:
        """Apply the transaction atomically and return the account after it.

        Raises DuplicateTransactionError if the id was already used,
        AccountNotFoundError if the account is gone, and InsufficientFundsError if the
        balance would go negative. On any of them nothing is written.
        """
        ...

    def get_transaction(self, account_id: str, transaction_id: str) -> Transaction | None: ...

    def list_transactions(
        self, account_id: str, limit: int = 50, cursor: str | None = None
    ) -> Page[Transaction]:
        """Newest first. `cursor` is opaque and comes from a previous Page."""
        ...

    def ping(self) -> None:
        """Raise RepositoryUnavailableError if the store cannot be reached."""
        ...
```

- [ ] **Step 4: Write `app/src/bgd/repository/memory.py`**

```python
"""In-memory LedgerRepository, for tests and local experimentation.

Held to the same contract suite as the DynamoDB implementation, including the
atomicity guarantee: a rejected debit must leave no trace. Here that is free
because the checks happen before any mutation — but it is asserted rather than
assumed, because that is the property the API layer's tests rely on.

Not thread-safe and not intended to be. Tests are single-threaded, and
production uses DynamoDB.
"""

import base64
import json

from bgd.domain.errors import (
    AccountAlreadyExistsError,
    AccountNotFoundError,
    DuplicateTransactionError,
    InsufficientFundsError,
)
from bgd.domain.models import Account, Money, Transaction
from bgd.repository.base import Page


def _encode_cursor(transaction_id: str) -> str:
    return base64.urlsafe_b64encode(json.dumps({"t": transaction_id}).encode()).decode()


def _decode_cursor(cursor: str) -> str:
    return json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())["t"]


class InMemoryLedgerRepository:
    def __init__(self) -> None:
        self._accounts: dict[str, Account] = {}
        # account_id -> transaction_id -> Transaction
        self._transactions: dict[str, dict[str, Transaction]] = {}

    # --- accounts ---

    def create_account(self, account: Account) -> None:
        if account.account_id in self._accounts:
            raise AccountAlreadyExistsError(
                "an account with that id already exists", account_id=account.account_id
            )
        self._accounts[account.account_id] = account

    def get_account(self, account_id: str) -> Account | None:
        return self._accounts.get(account_id)

    def list_accounts(self, limit: int = 50) -> list[Account]:
        return list(self._accounts.values())[:limit]

    # --- transactions ---

    def post_transaction(self, transaction: Transaction) -> Account:
        stored = self._transactions.setdefault(transaction.account_id, {})
        if transaction.transaction_id in stored:
            raise DuplicateTransactionError(
                "that idempotency key was already used on this account",
                account_id=transaction.account_id,
                idempotency_key=transaction.idempotency_key,
            )

        account = self._accounts.get(transaction.account_id)
        if account is None:
            raise AccountNotFoundError("no such account", account_id=transaction.account_id)

        if account.balance.amount_minor < transaction.minimum_balance_minor:
            raise InsufficientFundsError(
                "the account balance is too low for this debit",
                account_id=transaction.account_id,
                balance_minor=account.balance.amount_minor,
                requested_minor=transaction.amount.amount_minor,
            )

        # Both checks passed — only now does anything change.
        updated = Account(
            account_id=account.account_id,
            owner_name=account.owner_name,
            balance=Money(
                account.balance.amount_minor + transaction.signed_amount_minor,
                account.balance.currency,
            ),
            created_at=account.created_at,
        )
        self._accounts[account.account_id] = updated
        stored[transaction.transaction_id] = transaction
        return updated

    def get_transaction(self, account_id: str, transaction_id: str) -> Transaction | None:
        return self._transactions.get(account_id, {}).get(transaction_id)

    def list_transactions(
        self, account_id: str, limit: int = 50, cursor: str | None = None
    ) -> Page[Transaction]:
        # Newest first, matching the DynamoDB LSI queried with
        # ScanIndexForward=False. transaction_id breaks ties so the order is
        # total, and therefore so is the cursor.
        ordered = sorted(
            self._transactions.get(account_id, {}).values(),
            key=lambda t: (t.created_at, t.transaction_id),
            reverse=True,
        )

        start = 0
        if cursor is not None:
            after = _decode_cursor(cursor)
            start = next(
                (i + 1 for i, t in enumerate(ordered) if t.transaction_id == after),
                len(ordered),
            )

        window = ordered[start : start + limit]
        has_more = start + limit < len(ordered)
        return Page(
            items=window,
            next_cursor=_encode_cursor(window[-1].transaction_id) if has_more and window else None,
        )

    def ping(self) -> None:
        return None
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/contract --no-cov -q`
Expected: 21 passed

- [ ] **Step 6: Commit**

```bash
git add app/src/bgd/repository/ app/tests/contract/
git commit -m "feat(app): add the repository contract and in-memory implementation"
```

---

## Task 5: The ledger service

The use-case layer. Owns the rules that are not any single repository's business: currency matching, id generation, and idempotent replay.

**Files:**
- Create: `app/src/bgd/domain/services.py`
- Test: `app/tests/unit/test_domain_services.py`

**Interfaces:**
- Consumes: `bgd.repository.base.{LedgerRepository, Page}`, `bgd.domain.models.*`, `bgd.domain.errors.*`
- Produces: `bgd.domain.services.LedgerService(repository, *, clock=utcnow, id_factory=new_account_id)` with:
  - `open_account(owner_name: str, currency: str, initial_balance_minor: int = 0) -> Account`
  - `get_account(account_id: str) -> Account` — raises `AccountNotFoundError`
  - `list_accounts(limit: int = 50) -> list[Account]`
  - `post_transaction(*, account_id, transaction_type, amount_minor, currency, idempotency_key, description=None) -> tuple[Transaction, Account, bool]` — the bool is `created`: `True` for a new transaction, `False` for an idempotent replay. The parameter is `transaction_type`, not `type`, because ruff's `A002` rejects shadowing a builtin; the *wire* field stays `type`.
  - `list_transactions(account_id, limit=50, cursor=None) -> Page[Transaction]` — raises `AccountNotFoundError`

- [ ] **Step 1: Write the failing tests**

`app/tests/unit/test_domain_services.py`:

```python
from datetime import UTC, datetime

import pytest

from bgd.domain.errors import (
    AccountNotFoundError,
    CurrencyMismatchError,
    InsufficientFundsError,
    InvariantViolationError,
)
from bgd.domain.models import TransactionType
from bgd.domain.services import LedgerService
from bgd.repository.memory import InMemoryLedgerRepository

FIXED_TIME = datetime(2026, 8, 5, 10, 0, 0, 123456, tzinfo=UTC)


@pytest.fixture
def service() -> LedgerService:
    counter = iter(f"acc_{index:04d}" for index in range(1000))
    return LedgerService(
        InMemoryLedgerRepository(),
        clock=lambda: FIXED_TIME,
        id_factory=lambda: next(counter),
    )


def test_open_account_assigns_an_id_and_the_opening_balance(service) -> None:
    account = service.open_account("Ada Lovelace", "EUR", initial_balance_minor=5_000)
    assert account.account_id == "acc_0000"
    assert account.balance.amount_minor == 5_000
    assert account.balance.currency == "EUR"
    assert account.created_at == FIXED_TIME


def test_open_account_defaults_to_a_zero_balance(service) -> None:
    assert service.open_account("Ada", "EUR").balance.amount_minor == 0


def test_open_account_rejects_a_negative_opening_balance(service) -> None:
    with pytest.raises(InvariantViolationError):
        service.open_account("Ada", "EUR", initial_balance_minor=-1)


def test_get_account_raises_for_an_unknown_id(service) -> None:
    with pytest.raises(AccountNotFoundError):
        service.get_account("acc_missing")


def test_posting_a_credit_returns_created_true(service) -> None:
    account = service.open_account("Ada", "EUR", 10_000)
    transaction, updated, created = service.post_transaction(
        account_id=account.account_id,
        transaction_type=TransactionType.CREDIT,
        amount_minor=1_500,
        currency="EUR",
        idempotency_key="key-1",
    )
    assert created is True
    assert updated.balance.amount_minor == 11_500
    assert transaction.type is TransactionType.CREDIT


def test_replaying_an_idempotency_key_returns_the_original_and_created_false(service) -> None:
    """The balance must move exactly once, and the caller must get the stored
    transaction back rather than an error."""
    account = service.open_account("Ada", "EUR", 10_000)
    kwargs = {
        "account_id": account.account_id,
        "transaction_type": TransactionType.DEBIT,
        "amount_minor": 2_500,
        "currency": "EUR",
        "idempotency_key": "key-1",
    }

    first, _, created_first = service.post_transaction(**kwargs)
    second, updated, created_second = service.post_transaction(**kwargs)

    assert created_first is True
    assert created_second is False
    assert second.transaction_id == first.transaction_id
    assert updated.balance.amount_minor == 7_500


def test_a_currency_that_differs_from_the_account_is_rejected(service) -> None:
    account = service.open_account("Ada", "EUR", 10_000)
    with pytest.raises(CurrencyMismatchError):
        service.post_transaction(
            account_id=account.account_id,
            transaction_type=TransactionType.DEBIT,
            amount_minor=100,
            currency="USD",
            idempotency_key="key-1",
        )


def test_posting_to_an_unknown_account_raises(service) -> None:
    with pytest.raises(AccountNotFoundError):
        service.post_transaction(
            account_id="acc_missing",
            transaction_type=TransactionType.CREDIT,
            amount_minor=100,
            currency="EUR",
            idempotency_key="key-1",
        )


def test_an_overdraft_is_rejected(service) -> None:
    account = service.open_account("Ada", "EUR", 1_000)
    with pytest.raises(InsufficientFundsError):
        service.post_transaction(
            account_id=account.account_id,
            transaction_type=TransactionType.DEBIT,
            amount_minor=2_500,
            currency="EUR",
            idempotency_key="key-1",
        )


def test_a_non_positive_amount_is_rejected(service) -> None:
    account = service.open_account("Ada", "EUR", 10_000)
    with pytest.raises(InvariantViolationError):
        service.post_transaction(
            account_id=account.account_id,
            transaction_type=TransactionType.DEBIT,
            amount_minor=0,
            currency="EUR",
            idempotency_key="key-1",
        )


def test_the_same_key_on_two_accounts_is_two_transactions(service) -> None:
    first = service.open_account("Ada", "EUR", 10_000)
    second = service.open_account("Grace", "EUR", 10_000)
    for account in (first, second):
        service.post_transaction(
            account_id=account.account_id,
            transaction_type=TransactionType.DEBIT,
            amount_minor=100,
            currency="EUR",
            idempotency_key="shared-key",
        )
    assert service.get_account(first.account_id).balance.amount_minor == 9_900
    assert service.get_account(second.account_id).balance.amount_minor == 9_900


def test_listing_transactions_for_an_unknown_account_raises(service) -> None:
    with pytest.raises(AccountNotFoundError):
        service.list_transactions("acc_missing")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/unit/test_domain_services.py --no-cov -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'bgd.domain.services'`

- [ ] **Step 3: Write `app/src/bgd/domain/services.py`**

```python
"""Use cases.

The clock and the id factory are injected so tests get deterministic output
without patching module globals.
"""

from collections.abc import Callable
from datetime import datetime

from bgd.domain.errors import (
    AccountNotFoundError,
    CurrencyMismatchError,
    DuplicateTransactionError,
    InvariantViolationError,
)
from bgd.domain.models import (
    Account,
    Money,
    Transaction,
    TransactionType,
    new_account_id,
    transaction_id_for,
    utcnow,
)
from bgd.repository.base import LedgerRepository, Page


class LedgerService:
    def __init__(
        self,
        repository: LedgerRepository,
        *,
        clock: Callable[[], datetime] = utcnow,
        id_factory: Callable[[], str] = new_account_id,
    ) -> None:
        self._repository = repository
        self._clock = clock
        self._id_factory = id_factory

    # --- accounts ---

    def open_account(
        self, owner_name: str, currency: str, initial_balance_minor: int = 0
    ) -> Account:
        if initial_balance_minor < 0:
            raise InvariantViolationError(
                "an account cannot be opened overdrawn",
                initial_balance_minor=initial_balance_minor,
            )

        account = Account(
            account_id=self._id_factory(),
            owner_name=owner_name,
            balance=Money(initial_balance_minor, currency),
            created_at=self._clock(),
        )
        self._repository.create_account(account)
        return account

    def get_account(self, account_id: str) -> Account:
        account = self._repository.get_account(account_id)
        if account is None:
            raise AccountNotFoundError("no such account", account_id=account_id)
        return account

    def list_accounts(self, limit: int = 50) -> list[Account]:
        return self._repository.list_accounts(limit=limit)

    # --- transactions ---

    def post_transaction(
        self,
        *,
        account_id: str,
        transaction_type: TransactionType,
        amount_minor: int,
        currency: str,
        idempotency_key: str,
        description: str | None = None,
    ) -> tuple[Transaction, Account, bool]:
        """Apply a transaction. Returns (transaction, account, created).

        `created` is False when the idempotency key was already used with the
        same account — the stored transaction is returned instead of an error,
        which is what makes a client retry safe.
        """
        # Read first, so a currency mismatch and a missing account are reported
        # precisely rather than as a generic condition failure. The account
        # currency is immutable, so there is no meaningful race here.
        account = self.get_account(account_id)
        if account.currency != currency:
            raise CurrencyMismatchError(
                "the transaction currency does not match the account",
                account_currency=account.currency,
                transaction_currency=currency,
            )

        transaction = Transaction(
            transaction_id=transaction_id_for(account_id, idempotency_key),
            account_id=account_id,
            type=transaction_type,
            amount=Money(amount_minor, currency),
            idempotency_key=idempotency_key,
            description=description,
            created_at=self._clock(),
        )

        try:
            updated = self._repository.post_transaction(transaction)
        except DuplicateTransactionError:
            existing = self._repository.get_transaction(account_id, transaction.transaction_id)
            if existing is None:
                # Written and removed between the two calls. Nothing sensible
                # to return, so let the original error stand.
                raise
            return existing, self.get_account(account_id), False

        return transaction, updated, True

    def list_transactions(
        self, account_id: str, limit: int = 50, cursor: str | None = None
    ) -> Page[Transaction]:
        self.get_account(account_id)  # 404 rather than an empty list
        return self._repository.list_transactions(account_id, limit=limit, cursor=cursor)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/unit/test_domain_services.py --no-cov -q`
Expected: 12 passed

- [ ] **Step 5: Commit**

```bash
git add app/src/bgd/domain/services.py app/tests/unit/test_domain_services.py
git commit -m "feat(app): add the ledger service with idempotent transaction replay"
```

---

## Task 6: The DynamoDB repository

The contract suite already exists. This task adds the second implementation behind it, running against **DynamoDB Local**, plus a characterisation test pinning the semantics §F3 recorded — so if an image bump changes the error shape, the failure names the cause instead of appearing as a mysterious 500.

**This task needs `make local-up` running.** The contract fixture fails with an explicit instruction if it is not.

**Files:**
- Create: `app/src/bgd/repository/schema.py`, `app/src/bgd/repository/dynamodb.py`
- Test: `app/tests/contract/test_dynamodb_errors.py`
- Modify: `app/tests/contract/conftest.py` (add the DynamoDB Local plumbing and the `dynamodb` param)

**Interfaces:**
- Consumes: everything from Task 4, plus `bgd.config.Settings`
- Produces:
  - `bgd.repository.schema.TRANSACTIONS_BY_CREATED_AT_INDEX: str` = `"created_at-index"`
  - `bgd.repository.schema.table_definitions(accounts_table: str, transactions_table: str) -> list[dict]` — `create_table` kwargs
  - `bgd.repository.dynamodb.build_client(settings: Settings)` — a boto3 DynamoDB client
  - `bgd.repository.dynamodb.DynamoDbLedgerRepository(client, accounts_table: str, transactions_table: str)`

- [ ] **Step 1: Write the characterisation test**

`app/tests/contract/test_dynamodb_errors.py`:

```python
"""Pins the DynamoDB semantics this repository decodes.

Verified against DynamoDB Local, digest ff89bd48…, on 2026-08-05. If an image
bump changes the shape, this fails with an obvious name rather than surfacing
as an unexplained 500 out of post_transaction.

Two behaviours are pinned that the repository depends on and that are not
obvious from the API reference:

  1. CancellationReasons is positional — index 0 is the Put, index 1 is the
     balance Update.
  2. An absent account and an insufficient balance produce the *same* reason
     code, because one ConditionExpression yields one code and ours combines
     both checks. ReturnValuesOnConditionCheckFailure is what separates them:
     the old item comes back only when there was one.
"""

import pytest
from botocore.exceptions import ClientError


def reasons(error: ClientError) -> list[str]:
    return [reason.get("Code") for reason in error.response.get("CancellationReasons", [])]


def post(client, accounts, transactions, transaction_id, delta, minimum, account_id="acc_1"):
    return client.transact_write_items(
        TransactItems=[
            {
                "Put": {
                    "TableName": transactions,
                    "Item": {
                        "account_id": {"S": account_id},
                        "transaction_id": {"S": transaction_id},
                        "created_at": {"S": "2026-08-05T10:00:00.000001Z"},
                    },
                    "ConditionExpression": "attribute_not_exists(transaction_id)",
                }
            },
            {
                "Update": {
                    "TableName": accounts,
                    "Key": {"account_id": {"S": account_id}},
                    "UpdateExpression": "SET balance_minor = balance_minor + :delta",
                    "ConditionExpression": (
                        "attribute_exists(account_id) AND balance_minor >= :minimum"
                    ),
                    "ExpressionAttributeValues": {
                        ":delta": {"N": str(delta)},
                        ":minimum": {"N": str(minimum)},
                    },
                    "ReturnValuesOnConditionCheckFailure": "ALL_OLD",
                }
            },
        ]
    )


@pytest.fixture
def ledger(dynamodb_tables):
    client, accounts, transactions = dynamodb_tables
    client.put_item(
        TableName=accounts,
        Item={"account_id": {"S": "acc_1"}, "balance_minor": {"N": "10000"}},
    )
    return client, accounts, transactions


def test_a_duplicate_put_fails_at_index_zero(ledger) -> None:
    client, accounts, transactions = ledger
    post(client, accounts, transactions, "txn_a", -2500, 2500)
    with pytest.raises(ClientError) as caught:
        post(client, accounts, transactions, "txn_a", -2500, 2500)

    assert caught.value.response["Error"]["Code"] == "TransactionCanceledException"
    assert reasons(caught.value) == ["ConditionalCheckFailed", "None"]


def test_an_insufficient_balance_fails_at_index_one_and_returns_the_account(ledger) -> None:
    client, accounts, transactions = ledger
    with pytest.raises(ClientError) as caught:
        post(client, accounts, transactions, "txn_b", -999_999, 999_999)

    assert reasons(caught.value) == ["None", "ConditionalCheckFailed"]
    failed = caught.value.response["CancellationReasons"][1]
    assert failed["Item"]["balance_minor"]["N"] == "10000"


def test_a_missing_account_fails_at_index_one_with_no_item(ledger) -> None:
    """Identical reason code to an insufficient balance. The presence of `Item`
    is the only discriminator, which is why the repository reads it rather than
    issuing a second GetItem."""
    client, accounts, transactions = ledger
    with pytest.raises(ClientError) as caught:
        post(client, accounts, transactions, "txn_c", -1, 1, account_id="acc_gone")

    assert reasons(caught.value) == ["None", "ConditionalCheckFailed"]
    assert "Item" not in caught.value.response["CancellationReasons"][1]


def test_a_failed_transaction_writes_nothing(ledger) -> None:
    client, accounts, transactions = ledger
    with pytest.raises(ClientError):
        post(client, accounts, transactions, "txn_b", -999_999, 999_999)

    stored = client.get_item(
        TableName=transactions,
        Key={"account_id": {"S": "acc_1"}, "transaction_id": {"S": "txn_b"}},
    )
    assert "Item" not in stored
    account = client.get_item(TableName=accounts, Key={"account_id": {"S": "acc_1"}})
    assert account["Item"]["balance_minor"]["N"] == "10000"


def test_the_index_returns_newest_first_and_paginates(dynamodb_tables) -> None:
    client, _accounts, transactions = dynamodb_tables
    for index in range(5):
        client.put_item(
            TableName=transactions,
            Item={
                "account_id": {"S": "acc_2"},
                "transaction_id": {"S": f"txn_{index}"},
                "created_at": {"S": f"2026-08-05T10:00:0{index}.000000Z"},
            },
        )

    query = {
        "TableName": transactions,
        "IndexName": "created_at-index",
        "KeyConditionExpression": "account_id = :a",
        "ExpressionAttributeValues": {":a": {"S": "acc_2"}},
        "ScanIndexForward": False,
        "Limit": 2,
    }
    first = client.query(**query)
    assert [item["transaction_id"]["S"] for item in first["Items"]] == ["txn_4", "txn_3"]

    # The cursor must carry all three keys — the index's two plus the table's
    # sort key — which is why it is encoded whole rather than field by field.
    assert sorted(first["LastEvaluatedKey"]) == ["account_id", "created_at", "transaction_id"]

    second = client.query(**query, ExclusiveStartKey=first["LastEvaluatedKey"])
    assert [item["transaction_id"]["S"] for item in second["Items"]] == ["txn_2", "txn_1"]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
make local-up
cd app && ../app/.venv/bin/python -m pytest tests/contract/test_dynamodb_errors.py --no-cov -q
```

Expected: FAIL — `ModuleNotFoundError: No module named 'bgd.repository.schema'`. If instead it fails with "DynamoDB Local is not reachable", the container did not start — check `docker compose ps` in `app/`.

- [ ] **Step 3: Write `app/src/bgd/repository/schema.py`**

```python
"""DynamoDB table definitions — the single source of truth.

Read by the local bootstrap (bgd.cli.create_tables) and by the tests, so local
development and CI cannot drift apart. Phases 5 and 6 declare the same shape in
Terraform; this module is the reference they are written against, and the LSI
in particular is easy to omit there and impossible to add later without
recreating the table.

Key design:

  accounts       PK account_id
  transactions   PK account_id, SK transaction_id
                 LSI created_at-index: PK account_id, SK created_at

transaction_id is derived from the idempotency key (see
domain.models.transaction_id_for), so the table's sort key *is* the idempotency
guard — attribute_not_exists on the write is the whole mechanism. No separate
guard item and no GSI.

The LSI exists because listing needs newest-first order with real pagination.
An LSI must be created with the table; it cannot be added afterwards.
"""

TRANSACTIONS_BY_CREATED_AT_INDEX = "created_at-index"


def table_definitions(accounts_table: str, transactions_table: str) -> list[dict]:
    return [
        {
            "TableName": accounts_table,
            "KeySchema": [{"AttributeName": "account_id", "KeyType": "HASH"}],
            "AttributeDefinitions": [{"AttributeName": "account_id", "AttributeType": "S"}],
            "BillingMode": "PAY_PER_REQUEST",
        },
        {
            "TableName": transactions_table,
            "KeySchema": [
                {"AttributeName": "account_id", "KeyType": "HASH"},
                {"AttributeName": "transaction_id", "KeyType": "RANGE"},
            ],
            "AttributeDefinitions": [
                {"AttributeName": "account_id", "AttributeType": "S"},
                {"AttributeName": "transaction_id", "AttributeType": "S"},
                {"AttributeName": "created_at", "AttributeType": "S"},
            ],
            "LocalSecondaryIndexes": [
                {
                    "IndexName": TRANSACTIONS_BY_CREATED_AT_INDEX,
                    "KeySchema": [
                        {"AttributeName": "account_id", "KeyType": "HASH"},
                        {"AttributeName": "created_at", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                }
            ],
            "BillingMode": "PAY_PER_REQUEST",
        },
    ]
```

- [ ] **Step 4: Write `app/src/bgd/repository/dynamodb.py`**

```python
"""The DynamoDB LedgerRepository.

Uses the low-level client rather than the resource interface so the wire types
and the error payloads are explicit — CancellationReasons decoding below
depends on both.
"""

import base64
import json
import logging

from boto3.dynamodb.types import TypeDeserializer, TypeSerializer
from botocore.exceptions import BotoCoreError, ClientError

from bgd.domain.errors import (
    AccountAlreadyExistsError,
    AccountNotFoundError,
    DuplicateTransactionError,
    InsufficientFundsError,
    RepositoryUnavailableError,
)
from bgd.domain.models import (
    Account,
    Money,
    Transaction,
    TransactionType,
    from_iso,
    to_iso,
)
from bgd.repository.base import Page
from bgd.repository.schema import TRANSACTIONS_BY_CREATED_AT_INDEX

logger = logging.getLogger(__name__)

_serializer = TypeSerializer()
_deserializer = TypeDeserializer()


def _to_item(values: dict) -> dict:
    return {key: _serializer.serialize(value) for key, value in values.items()}


def _from_item(item: dict) -> dict:
    return {key: _deserializer.deserialize(value) for key, value in item.items()}


def _encode_cursor(key: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(key).encode()).decode()


def _decode_cursor(cursor: str) -> dict:
    return json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())


def build_client(settings):
    """Build a DynamoDB client for these settings.

    When an endpoint URL is set we are talking to DynamoDB Local, which accepts
    any credentials but rejects none. Supplying explicit dummy credentials
    keeps `docker compose up` working without an AWS profile or an SSO session.
    """
    import boto3

    kwargs: dict = {"region_name": settings.aws_region}
    if settings.dynamodb_endpoint_url:
        kwargs["endpoint_url"] = settings.dynamodb_endpoint_url
        kwargs["aws_access_key_id"] = "local"
        kwargs["aws_secret_access_key"] = "local"
    return boto3.client("dynamodb", **kwargs)


def _account_from_item(item: dict) -> Account:
    values = _from_item(item)
    return Account(
        account_id=values["account_id"],
        owner_name=values["owner_name"],
        balance=Money(int(values["balance_minor"]), values["currency"]),
        created_at=from_iso(values["created_at"]),
    )


def _transaction_from_item(item: dict) -> Transaction:
    values = _from_item(item)
    return Transaction(
        transaction_id=values["transaction_id"],
        account_id=values["account_id"],
        type=TransactionType(values["type"]),
        amount=Money(int(values["amount_minor"]), values["currency"]),
        idempotency_key=values["idempotency_key"],
        description=values.get("description"),
        created_at=from_iso(values["created_at"]),
    )


class DynamoDbLedgerRepository:
    def __init__(self, client, accounts_table: str, transactions_table: str) -> None:
        self._client = client
        self._accounts = accounts_table
        self._transactions = transactions_table

    # --- accounts ---

    def create_account(self, account: Account) -> None:
        try:
            self._client.put_item(
                TableName=self._accounts,
                Item=_to_item(
                    {
                        "account_id": account.account_id,
                        "owner_name": account.owner_name,
                        "currency": account.balance.currency,
                        "balance_minor": account.balance.amount_minor,
                        "created_at": to_iso(account.created_at),
                    }
                ),
                ConditionExpression="attribute_not_exists(account_id)",
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise AccountAlreadyExistsError(
                    "an account with that id already exists", account_id=account.account_id
                ) from error
            raise self._unavailable(error) from error

    def get_account(self, account_id: str) -> Account | None:
        try:
            response = self._client.get_item(
                TableName=self._accounts, Key=_to_item({"account_id": account_id})
            )
        except (ClientError, BotoCoreError) as error:
            raise self._unavailable(error) from error
        item = response.get("Item")
        return _account_from_item(item) if item else None

    def list_accounts(self, limit: int = 50) -> list[Account]:
        # A Scan, deliberately. The accounts table is small by design and there
        # is no access pattern that would justify an index here.
        try:
            response = self._client.scan(TableName=self._accounts, Limit=limit)
        except (ClientError, BotoCoreError) as error:
            raise self._unavailable(error) from error
        return [_account_from_item(item) for item in response.get("Items", [])]

    # --- transactions ---

    def post_transaction(self, transaction: Transaction) -> Account:
        item = {
            "account_id": transaction.account_id,
            "transaction_id": transaction.transaction_id,
            "type": str(transaction.type),
            "amount_minor": transaction.amount.amount_minor,
            "currency": transaction.amount.currency,
            "idempotency_key": transaction.idempotency_key,
            "created_at": to_iso(transaction.created_at),
        }
        if transaction.description is not None:
            item["description"] = transaction.description

        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Put": {
                            "TableName": self._transactions,
                            "Item": _to_item(item),
                            "ConditionExpression": "attribute_not_exists(transaction_id)",
                        }
                    },
                    {
                        "Update": {
                            "TableName": self._accounts,
                            "Key": _to_item({"account_id": transaction.account_id}),
                            "UpdateExpression": "SET balance_minor = balance_minor + :delta",
                            "ConditionExpression": (
                                "attribute_exists(account_id) AND balance_minor >= :minimum"
                            ),
                            "ExpressionAttributeValues": _to_item(
                                {
                                    ":delta": transaction.signed_amount_minor,
                                    ":minimum": transaction.minimum_balance_minor,
                                }
                            ),
                            # Returns the account as the condition saw it when
                            # the condition fails. That payload is what tells a
                            # missing account apart from an insufficient
                            # balance without a second read (§F3).
                            "ReturnValuesOnConditionCheckFailure": "ALL_OLD",
                        }
                    },
                ]
            )
        except ClientError as error:
            raise self._translate_cancellation(error, transaction) from error
        except BotoCoreError as error:
            raise self._unavailable(error) from error

        account = self.get_account(transaction.account_id)
        if account is None:  # pragma: no cover - the write just succeeded
            raise AccountNotFoundError("account vanished after a successful write")
        return account

    def _translate_cancellation(self, error: ClientError, transaction: Transaction) -> Exception:
        """Decode a TransactionCanceledException into a domain error.

        CancellationReasons is positional: index 0 is the Put, index 1 is the
        balance Update. Index 1 is ambiguous on its own — one
        ConditionExpression yields one reason code, and ours checks both that
        the account exists and that the balance is sufficient.

        ReturnValuesOnConditionCheckFailure resolves it without a second read.
        The old item comes back only if there was one, so `Item` present means
        the account exists and the balance was too low, and `Item` absent means
        the account is gone. Verified against DynamoDB Local; see §F3.
        """
        if error.response.get("Error", {}).get("Code") != "TransactionCanceledException":
            return self._unavailable(error)

        reasons = error.response.get("CancellationReasons", [])
        codes = [reason.get("Code") for reason in reasons]

        # Index 0 is tested first so that a replayed key against a deleted
        # account reports the duplicate. The in-memory fake also checks for a
        # duplicate before it looks at the account, so the two agree.
        if len(codes) > 0 and codes[0] == "ConditionalCheckFailed":
            return DuplicateTransactionError(
                "that idempotency key was already used on this account",
                account_id=transaction.account_id,
                idempotency_key=transaction.idempotency_key,
            )

        if len(codes) > 1 and codes[1] == "ConditionalCheckFailed":
            item = reasons[1].get("Item")
            if item is None:
                return AccountNotFoundError("no such account", account_id=transaction.account_id)
            # The balance the condition actually rejected — not whatever a
            # follow-up read would have found after a concurrent write.
            return InsufficientFundsError(
                "the account balance is too low for this debit",
                account_id=transaction.account_id,
                balance_minor=int(_from_item(item)["balance_minor"]),
                requested_minor=transaction.amount.amount_minor,
            )

        return self._unavailable(error)

    def get_transaction(self, account_id: str, transaction_id: str) -> Transaction | None:
        try:
            response = self._client.get_item(
                TableName=self._transactions,
                Key=_to_item({"account_id": account_id, "transaction_id": transaction_id}),
            )
        except (ClientError, BotoCoreError) as error:
            raise self._unavailable(error) from error
        item = response.get("Item")
        return _transaction_from_item(item) if item else None

    def list_transactions(
        self, account_id: str, limit: int = 50, cursor: str | None = None
    ) -> Page[Transaction]:
        query = {
            "TableName": self._transactions,
            "IndexName": TRANSACTIONS_BY_CREATED_AT_INDEX,
            "KeyConditionExpression": "account_id = :account_id",
            "ExpressionAttributeValues": _to_item({":account_id": account_id}),
            "ScanIndexForward": False,  # newest first
            "Limit": limit,
        }
        if cursor is not None:
            query["ExclusiveStartKey"] = _decode_cursor(cursor)

        try:
            response = self._client.query(**query)
        except (ClientError, BotoCoreError) as error:
            raise self._unavailable(error) from error

        last_key = response.get("LastEvaluatedKey")
        return Page(
            items=[_transaction_from_item(item) for item in response.get("Items", [])],
            next_cursor=_encode_cursor(last_key) if last_key else None,
        )

    # --- health ---

    def ping(self) -> None:
        """A data-plane read against a key that does not exist.

        Cheaper and far less throttle-prone than DescribeTable, which is a
        control-plane call — and /ready is polled.
        """
        try:
            self._client.get_item(
                TableName=self._accounts, Key=_to_item({"account_id": "__ping__"})
            )
        except (ClientError, BotoCoreError) as error:
            raise self._unavailable(error) from error

    @staticmethod
    def _unavailable(error: Exception) -> RepositoryUnavailableError:
        logger.warning("dynamodb call failed", extra={"error": str(error)})
        return RepositoryUnavailableError("the data store is unavailable")
```

- [ ] **Step 5: Add the DynamoDB implementation to the contract fixture**

Replace the whole of `app/tests/contract/conftest.py`:

```python
"""One repository fixture, parametrised over every implementation.

Both backends run the identical suite in test_ledger_repository.py. That is
what keeps the fake honest: a behaviour the fake gets wrong is a red test, not
a production surprise.

The DynamoDB backend runs against DynamoDB Local — AWS's own implementation —
rather than a Python reimplementation of it. See §0 of the Phase 1 plan.
"""

import os
import uuid

import boto3
import pytest
from botocore.exceptions import EndpointConnectionError

from bgd.repository.dynamodb import DynamoDbLedgerRepository
from bgd.repository.memory import InMemoryLedgerRepository
from bgd.repository.schema import table_definitions

DEFAULT_ENDPOINT = "http://localhost:8000"


def _client(endpoint: str):
    # Explicit dummy credentials: DynamoDB Local accepts any credentials but
    # rejects none, and passing them here keeps the suite independent of
    # whatever profile the developer happens to have exported.
    return boto3.client(
        "dynamodb",
        region_name="us-east-1",
        endpoint_url=endpoint,
        aws_access_key_id="local",
        aws_secret_access_key="local",
    )


@pytest.fixture(scope="session")
def dynamodb_endpoint() -> str:
    endpoint = os.environ.get("BGD_TEST_DYNAMODB_ENDPOINT", DEFAULT_ENDPOINT)
    try:
        _client(endpoint).list_tables()
    except EndpointConnectionError:
        # fail, not skip. A silently skipped backend test would defeat the
        # entire reason for choosing the higher-fidelity tool — the suite
        # would go green having tested one implementation, not two.
        pytest.fail(
            f"DynamoDB Local is not reachable at {endpoint}. Run `make local-up`.",
            pytrace=False,
        )
    return endpoint


@pytest.fixture
def dynamodb_tables(dynamodb_endpoint: str):
    """A private pair of tables per test.

    Unique names rather than one shared pair that gets emptied between tests:
    no test can observe another's writes, there is no teardown ordering to get
    wrong, and the suite stays correct if it is ever parallelised with xdist.
    """
    client = _client(dynamodb_endpoint)
    suffix = uuid.uuid4().hex[:12]
    accounts = f"bgd-us-east-1-test-{suffix}-accounts"
    transactions = f"bgd-us-east-1-test-{suffix}-transactions"

    for definition in table_definitions(accounts, transactions):
        client.create_table(**definition)

    yield client, accounts, transactions

    for name in (accounts, transactions):
        client.delete_table(TableName=name)


@pytest.fixture(params=["memory", "dynamodb"])
def repository(request: pytest.FixtureRequest):
    if request.param == "memory":
        return InMemoryLedgerRepository()
    # Requested lazily so the memory parametrisation does not pay for table
    # creation it never uses.
    client, accounts, transactions = request.getfixturevalue("dynamodb_tables")
    return DynamoDbLedgerRepository(client, accounts, transactions)
```

- [ ] **Step 6: Run the whole contract suite against both implementations**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/contract --no-cov -q`
Expected: 48 passed — 21 contract tests × 2 implementations, plus the 6 characterisation tests. Any test that passes for `memory` and fails for `dynamodb` is a genuine divergence and must be fixed in `dynamodb.py`, not worked around in the test.

- [ ] **Step 7: Commit**

```bash
git add app/src/bgd/repository/schema.py app/src/bgd/repository/dynamodb.py \
        app/tests/contract/
git commit -m "feat(app): add the DynamoDB repository with atomic balance updates

Posts the transaction record and the balance update in one TransactWriteItems,
so a rejected debit leaves no trace. Runs against the same contract suite as
the in-memory fake."
```

---

## Task 7: The FastAPI application shell — health, version, errors, request context

Everything that is not a business endpoint: the app factory, the RFC 9457 error envelope, the request-id middleware, and the three operational endpoints. `/version` is the one Phase 6 depends on.

**Files:**
- Create: `app/src/bgd/api/__init__.py`, `main.py`, `middleware.py`, `errors.py`, `dependencies.py`, `schemas.py`
- Create: `app/src/bgd/api/routers/__init__.py`, `routers/health.py`
- Test: `app/tests/api/test_health.py`, `app/tests/api/test_errors.py`

**Interfaces:**
- Consumes: everything from Tasks 2–5
- Produces:
  - `bgd.api.main.create_app(repository=None, settings=None) -> FastAPI`
  - `bgd.api.errors.problem_response(status, code, detail, instance, **extra) -> JSONResponse` — the title is derived from the status
  - `bgd.api.errors.install_exception_handlers(app) -> None`
  - `bgd.api.errors.STATUS_BY_CODE: dict[str, int]`
  - `bgd.api.middleware.RequestContextMiddleware`
  - `bgd.api.dependencies.ServiceDep`, `SettingsDep`
  - Endpoints `GET /health`, `GET /ready`, `GET /version`

- [ ] **Step 1: Write the failing tests**

`app/tests/api/test_health.py`:

```python
import pytest
from fastapi.testclient import TestClient

from bgd.api.main import create_app
from bgd.config import Settings
from bgd.domain.errors import RepositoryUnavailableError
from bgd.repository.memory import InMemoryLedgerRepository


@pytest.fixture
def client() -> TestClient:
    settings = Settings(
        _env_file=None,
        app_version="1.2.345",
        git_sha="deadbee",
        image_digest="sha256:abc123",
        built_at="2026-08-05T10:00:00Z",
    )
    return TestClient(create_app(repository=InMemoryLedgerRepository(), settings=settings))


def test_health_is_liveness_only(client) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_health_never_touches_the_repository() -> None:
    """The ALB target-group health check calls this. If it consulted DynamoDB,
    a dependency hiccup would deregister healthy tasks and take the service
    down — so a repository that raises on every call must not affect it."""

    class ExplodingRepository(InMemoryLedgerRepository):
        def ping(self) -> None:
            raise AssertionError("/health must never call ping()")

    client = TestClient(create_app(repository=ExplodingRepository()))
    assert client.get("/health").status_code == 200


def test_ready_reports_the_dependency_as_ok(client) -> None:
    response = client.get("/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ready", "checks": {"dynamodb": "ok"}}


def test_ready_returns_503_when_the_store_is_unreachable() -> None:
    class UnreachableRepository(InMemoryLedgerRepository):
        def ping(self) -> None:
            raise RepositoryUnavailableError("nope")

    client = TestClient(create_app(repository=UnreachableRepository()))
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.json()["checks"]["dynamodb"] == "unavailable"


def test_version_reports_the_injected_build_metadata(client) -> None:
    """Phase 6 curls this against :443 and :8443 during a blue/green shift.
    Two different git_sha values is the direct proof of which colour serves
    whom, so these four fields are a contract with Phase 6, not decoration."""
    body = client.get("/version").json()
    assert body == {
        "version": "1.2.345",
        "git_sha": "deadbee",
        "image_digest": "sha256:abc123",
        "built_at": "2026-08-05T10:00:00Z",
    }


def test_every_response_carries_a_request_id_header(client) -> None:
    assert len(client.get("/health").headers["x-request-id"]) == 32


def test_a_supplied_request_id_is_echoed(client) -> None:
    response = client.get("/health", headers={"X-Request-ID": "req-abc"})
    assert response.headers["x-request-id"] == "req-abc"
```

`app/tests/api/test_errors.py`:

```python
"""The error envelope, tested independently of the business endpoints.

The app under test registers its own throwaway probe routes rather than calling
/api/accounts. Error representation is a property of the API shell, and tying
these assertions to business routes would make them fail for reasons that have
nothing to do with the envelope — and would make this task depend on the next
one.
"""

import pytest
from fastapi.testclient import TestClient
from pydantic import BaseModel, Field

from bgd.api.errors import STATUS_BY_CODE
from bgd.api.main import create_app
from bgd.domain.errors import AccountNotFoundError, DomainError, RepositoryUnavailableError
from bgd.repository.memory import InMemoryLedgerRepository


class Payload(BaseModel):
    amount_minor: int = Field(gt=0)


@pytest.fixture
def client() -> TestClient:
    app = create_app(repository=InMemoryLedgerRepository())

    @app.get("/probe/domain-error")
    def _domain_error() -> None:
        raise AccountNotFoundError("no such account", account_id="acc_missing")

    @app.get("/probe/unavailable")
    def _unavailable() -> None:
        raise RepositoryUnavailableError("the data store is unavailable")

    @app.post("/probe/validated")
    def _validated(payload: Payload) -> dict:
        return {"amount_minor": payload.amount_minor}

    @app.get("/probe/boom")
    def _boom() -> None:
        raise RuntimeError("secret internal detail")

    return TestClient(app, raise_server_exceptions=False)


def test_a_domain_error_becomes_an_rfc_9457_problem(client) -> None:
    response = client.get("/probe/domain-error")
    assert response.status_code == 404
    assert response.headers["content-type"].startswith("application/problem+json")

    body = response.json()
    assert body["code"] == "ACCOUNT_NOT_FOUND"
    assert body["status"] == 404
    assert body["title"] == "Not Found"
    assert body["type"].endswith("/account-not-found")
    assert body["instance"] == "/probe/domain-error"
    assert body["request_id"]


def test_domain_error_details_are_merged_into_the_problem(client) -> None:
    assert client.get("/probe/domain-error").json()["account_id"] == "acc_missing"


def test_an_unavailable_repository_becomes_503(client) -> None:
    response = client.get("/probe/unavailable")
    assert response.status_code == 503
    assert response.json()["code"] == "REPOSITORY_UNAVAILABLE"


def test_a_validation_failure_becomes_a_422_problem_with_field_errors(client) -> None:
    response = client.post("/probe/validated", json={"amount_minor": -1})
    assert response.status_code == 422
    assert response.headers["content-type"].startswith("application/problem+json")

    body = response.json()
    assert body["code"] == "VALIDATION_FAILED"
    assert body["errors"][0]["field"] == "amount_minor"


def test_an_unknown_route_becomes_a_problem_document(client) -> None:
    response = client.get("/nope")
    assert response.status_code == 404
    assert response.headers["content-type"].startswith("application/problem+json")
    assert response.json()["code"] == "NOT_FOUND"


def test_an_unhandled_exception_becomes_a_500_that_leaks_nothing(client) -> None:
    """A stack trace or an internal message in the response body is an
    information-disclosure bug. request_id is the link to the log line that
    does carry the detail."""
    response = client.get("/probe/boom")
    assert response.status_code == 500
    assert response.json()["code"] == "INTERNAL_ERROR"
    assert "secret internal detail" not in response.text
    assert response.json()["request_id"]


def test_every_domain_error_code_has_a_status(client) -> None:
    """A new DomainError subclass with no entry in STATUS_BY_CODE would
    silently become a 500. Walking the subclasses is what keeps the map
    honest as the domain grows."""

    def subclasses(cls: type) -> set[type]:
        direct = set(cls.__subclasses__())
        return direct.union(*(subclasses(child) for child in direct)) if direct else direct

    missing = {cls.code for cls in subclasses(DomainError)} - set(STATUS_BY_CODE)
    assert not missing, f"DomainError subclasses with no status mapping: {sorted(missing)}"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/api --no-cov -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'bgd.api'`

- [ ] **Step 3: Write `app/src/bgd/api/middleware.py`**

```python
"""Request context and access logging.

Written as raw ASGI rather than a BaseHTTPMiddleware subclass. BaseHTTPMiddleware
runs the downstream application in a separate anyio task, which makes
ContextVar propagation subtle in exactly the direction this needs. Raw ASGI
shares the context directly, and is about the same amount of code.
"""

import logging
import time
import uuid
from collections.abc import Callable

from starlette.datastructures import Headers

from bgd.logging import request_id_var

logger = logging.getLogger("bgd.access")


class RequestContextMiddleware:
    def __init__(self, app: Callable) -> None:
        self.app = app

    async def __call__(self, scope: dict, receive: Callable, send: Callable) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        request_id = Headers(scope=scope).get("x-request-id") or uuid.uuid4().hex
        token = request_id_var.set(request_id)
        started = time.perf_counter()
        status = 500

        async def send_wrapper(message: dict) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
                message["headers"] = [
                    *message["headers"],
                    (b"x-request-id", request_id.encode()),
                ]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            logger.info(
                "request",
                extra={
                    "method": scope["method"],
                    "path": scope["path"],
                    "status": status,
                    "duration_ms": round((time.perf_counter() - started) * 1000, 2),
                },
            )
            request_id_var.reset(token)
```

- [ ] **Step 4: Write `app/src/bgd/api/errors.py`**

```python
"""HTTP error representation — RFC 9457 problem details.

This module is the only place that knows how a domain error maps to a status
code. The domain stays transport-agnostic, and adding an error there without
adding it here is caught by test_every_domain_code_has_a_status.
"""

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from bgd.domain.errors import DomainError
from bgd.logging import request_id_var

logger = logging.getLogger(__name__)

PROBLEM_TYPE_BASE = "https://carloscloudengineer.com/problems/"

STATUS_BY_CODE: dict[str, int] = {
    "ACCOUNT_NOT_FOUND": 404,
    "ACCOUNT_ALREADY_EXISTS": 409,
    "DUPLICATE_TRANSACTION": 409,
    "INSUFFICIENT_FUNDS": 409,
    "CURRENCY_MISMATCH": 422,
    "INVARIANT_VIOLATION": 422,
    "REPOSITORY_UNAVAILABLE": 503,
    "DOMAIN_ERROR": 500,
}

_TITLES = {
    400: "Bad Request",
    404: "Not Found",
    409: "Conflict",
    422: "Unprocessable Content",
    500: "Internal Server Error",
    503: "Service Unavailable",
}


def problem_response(
    status: int, code: str, detail: str, instance: str, **extra: object
) -> JSONResponse:
    body: dict[str, object] = {
        "type": PROBLEM_TYPE_BASE + code.lower().replace("_", "-"),
        "title": _TITLES.get(status, "Error"),
        "status": status,
        "detail": detail,
        "instance": instance,
        "code": code,
        "request_id": request_id_var.get(),
    }
    body.update(extra)
    return JSONResponse(status_code=status, content=body, media_type="application/problem+json")


def install_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(DomainError)
    async def _domain(request: Request, exc: DomainError) -> JSONResponse:
        status = STATUS_BY_CODE.get(exc.code, 500)
        if status >= 500:
            logger.error("domain error", extra={"code": exc.code, "detail": exc.message})
        return problem_response(status, exc.code, exc.message, request.url.path, **exc.details)

    @app.exception_handler(RequestValidationError)
    async def _validation(request: Request, exc: RequestValidationError) -> JSONResponse:
        return problem_response(
            422,
            "VALIDATION_FAILED",
            "the request body or parameters failed validation",
            request.url.path,
            errors=[
                {
                    # loc[0] is the source ("body", "query"); the rest is the path.
                    "field": ".".join(str(part) for part in error["loc"][1:]),
                    "message": error["msg"],
                }
                for error in exc.errors()
            ],
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = "NOT_FOUND" if exc.status_code == 404 else "HTTP_ERROR"
        return problem_response(exc.status_code, code, str(exc.detail), request.url.path)

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
        # The detail goes to the log, never to the client. request_id is the
        # link between the two.
        logger.exception("unhandled exception", extra={"path": request.url.path})
        return problem_response(
            500, "INTERNAL_ERROR", "an unexpected error occurred", request.url.path
        )
```

- [ ] **Step 5: Write `app/src/bgd/api/schemas.py`**

```python
"""The HTTP boundary types.

Pydantic here, frozen dataclasses in the domain. Keeping them separate means
a rename in the wire format cannot silently change a domain invariant, and the
API can present `amount_minor` as a plain int while the domain insists on Money.
"""

from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

Currency = Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]
OwnerName = Annotated[str, StringConstraints(min_length=1, max_length=120, strip_whitespace=True)]
IdempotencyKey = Annotated[str, StringConstraints(min_length=1, max_length=128)]


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"


class ReadyResponse(BaseModel):
    status: Literal["ready", "not_ready"]
    checks: dict[str, str]


class VersionResponse(BaseModel):
    version: str
    git_sha: str
    image_digest: str
    built_at: str


class AccountCreateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    owner_name: OwnerName
    currency: Currency
    initial_balance_minor: int = Field(default=0, ge=0)


class AccountResponse(BaseModel):
    account_id: str
    owner_name: str
    currency: str
    balance_minor: int
    created_at: datetime


class AccountListResponse(BaseModel):
    items: list[AccountResponse]


class TransactionCreateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    account_id: str
    type: Literal["CREDIT", "DEBIT"]
    amount_minor: int = Field(gt=0)
    currency: Currency
    idempotency_key: IdempotencyKey
    description: str | None = Field(default=None, max_length=280)


class TransactionResponse(BaseModel):
    transaction_id: str
    account_id: str
    type: str
    amount_minor: int
    currency: str
    idempotency_key: str
    description: str | None
    created_at: datetime


class TransactionListResponse(BaseModel):
    items: list[TransactionResponse]
    next_cursor: str | None = None
```

- [ ] **Step 6: Write `app/src/bgd/api/dependencies.py`**

```python
"""Dependency wiring.

The repository lives on app.state, put there by create_app. That is what lets
every API test pass in the in-memory fake and never import boto3.
"""

from typing import Annotated

from fastapi import Depends, Request

from bgd.config import Settings
from bgd.domain.services import LedgerService
from bgd.repository.base import LedgerRepository


def get_repository(request: Request) -> LedgerRepository:
    return request.app.state.repository


def get_settings_dep(request: Request) -> Settings:
    return request.app.state.settings


def get_service(
    repository: Annotated[LedgerRepository, Depends(get_repository)],
) -> LedgerService:
    return LedgerService(repository)


RepositoryDep = Annotated[LedgerRepository, Depends(get_repository)]
SettingsDep = Annotated[Settings, Depends(get_settings_dep)]
ServiceDep = Annotated[LedgerService, Depends(get_service)]
```

- [ ] **Step 7: Write `app/src/bgd/api/routers/health.py`**

```python
"""Operational endpoints.

/health and /ready are deliberately different. /health is what the ALB target
group polls: it must report only whether this process is alive, because a
dependency check there would let a DynamoDB hiccup deregister every healthy
task at once. /ready is for humans and for deployment gates, and does check.
"""

from fastapi import APIRouter, Response

from bgd.api.dependencies import RepositoryDep, SettingsDep
from bgd.api.schemas import HealthResponse, ReadyResponse, VersionResponse
from bgd.domain.errors import DomainError

router = APIRouter(tags=["operations"])


@router.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse()


@router.get("/ready", response_model=ReadyResponse)
def ready(repository: RepositoryDep, response: Response) -> ReadyResponse:
    try:
        repository.ping()
    except DomainError:
        response.status_code = 503
        return ReadyResponse(status="not_ready", checks={"dynamodb": "unavailable"})
    return ReadyResponse(status="ready", checks={"dynamodb": "ok"})


@router.get("/version", response_model=VersionResponse)
def version(settings: SettingsDep) -> VersionResponse:
    """Build identity of the running task.

    Phase 6 curls this against the :443 production listener and the :8443 test
    listener during a blue/green shift; two different git_sha values are the
    direct proof of which colour is serving whom.
    """
    return VersionResponse(
        version=settings.app_version,
        git_sha=settings.git_sha,
        image_digest=settings.image_digest,
        built_at=settings.built_at,
    )
```

- [ ] **Step 8: Write `app/src/bgd/api/main.py`**

```python
"""The application factory.

create_app takes its repository as an argument so tests inject the in-memory
fake and never construct a boto3 client. Production passes nothing and gets the
DynamoDB implementation built from settings.
"""

from fastapi import FastAPI

from bgd.api.errors import install_exception_handlers
from bgd.api.middleware import RequestContextMiddleware
from bgd.api.routers import accounts, health, transactions
from bgd.config import Settings, get_settings
from bgd.logging import configure_logging
from bgd.repository.base import LedgerRepository


def create_app(
    repository: LedgerRepository | None = None,
    settings: Settings | None = None,
) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.log_level)

    if repository is None:
        from bgd.repository.dynamodb import DynamoDbLedgerRepository, build_client

        repository = DynamoDbLedgerRepository(
            build_client(settings),
            settings.accounts_table,
            settings.transactions_table,
        )

    app = FastAPI(
        title="Blue/Green Deployment Platform API",
        version=settings.app_version,
        # The default handler would return a plain JSON body; ours returns
        # application/problem+json for every error including unhandled ones.
        docs_url="/docs",
    )
    app.state.settings = settings
    app.state.repository = repository

    app.add_middleware(RequestContextMiddleware)
    install_exception_handlers(app)

    app.include_router(health.router)
    app.include_router(accounts.router)
    app.include_router(transactions.router)
    return app
```

> **Note for the implementer:** `main.py` imports `accounts` and `transactions`, which Task 8 fills in. Create both router modules now as bare stubs so this task stands on its own:
>
> ```python
> # app/src/bgd/api/routers/accounts.py — and transactions.py, identically
> from fastapi import APIRouter
>
> router = APIRouter()
> ```
>
> No prefix and no routes: Task 8 replaces both files wholesale. This task's tests use their own probe routes and never call `/api/...`, so nothing here is left failing for the next task to fix.

- [ ] **Step 9: Run the tests to verify they pass**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/api --no-cov -q`
Expected: 14 passed — 7 in `test_health.py`, 7 in `test_errors.py`.

- [ ] **Step 10: Commit**

```bash
git add app/src/bgd/api/ app/tests/api/test_health.py app/tests/api/test_errors.py
git commit -m "feat(app): add the API shell, RFC 9457 errors and request context"
```

---

## Task 8: The accounts and transactions endpoints

The business surface. All five endpoints the design's §4 table promises.

**Files:**
- Create (replacing the Task 7 stubs): `app/src/bgd/api/routers/accounts.py`, `app/src/bgd/api/routers/transactions.py`
- Test: `app/tests/api/test_accounts.py`, `app/tests/api/test_transactions.py`

**Interfaces:**
- Consumes: `bgd.api.dependencies.ServiceDep`, `bgd.api.schemas.*`, `bgd.domain.models.TransactionType`
- Produces:
  - `GET /api/accounts`, `POST /api/accounts`, `GET /api/accounts/{account_id}`
  - `POST /api/transactions`, `GET /api/transactions`

- [ ] **Step 1: Write the failing tests**

`app/tests/api/test_accounts.py`:

```python
import pytest
from fastapi.testclient import TestClient

from bgd.api.main import create_app
from bgd.repository.memory import InMemoryLedgerRepository


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_app(repository=InMemoryLedgerRepository()))


def open_account(client: TestClient, **overrides) -> dict:
    payload = {"owner_name": "Ada Lovelace", "currency": "EUR", "initial_balance_minor": 10_000}
    payload.update(overrides)
    return client.post("/api/accounts", json=payload).json()


def test_creating_an_account_returns_201_and_the_resource(client) -> None:
    response = client.post(
        "/api/accounts",
        json={"owner_name": "Ada Lovelace", "currency": "EUR", "initial_balance_minor": 10_000},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["account_id"].startswith("acc_")
    assert body["owner_name"] == "Ada Lovelace"
    assert body["currency"] == "EUR"
    assert body["balance_minor"] == 10_000
    assert response.headers["location"] == f"/api/accounts/{body['account_id']}"


def test_the_opening_balance_defaults_to_zero(client) -> None:
    response = client.post("/api/accounts", json={"owner_name": "Ada", "currency": "EUR"})
    assert response.json()["balance_minor"] == 0


def test_an_account_can_be_fetched_by_id(client) -> None:
    created = open_account(client)
    response = client.get(f"/api/accounts/{created['account_id']}")
    assert response.status_code == 200
    assert response.json() == created


def test_fetching_an_unknown_account_is_404(client) -> None:
    assert client.get("/api/accounts/acc_missing").status_code == 404


def test_accounts_can_be_listed(client) -> None:
    open_account(client, owner_name="Ada")
    open_account(client, owner_name="Grace")
    body = client.get("/api/accounts").json()
    assert {item["owner_name"] for item in body["items"]} == {"Ada", "Grace"}


def test_the_list_limit_is_validated(client) -> None:
    assert client.get("/api/accounts?limit=0").status_code == 422
    assert client.get("/api/accounts?limit=1000").status_code == 422


@pytest.mark.parametrize(
    "payload",
    [
        {"owner_name": "", "currency": "EUR"},
        {"owner_name": "Ada", "currency": "eur"},
        {"owner_name": "Ada", "currency": "EURO"},
        {"owner_name": "Ada", "currency": "EUR", "initial_balance_minor": -1},
        {"currency": "EUR"},
        {"owner_name": "Ada", "currency": "EUR", "unexpected": "field"},
    ],
)
def test_invalid_payloads_are_rejected_with_422(client, payload) -> None:
    assert client.post("/api/accounts", json=payload).status_code == 422
```

`app/tests/api/test_transactions.py`:

```python
import pytest
from fastapi.testclient import TestClient

from bgd.api.main import create_app
from bgd.repository.memory import InMemoryLedgerRepository


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_app(repository=InMemoryLedgerRepository()))


@pytest.fixture
def account_id(client: TestClient) -> str:
    response = client.post(
        "/api/accounts",
        json={"owner_name": "Ada", "currency": "EUR", "initial_balance_minor": 10_000},
    )
    return response.json()["account_id"]


def post_transaction(client: TestClient, account_id: str, **overrides):
    payload = {
        "account_id": account_id,
        "type": "DEBIT",
        "amount_minor": 2_500,
        "currency": "EUR",
        "idempotency_key": "key-1",
        "description": "rent",
    }
    payload.update(overrides)
    return client.post("/api/transactions", json=payload)


def balance(client: TestClient, account_id: str) -> int:
    return client.get(f"/api/accounts/{account_id}").json()["balance_minor"]


def test_a_debit_returns_201_and_moves_the_balance(client, account_id) -> None:
    response = post_transaction(client, account_id)
    assert response.status_code == 201
    body = response.json()
    assert body["transaction_id"].startswith("txn_")
    assert body["type"] == "DEBIT"
    assert body["amount_minor"] == 2_500
    assert balance(client, account_id) == 7_500


def test_a_credit_moves_the_balance_the_other_way(client, account_id) -> None:
    post_transaction(client, account_id, type="CREDIT", amount_minor=1_500)
    assert balance(client, account_id) == 11_500


def test_replaying_the_idempotency_key_returns_200_not_201(client, account_id) -> None:
    """A retry must be safe. 201 says 'created', 200 says 'you already did
    this' — and the balance must have moved exactly once either way."""
    first = post_transaction(client, account_id)
    second = post_transaction(client, account_id)

    assert first.status_code == 201
    assert second.status_code == 200
    assert second.json()["transaction_id"] == first.json()["transaction_id"]
    assert balance(client, account_id) == 7_500


def test_an_overdraft_is_409_with_the_balance_in_the_problem(client, account_id) -> None:
    response = post_transaction(client, account_id, amount_minor=50_000)
    assert response.status_code == 409
    body = response.json()
    assert body["code"] == "INSUFFICIENT_FUNDS"
    assert body["balance_minor"] == 10_000
    assert body["requested_minor"] == 50_000
    assert balance(client, account_id) == 10_000


def test_a_currency_mismatch_is_422(client, account_id) -> None:
    response = post_transaction(client, account_id, currency="USD")
    assert response.status_code == 422
    assert response.json()["code"] == "CURRENCY_MISMATCH"


def test_posting_to_an_unknown_account_is_404(client) -> None:
    response = post_transaction(client, "acc_missing")
    assert response.status_code == 404
    assert response.json()["code"] == "ACCOUNT_NOT_FOUND"


@pytest.mark.parametrize(
    "overrides",
    [
        {"amount_minor": 0},
        {"amount_minor": -100},
        {"type": "TRANSFER"},
        {"currency": "eur"},
        {"idempotency_key": ""},
    ],
)
def test_invalid_transaction_payloads_are_422(client, account_id, overrides) -> None:
    assert post_transaction(client, account_id, **overrides).status_code == 422


def test_transactions_are_listed_newest_first(client, account_id) -> None:
    for index in range(3):
        post_transaction(client, account_id, amount_minor=100 + index, idempotency_key=f"k{index}")

    items = client.get(f"/api/transactions?account_id={account_id}").json()["items"]
    assert [item["amount_minor"] for item in items] == [102, 101, 100]


def test_listing_transactions_paginates(client, account_id) -> None:
    for index in range(5):
        post_transaction(client, account_id, amount_minor=100 + index, idempotency_key=f"k{index}")

    first = client.get(f"/api/transactions?account_id={account_id}&limit=2").json()
    assert len(first["items"]) == 2
    assert first["next_cursor"]

    second = client.get(
        f"/api/transactions?account_id={account_id}&limit=2&cursor={first['next_cursor']}"
    ).json()
    assert [item["amount_minor"] for item in second["items"]] == [102, 101]


def test_listing_transactions_for_an_unknown_account_is_404(client) -> None:
    assert client.get("/api/transactions?account_id=acc_missing").status_code == 404


def test_account_id_is_required_when_listing(client) -> None:
    assert client.get("/api/transactions").status_code == 422
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/api/test_accounts.py tests/api/test_transactions.py --no-cov -q`
Expected: FAIL — 404 on every route, because the routers are still empty stubs.

- [ ] **Step 3: Write `app/src/bgd/api/routers/accounts.py`**

```python
from fastapi import APIRouter, Query, Response, status

from bgd.api.dependencies import ServiceDep
from bgd.api.schemas import AccountCreateRequest, AccountListResponse, AccountResponse
from bgd.domain.models import Account

router = APIRouter(prefix="/api/accounts", tags=["accounts"])


def to_response(account: Account) -> AccountResponse:
    return AccountResponse(
        account_id=account.account_id,
        owner_name=account.owner_name,
        currency=account.balance.currency,
        balance_minor=account.balance.amount_minor,
        created_at=account.created_at,
    )


@router.post("", response_model=AccountResponse, status_code=status.HTTP_201_CREATED)
def create_account(
    payload: AccountCreateRequest, service: ServiceDep, response: Response
) -> AccountResponse:
    account = service.open_account(
        owner_name=payload.owner_name,
        currency=payload.currency,
        initial_balance_minor=payload.initial_balance_minor,
    )
    response.headers["Location"] = f"/api/accounts/{account.account_id}"
    return to_response(account)


@router.get("", response_model=AccountListResponse)
def list_accounts(
    service: ServiceDep, limit: int = Query(default=50, ge=1, le=100)
) -> AccountListResponse:
    return AccountListResponse(items=[to_response(a) for a in service.list_accounts(limit=limit)])


@router.get("/{account_id}", response_model=AccountResponse)
def get_account(account_id: str, service: ServiceDep) -> AccountResponse:
    return to_response(service.get_account(account_id))
```

- [ ] **Step 4: Write `app/src/bgd/api/routers/transactions.py`**

```python
from fastapi import APIRouter, Query, Response, status

from bgd.api.dependencies import ServiceDep
from bgd.api.schemas import (
    TransactionCreateRequest,
    TransactionListResponse,
    TransactionResponse,
)
from bgd.domain.models import Transaction, TransactionType

router = APIRouter(prefix="/api/transactions", tags=["transactions"])


def to_response(transaction: Transaction) -> TransactionResponse:
    return TransactionResponse(
        transaction_id=transaction.transaction_id,
        account_id=transaction.account_id,
        type=str(transaction.type),
        amount_minor=transaction.amount.amount_minor,
        currency=transaction.amount.currency,
        idempotency_key=transaction.idempotency_key,
        description=transaction.description,
        created_at=transaction.created_at,
    )


@router.post("", response_model=TransactionResponse, status_code=status.HTTP_201_CREATED)
def post_transaction(
    payload: TransactionCreateRequest, service: ServiceDep, response: Response
) -> TransactionResponse:
    transaction, _account, created = service.post_transaction(
        account_id=payload.account_id,
        transaction_type=TransactionType(payload.type),
        amount_minor=payload.amount_minor,
        currency=payload.currency,
        idempotency_key=payload.idempotency_key,
        description=payload.description,
    )
    if not created:
        # An idempotent replay. 200 rather than 201, because nothing was
        # created this time — the client's retry was safe and is being told so.
        response.status_code = status.HTTP_200_OK
    else:
        response.headers["Location"] = f"/api/transactions/{transaction.transaction_id}"
    return to_response(transaction)


@router.get("", response_model=TransactionListResponse)
def list_transactions(
    service: ServiceDep,
    account_id: str = Query(...),
    limit: int = Query(default=50, ge=1, le=100),
    cursor: str | None = Query(default=None),
) -> TransactionListResponse:
    page = service.list_transactions(account_id, limit=limit, cursor=cursor)
    return TransactionListResponse(
        items=[to_response(t) for t in page.items], next_cursor=page.next_cursor
    )
```

- [ ] **Step 5: Run the full suite with the coverage gate**

Run: `make test`
Expected: all tests pass and coverage is ≥ 90%. If coverage falls short, the gap is a real one — add the missing test rather than lowering `fail_under`.

- [ ] **Step 6: Run lint**

Run: `make lint`
Expected: `All checks passed!` and no formatting diff. Run `make format` first if it reports one.

- [ ] **Step 7: Commit**

```bash
git add app/src/bgd/api/routers/ app/tests/api/
git commit -m "feat(app): add the accounts and transactions endpoints"
```

---

## Task 9: Local development and end-to-end verification

The roadmap's exit criterion: "the service runs against DynamoDB Local and every endpoint returns correct responses."

Task 6 already covers the repository layer against DynamoDB Local, so what this task adds is the **end-to-end** path — real HTTP, through the routers, the service and the repository, into the same engine — plus the ergonomics for running it by hand.

**Files:**
- Create: `app/.env.example`
- Create: `app/src/bgd/cli/__init__.py`, `app/src/bgd/cli/create_tables.py`
- Create: `docs/phases/phase1/2026-08-05-local-verification.md`
- Modify: `makefile` (`local-tables`, `run-local`), `app/README.md`

**Interfaces:**
- Consumes: `bgd.repository.schema.table_definitions`, `bgd.repository.dynamodb.build_client`, `bgd.config.get_settings`; `make local-up` / `local-down` from Task 1
- Produces: `python -m bgd.cli.create_tables`; `make local-tables`, `make run-local`

- [ ] **Step 1: Write `app/.env.example`**

```bash
# Copy to app/.env for local development. .env is gitignored; this file is not.
#
# No AWS credentials are needed: when BGD_DYNAMODB_ENDPOINT_URL is set, the
# repository supplies dummy credentials itself, because DynamoDB Local accepts
# any credentials but rejects none.

BGD_ENVIRONMENT=local
BGD_LOG_LEVEL=INFO

BGD_AWS_REGION=us-east-1
BGD_DYNAMODB_ENDPOINT_URL=http://localhost:8000

BGD_ACCOUNTS_TABLE=bgd-us-east-1-local-accounts
BGD_TRANSACTIONS_TABLE=bgd-us-east-1-local-transactions

# Build metadata. Phase 2 injects the real values at image build time.
BGD_APP_VERSION=0.0.0-dev
BGD_GIT_SHA=local
BGD_IMAGE_DIGEST=none
BGD_BUILT_AT=1970-01-01T00:00:00Z
```

- [ ] **Step 2: Write `app/src/bgd/cli/create_tables.py`**

```python
"""Create the local DynamoDB tables.

Idempotent — an existing table is left alone — and it reads its definitions
from bgd.repository.schema, the same module the tests use, so local
development and CI cannot drift apart.

Refuses to run without BGD_DYNAMODB_ENDPOINT_URL. Without that guard a stray
AWS_PROFILE would point this at a real account and silently create tables there.
"""

import time

from botocore.exceptions import EndpointConnectionError

from bgd.config import get_settings
from bgd.repository.dynamodb import build_client
from bgd.repository.schema import table_definitions


def _wait_for_endpoint(client, attempts: int = 30, delay: float = 1.0) -> None:
    for attempt in range(1, attempts + 1):
        try:
            client.list_tables()
            return
        except EndpointConnectionError:
            if attempt == attempts:
                raise
            print(f"waiting for DynamoDB Local ({attempt}/{attempts})")
            time.sleep(delay)


def main() -> None:
    settings = get_settings()
    if not settings.dynamodb_endpoint_url:
        raise SystemExit(
            "BGD_DYNAMODB_ENDPOINT_URL is not set. Refusing to create tables "
            "against real AWS — copy app/.env.example to app/.env first."
        )

    client = build_client(settings)
    _wait_for_endpoint(client)

    for definition in table_definitions(settings.accounts_table, settings.transactions_table):
        name = definition["TableName"]
        try:
            client.create_table(**definition)
            print(f"created  {name}")
        except client.exceptions.ResourceInUseException:
            print(f"exists   {name}")

    for name in (settings.accounts_table, settings.transactions_table):
        client.get_waiter("table_exists").wait(TableName=name)

    print("tables ready")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Add the local make targets**

Append to the Phase 1 block in `makefile`:

`local-up` and `local-down` already exist from Task 1. This adds the two that need application code:

```make
.PHONY: local-tables
local-tables: deps local-up ## Create the local DynamoDB tables (idempotent)
	@cd $(APP_DIR) && $(PY) -m bgd.cli.create_tables

.PHONY: run-local
run-local: local-tables ## Run the API against DynamoDB Local
	@cd $(APP_DIR) && $(PY) -m uvicorn bgd.api.main:create_app --factory --reload --port 8080
```

Delete the now-implemented line from the `# PLANNED:` block:

```
# PLANNED: run-local      docker compose up with DynamoDB Local (Phase 1)
```

- [ ] **Step 4: Run the service against DynamoDB Local**

```bash
cp app/.env.example app/.env
make run-local
```

Expected: DynamoDB Local starts, `created bgd-us-east-1-local-accounts` and `created bgd-us-east-1-local-transactions`, then uvicorn listening on `:8080` and emitting one JSON object per request.

- [ ] **Step 5: Exercise every endpoint end to end**

In a second terminal, with `make run-local` still running in the first. Task 6 proved the repository against this engine; this proves the whole stack above it, which no unit or contract test covers.

```bash
curl -s localhost:8080/health
curl -s localhost:8080/ready
curl -s localhost:8080/version

ACC=$(curl -s -X POST localhost:8080/api/accounts \
  -H 'content-type: application/json' \
  -d '{"owner_name":"Ada Lovelace","currency":"EUR","initial_balance_minor":10000}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["account_id"])')
echo "account: $ACC"

curl -s localhost:8080/api/accounts
curl -s "localhost:8080/api/accounts/$ACC"

# a debit, then the same request again — 201 then 200, balance moves once
curl -s -i -X POST localhost:8080/api/transactions \
  -H 'content-type: application/json' \
  -d "{\"account_id\":\"$ACC\",\"type\":\"DEBIT\",\"amount_minor\":2500,\"currency\":\"EUR\",\"idempotency_key\":\"key-1\"}" \
  | head -1
curl -s -i -X POST localhost:8080/api/transactions \
  -H 'content-type: application/json' \
  -d "{\"account_id\":\"$ACC\",\"type\":\"DEBIT\",\"amount_minor\":2500,\"currency\":\"EUR\",\"idempotency_key\":\"key-1\"}" \
  | head -1

# the overdraft path, end to end: HTTP -> service -> ConditionExpression
curl -s -X POST localhost:8080/api/transactions \
  -H 'content-type: application/json' \
  -d "{\"account_id\":\"$ACC\",\"type\":\"DEBIT\",\"amount_minor\":999999,\"currency\":\"EUR\",\"idempotency_key\":\"key-2\"}"

curl -s "localhost:8080/api/accounts/$ACC"
curl -s "localhost:8080/api/transactions?account_id=$ACC"

# /ready must fail when the dependency is gone
make local-down
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/ready   # expect 503
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/health  # expect 200
```

Expected: `201` then `200` on the two identical posts; balance `7500` after both; the overdraft returns a `409` problem document with `"code":"INSUFFICIENT_FUNDS"` and `"balance_minor":7500`; the balance is still `7500` afterwards; the transaction list shows exactly one item. After `make local-down`, `/ready` returns 503 while `/health` still returns 200 — the single most important behavioural difference in this phase.

- [ ] **Step 6: Record the verification**

Write `docs/phases/phase1/2026-08-05-local-verification.md` in the style of the Phase 0 findings: for each of the eleven calls above, the exact command, its raw output, and whether it matched expectation. This is the document Phase 5 will compare a real deployment's responses against.

- [ ] **Step 7: Update `app/README.md`**

Replace the "Phase 1 builds this test-first" paragraph with the real commands — `make run-local`, `make test`, `make lint`, `make local-down` — a one-paragraph description of the three-layer structure, and a table of the five endpoints with their status codes. Keep the existing paragraph about `/version` being load-bearing; it is still true and Phase 6 depends on it.

- [ ] **Step 8: Commit**

```bash
git add app/.env.example app/src/bgd/cli/ app/README.md makefile \
        docs/phases/phase1/2026-08-05-local-verification.md
git commit -m "feat(app): add local DynamoDB development and record the verification"
```

---

## Task 10: Pre-merge CI and phase closure

Phase 0 §C4 deferred the pull-request workflow to Phase 1, "once there is Python to check". There now is. This closes the gap roadmap §2.1 concedes: pull requests do not trigger the CodePipelines, so without this the pre-merge gate is voluntary.

**Files:**
- Create: `.github/workflows/pr-validate.yml`
- Modify: `docs/phases/phase1/2026-08-05-local-verification.md` (append the CI result)

**Interfaces:**
- Consumes: `app/requirements-dev.txt`, `app/pyproject.toml`
- Produces: a required status check on every pull request to `main`

- [ ] **Step 1: Write `.github/workflows/pr-validate.yml`**

```yaml
# Pre-merge validation.
#
# GitHub's role in this design is source-only: CodeConnections grants
# CodePipeline read access and a push to main triggers a deployment. This
# workflow deploys nothing and needs no AWS credentials and no OIDC federation
# — it lints and tests source, and touches nothing in the account.
#
# It exists because pull requests do not trigger the pipelines (roadmap §2.1),
# only the merge does. Without it the pre-merge gate would be the honour system.
name: pr-validate

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: pr-validate-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint-and-test:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: app

    # The contract suite runs against DynamoDB Local. A service container is
    # the GitHub-native equivalent of `make local-up`.
    #
    # No `command:` override, deliberately — service containers cannot set one,
    # and this image's default entrypoint is already
    # `java -jar DynamoDBLocal.jar -inMemory` on port 8000. The compose file
    # adds -sharedDb for local work so the AWS CLI and the app agree; here every
    # client is the test suite presenting the same credentials and region, so
    # there is nothing to share across.
    services:
      dynamodb-local:
        image: amazon/dynamodb-local@sha256:ff89bd48ff32cd8d9be5fee8873b65b8854dc408f1afe881be6eb00247bc0dab
        ports:
          - 8000:8000

    steps:
      - uses: actions/checkout@v5

      - uses: actions/setup-python@v6
        with:
          # The repository pin, so CI and this machine cannot disagree.
          python-version-file: .python-version
          cache: pip
          cache-dependency-path: app/requirements-dev.txt

      - name: Install hash-pinned dependencies
        run: pip install --require-hashes -r requirements-dev.txt

      - name: Ruff lint
        run: ruff check --output-format=github .

      - name: Ruff format check
        run: ruff format --check .

      - name: Tests with coverage
        run: pytest
```

> `python-version-file` points at the repository root's `.python-version` (`3.14.6`) — `working-directory` applies to `run` steps only, not to `uses`. If the runner image does not carry that exact patch release, `setup-python` fails with a clear "version not found" message; the one-line fix is to replace that key with `python-version: "3.14"` and note the divergence in the verification document. Step 3 is what determines which applies.

- [ ] **Step 2: Verify the whole suite is green locally first**

```bash
make verify
make lint
make test
```

Expected: all three exit 0, with coverage ≥ 90%.

- [ ] **Step 3: Push the branch and confirm the workflow passes**

```bash
git add .github/workflows/pr-validate.yml
git commit -m "ci: validate pull requests with ruff and pytest"
git push -u origin feat/Phase1_Application
gh run watch
```

Expected: the `lint-and-test` job succeeds. If `setup-python` cannot find 3.14.6, apply the one-line fallback in the note above, commit it, and record the divergence.

- [ ] **Step 4: Append the CI result to the verification document**

Add a short section recording the workflow run URL, the Python version the runner actually resolved, and whether the pin or the fallback was used.

- [ ] **Step 5: Open the pull request**

```bash
gh pr create --base main --title "Phase 1 — Application (local, test-driven)" --body "..."
```

The body follows the repository's pull request template, with the Phase 1 exit criteria of §6 below and how each was verified.

- [ ] **Step 6: Commit the documentation update**

```bash
git add docs/phases/phase1/2026-08-05-local-verification.md
git commit -m "docs: record the Phase 1 CI verification"
```

---

## 5. Commit sequence

Each commit is **proposed for your approval, never made automatically** (roadmap §2). Test commits precede implementation commits where the work is test-driven; within a task the test file and its implementation are committed together, because a commit that leaves the suite red is not a useful bisect point.

| # | Task | Commit |
|---|---|---|
| 1 | 1 | `build: pin the toolchain to a project virtualenv and hash-locked deps` |
| 2 | 2 | `feat(app): add settings and structured JSON logging` |
| 3 | 3 | `feat(app): add the domain model and error hierarchy` |
| 4 | 4 | `feat(app): add the repository contract and in-memory implementation` |
| 5 | 5 | `feat(app): add the ledger service with idempotent transaction replay` |
| 6 | 6 | `feat(app): add the DynamoDB repository with atomic balance updates` |
| 7 | 7 | `feat(app): add the API shell, RFC 9457 errors and request context` |
| 8 | 8 | `feat(app): add the accounts and transactions endpoints` |
| 9 | 9 | `feat(app): add local DynamoDB development and record the verification` |
| 10 | 10 | `ci: validate pull requests with ruff and pytest` |
| 11 | 10 | `docs: record the Phase 1 CI verification` |

---

## 6. Exit criteria

Phase 1 is done when every line below is true and demonstrated.

1. `make test` passes with **coverage ≥ 90%** on `src/bgd`, run on Python **3.14.6** — confirmed by `app/.venv/bin/python --version`, not by `python3`.
2. `make lint` passes: `ruff check` and `ruff format --check` both clean.
3. `make verify` exits 0, with the `app/.venv` row reporting `3.14.6 ✓`. The pre-existing failure recorded in §F1 is resolved, and resolved by fixing the interpreter rather than by lowering a minimum.
4. The contract suite in `tests/contract/` passes against **both** repository implementations — the in-memory fake and the DynamoDB one running on DynamoDB Local — including the atomicity test proving a rejected debit writes nothing.
5. `make run-local` starts DynamoDB Local, creates both tables, and serves the API; all five endpoint groups return correct responses over HTTP.
6. `/health` returns 200 while DynamoDB is stopped, and `/ready` returns 503 at the same moment. Demonstrated, not asserted.
7. `/version` returns the four injected build fields, so Phase 6 has something to curl against `:443` and `:8443`.
8. `POST /api/transactions` replayed with the same idempotency key returns **201 then 200**, and the balance moves exactly once.
9. An overdraft returns a 409 `application/problem+json` document carrying `balance_minor` and `requested_minor`, and the balance is unchanged afterwards.
10. `app/requirements.txt` and `app/requirements-dev.txt` are hash-pinned, agree on every shared package, and the check that proves it is a test in the suite.
11. `docs/phases/phase1/2026-08-05-local-verification.md` records every command from Task 9 step 5 with its raw output.
12. No AWS mocking library appears in either lock file. The real backend is exercised against AWS's own implementation.
13. `.github/workflows/pr-validate.yml` runs green on the pull request, with its DynamoDB Local service container.
14. A pull request is open against `main`, its description listing these criteria and how each was verified.

---

## 7. Risks inside this phase

| Risk | Handling |
|---|---|
| **DynamoDB Local is not the real service** | Accepted (§0), and the closest approximation available without spending money. AWS documents the divergences — throughput is not enforced, table creation is instant, some limits differ — and none of them touch what Phase 1 asserts: conditional writes, transaction atomicity, index ordering. Phase 5 is the first deployment against the real service and re-runs the same calls. |
| **`make test` now requires docker** | `test` depends on `local-up`, so the container starts automatically and CI uses a service container. Running `pytest` directly without it **fails** with "run `make local-up`" rather than skipping — a silently skipped backend test would defeat the entire reason for choosing the higher-fidelity tool. |
| **The interpreter fix moves the problem rather than solving it** | It does not: `create-venv.sh` resolves an absolute path and every make target calls the venv by absolute path, so no shell startup file is consulted at any point. `check_venv_pin` in `make verify` is the standing guard. |
| **`setup-python` may not offer 3.14.6** | Discovered in Task 10 step 3, with a one-line fallback stated in advance. Not a blocker — CI would run 3.14.x instead of 3.14.6, and the local venv remains exact. |
| **The LSI cannot be added after the table exists** | This is why `schema.py` is the single source of truth and why the plan flags it for Phases 5 and 6. A Terraform table declared without the index would need destroying and recreating — which, on prod, means data loss. |
| **Coverage gates encourage tests written for the metric** | The 90% gate is a floor, not a target. The contract suite and the atomicity, idempotency and `/health`-isolation tests are the ones that carry the value; if coverage is short, the instruction in Task 8 step 5 is to add the missing test, never to lower `fail_under`. |
| **Ambient AWS credentials in a developer shell** | Neutralised at session scope in `conftest.py` (§F2), including `AWS_CONFIG_FILE`, so the suite cannot reach AWS even if a profile is exported. |

---

## 8. What comes next

Phase 2 branches from `main` as `feat/Phase2_ContainerBuild` and turns `app/` into a reproducible artifact: a multi-stage `Dockerfile` on `python:3.14-slim` pinned by SHA256 digest, `pip install --require-hashes` against `app/requirements.txt`, the four `BGD_APP_VERSION` / `BGD_GIT_SHA` / `BGD_IMAGE_DIGEST` / `BGD_BUILT_AT` values injected as build arguments and surfaced by `/version`, an SBOM from syft, and an `api` service added to `app/docker-compose.yml`.

Phase 2 depends on Phase 1 for four things specifically: the hash-pinned `requirements.txt`, the `PYTHONPATH=/app/src` layout, `create_app` being importable as a factory (`uvicorn bgd.api.main:create_app --factory`), and the four build-metadata settings fields already being read from the environment.
