# Phase 1 — code questions and answers

**Date:** 2026-08-10
**Branch:** `feat/Phase1_application_development`
**Companion documents:** [implementation plan](./2026-08-05-phase-01-implementation-plan.md) ·
[local verification](./2026-08-09-local-verification.md) · [`Session1Phase1.md`](../../../Session1Phase1.md)

A record of the parts of the Phase 1 code that were not obvious on reading, and
what each one actually does. Written question-first, so it can be read as a
reference rather than as prose.

Where an answer was checked by running something rather than by reasoning about
it, the measured output is included — those blocks are the evidence, not
decoration.

Three earlier questions — the DynamoDB Local image digest, `ge`/`le` in
`Query(...)`, and how `/ready` sets a 503 without returning the `Response` — are
already recorded in [`Session1Phase1.md` §5](../../../Session1Phase1.md) and are
not repeated here.

| # | Question | Subject |
|---|---|---|
| 1 | What is `Annotated[...]` in the dependency aliases? | `api/dependencies.py` |
| 2 | Are those aliases singletons? | `api/dependencies.py` |
| 3 | Does `install_exception_handlers` catch a `DomainError` raised anywhere? | `api/errors.py` |
| 4 | Why two objects, `Put` and `Update`, in one `transact_write_items`? | `repository/dynamodb.py` |
| 5 | What is `send_wrapper` for? | `api/middleware.py` |
| 6 | What is the request id actually for? | `api/middleware.py`, `logging.py` |
| 7 | What does `get_waiter` do, and is `_wait_for_endpoint` only a ping? | `cli/create_tables.py` |
| 8 | How is the exception message kept out of the 500 response? | `tests/api/test_errors.py` |
| 9 | What is `yield` doing in the `dynamodb_tables` fixture? | `tests/contract/conftest.py` |
| 10 | What is `capsys`? | `tests/contract/test_create_tables.py` |
| 11 | What is the `PIN` regex for? | `tests/unit/test_requirements_lock.py` |
| 12 | Why both `requirements.in` and `requirements.txt`? | `app/` |

Two code changes came out of these questions and are recorded in place below:
the request-id fix in §8, and — separately from any question — the CI-only test
failure fixed in `tests/contract/`. Two items were found and deliberately left
open; they are collected in the last section.

---

## 1. What is `Annotated[...]` in the dependency aliases?

```python
RepositoryDep = Annotated[LedgerRepository, Depends(get_repository)]
SettingsDep = Annotated[Settings, Depends(get_settings_dep)]
ServiceDep = Annotated[LedgerService, Depends(get_service)]
```

`Annotated` is standard library `typing` (PEP 593), not a FastAPI invention. It
means: *this is type `T`, plus metadata for whoever cares to look*.

```python
Annotated[LedgerService, Depends(get_service)]
#         ^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^^^^^
#         the real type   metadata, erased for type checkers
```

A type checker sees plain `LedgerService`. A runtime library that wants the
metadata asks for it explicitly, via `get_type_hints(fn, include_extras=True)`.
FastAPI does exactly that when inspecting a path operation: it finds a `Depends`
in the metadata, calls `get_service`, and passes the result in.

The three lines are **named aliases** for those annotations — nothing more.
`service: ServiceDep` expands to `service: Annotated[LedgerService, Depends(get_service)]`.

The same mechanism appears a layer up in `api/schemas.py:13`, with pydantic as
the reader instead of FastAPI:

```python
Currency = Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]
```

### Why this form rather than `= Depends(...)`

The pre-0.95 spelling was a default value: `service: LedgerService = Depends(get_service)`.
Three concrete differences, all visible in this codebase:

- **Parameter ordering stops mattering.** `Depends()` as a default makes the
  parameter *have* a default, so no plain parameter may follow it.
  `routers/transactions.py:29` reads `payload: TransactionCreateRequest, service: ServiceDep, response: Response`
  — three parameters, none with a default. In the old style, placing
  `service = Depends(...)` before `response: Response` is a `SyntaxError`.
- **The annotation stops lying.** In the old form the declared type is
  `LedgerService` but the runtime default is a `Depends` object, so calling the
  function outside FastAPI yields a `Depends` instance. With `Annotated` the
  parameter is genuinely just typed, and a path operation is an ordinary
  function.
- **It is aliasable.** `= Depends(get_service)` cannot be given a name and
  reused; an `Annotated[...]` can. That is the entire reason those three lines
  exist.

### What it buys, in practice

A change request that will arrive with authentication in a later phase — requests
carry an `X-API-Key`, and `LedgerService` must know the caller — is confined to
`dependencies.py`:

```python
def get_caller(x_api_key: Annotated[str | None, Header()] = None) -> Caller:
    caller = lookup_caller(x_api_key)
    if caller is None:
        raise UnauthenticatedError()
    return caller

CallerDep = Annotated[Caller, Depends(get_caller)]

def get_service(repository: RepositoryDep, caller: CallerDep) -> LedgerService:
    return LedgerService(repository, caller)      # the only construction site
```

Nothing else changes. All eight handlers still read `service: ServiceDep`
(`accounts.py:22,35,41`, `transactions.py:29,50`); `/health` and `/version` are
untouched and stay unauthenticated because they never asked for a service.
Without the aliases, `Depends(get_service)` is written out at eight call sites
and a constructor change means editing all eight signatures.

### The parameter list is an enforced capability list

| Handler in `routers/health.py` | Declares | Can it touch DynamoDB? |
|---|---|---|
| `health()` | nothing | **structurally cannot** |
| `ready(repository: RepositoryDep)` | the repository | yes — that is the point |
| `version(settings: SettingsDep)` | settings only | no |

The module docstring says `/health` must not check dependencies, because a
dependency check there would let one DynamoDB hiccup deregister every healthy
task at once. The aliases make that a property of the code rather than a rule to
remember: `health()` has no way to reach the repository, and breaking that would
require adding a parameter — a visible, reviewable diff.

---

## 2. Are those aliases singletons?

Not quite. **The alias is not an instance — it is a name for a recipe.** No
object exists at import time, and the lifetime of what you receive is decided by
the provider function, not by the alias.

Measured against this application:

```
2 requests -> LedgerService constructed 2x, distinct objects: 2
repository is the SAME object on every request: True
two create_app() calls share a repository:      False
one request, dependency asked for twice -> ran 1x, same object: True
```

| Alias | Provider | Lifetime |
|---|---|---|
| `RepositoryDep` | `request.app.state.repository` | **one per app** — created in `create_app`, reused by every request |
| `SettingsDep` | `request.app.state.settings` | one per app (`get_settings` is `lru_cache`d underneath) |
| `ServiceDep` | `LedgerService(repository)` | **new object per request**, reused within that request |

So the intuition holds for the first two and not for the third. `LedgerService`
is a stateless wrapper, so per-request construction is free — and it is what
makes the `CallerDep` change in §1 possible at all, since a per-request service
can carry per-request state and an app-wide one cannot.

The last line is the caching rule: **within one request**, a dependency asked
for twice runs once and both parameters receive the same object. Across
requests the cache is discarded.

### Where the singleton analogy breaks, and why that matters

The real alternative would be a module-level global:

```python
# the thing this design avoids
repository = DynamoDbLedgerRepository(boto3.client("dynamodb"), ...)   # at import time
```

That is one instance per *process*, bound at import, reachable from anywhere.
The aliases give one instance per **app object**, bound by `create_app`. The
third measurement is the whole difference — two `create_app()` calls do not
share a repository — and it is why `tests/api/test_accounts.py:10` can hand every
test a fresh `InMemoryLedgerRepository` with no patching and no cross-test bleed.
With a true singleton, every test would share one store, and importing the module
without AWS configuration would fail outright.

Accurate phrasing: the aliases mean each file **declares what it needs** instead
of **importing a specific instance**.

---

## 3. Does `install_exception_handlers` catch a `DomainError` raised anywhere?

Yes. Registration is **by exception type**, and dispatch walks the exception's
MRO, so one handler covers a whole family. All eight `DomainError` subclasses
land in `_domain`; the per-error distinction is then made by `exc.code` through
`STATUS_BY_CODE`, which is why `AccountNotFoundError` becomes 404 and
`RepositoryUnavailableError` becomes 503 without either having its own handler.

The function names (`_domain`, `_http`) are never used by anything — the
decorator does the registering, and the leading underscore says so.

The reach is anything raised **while the request is handled inside the router** —
the path operation, its dependencies, and anything they call, however deep:

```
/probe/deep    -> 503  REPOSITORY_UNAVAILABLE     raised 3 frames down, inside a service call
/nope          -> 404  NOT_FOUND                  FastAPI's HTTPException subclasses Starlette's
```

That is why `routers/accounts.py` and `routers/transactions.py` contain no
`try`/`except` at all: the repository raises `InsufficientFundsError`, and a 409
problem document carrying `balance_minor` appears at the edge.

### Three boundaries

**Exceptions raised in middleware get the catch-all, not the typed handler.**
Raising `AccountNotFoundError` from an ASGI middleware produces:

```
/probe/mw      -> 500  INTERNAL_ERROR             not 404
```

Starlette's stack is `ServerErrorMiddleware` (outermost) → *your* middleware →
`ExceptionMiddleware` → router. The three typed handlers live in
`ExceptionMiddleware`, which sits **inside** `RequestContextMiddleware`, so
nothing that middleware raises can reach them. Only the `Exception` handler is
special-cased: Starlette hands it to `ServerErrorMiddleware`, the outermost
layer.

**The catch-all re-raises after responding.** With a default `TestClient`:

```
raise_server_exceptions=True -> re-raised AccountNotFoundError
```

`ServerErrorMiddleware` sends the response *and then* re-raises, so the server
can log the traceback and test clients can surface it. That is why
`tests/api/test_errors.py` constructs `TestClient(app, raise_server_exceptions=False)`
— without it, `/probe/boom` would raise `RuntimeError` into the test instead of
yielding a 500 to assert on.

**Code that catches for itself never gets there.** `routers/health.py:24` wraps
`repository.ping()` in its own `try/except DomainError` and returns a 503
`ReadyResponse` with `checks`, not a problem document — so `/ready` never
reaches `_domain`. Also out of reach: background tasks (they run after the
response is sent) and `ResponseValidationError`, which is not a
`RequestValidationError` and so falls through to `_unhandled` as a 500.

**Precedence** is by most specific class, not registration order. Adding
`@app.exception_handler(InsufficientFundsError)` later would win over `_domain`
for that class alone, wherever it appears in the file.

---

## 4. Why two objects, `Put` and `Update`, in one `transact_write_items`?

`TransactItems` is a **list of actions**, and each element is a dict whose single
key names the verb — `Put`, `Update`, `Delete` or `ConditionCheck`. The key *is*
the discriminator; there is no `"action": "put"` field, and two verbs cannot
share one element. Each element carries its own `TableName`, its own condition,
and produces its own failure reason.

| # | Verb | Table | Job | Its condition |
|---|---|---|---|---|
| 0 | `Put` | `transactions` | record the transaction | `attribute_not_exists(transaction_id)` — the idempotency guard |
| 1 | `Update` | `accounts` | move the balance | account exists **and** `balance_minor >= :minimum` — the overdraft guard |

Item 0's guard works because `transaction_id_for()` (`domain/models.py:114`)
derives the id as a uuid5 of `account_id:idempotency_key` against a fixed
namespace. A replay computes the *same* id, so the `Put` collides with the
existing row — which is why the sort key *is* the idempotency check: no guard
item, no secondary index, no read-before-write.

Item 1's `:minimum` comes from `minimum_balance_minor` — the debit amount for a
debit, `0` for a credit — so the overdraft rule is stated once in the domain and
quoted by the backend.

### Why one call instead of two

`TransactWriteItems` is all-or-nothing. Split into two calls, the failure modes
have no correct recovery:

- Put succeeds, Update fails → a recorded transaction the balance never reflects.
- Update succeeds, process dies → money moved with no audit row.
- A race no ordering fixes: read the balance, decide it is sufficient, then write
  — two concurrent debits both pass the check and the account goes negative.
  Inside the transaction the `ConditionExpression` is evaluated **at commit**, so
  the second is rejected.

This is what makes exit criterion 9 true: an overdraft does not merely return
409, it rolls item 0 back with it, so no orphan transaction row exists.

### The list order is load-bearing

`CancellationReasons` comes back **positionally**, aligned to `TransactItems`.
`_translate_cancellation` indexes into it literally — `codes[0]` →
`DuplicateTransactionError`, `codes[1]` → account-missing or insufficient-funds,
disambiguated by `ReturnValuesOnConditionCheckFailure`. Swapping the two dicts
would leave the suite compiling and the writes correct while reporting
duplicates as insufficient funds. Recorded in §F3 of the plan; repeated here as
a constraint on ever reordering them.

### Constraints worth carrying forward

Up to 100 actions and 4 MB per transaction; **no two actions may touch the same
item**; and roughly **2× the write units** of the equivalent plain writes,
because DynamoDB performs a prepare and a commit pass.

---

## 5. What is `send_wrapper` for?

Because an ASGI app **does not return a response — it emits one**. There is no
return value to inspect or decorate; the response leaves as a stream of events
pushed through the `send` callable the server provided. The only way a raw ASGI
middleware can see or alter a response is to pass a *different* `send`
downstream, which is what line 51 does:

```python
await self.app(scope, receive, send_wrapper)   # not send
```

A response is always `http.response.start` — exactly once, carrying `status` and
`headers` — followed by one or more `http.response.body` chunks. Status and
headers exist only on that first message, which is why the whole body of the
wrapper is guarded by that type check. Two jobs there:

1. **Capture the status for the access log.** The `finally` block logs `method`,
   `path`, `status`, `duration_ms`, by which time the response is gone.
   `nonlocal status` writes back into the enclosing `__call__` frame; without it
   the assignment would create a local and vanish. The initial `status = 500` is
   what gets logged when no start message ever arrives — i.e. the app raised —
   which is also what the client ends up receiving.
2. **Inject `x-request-id`**, so the id in the JSON logs is also in the caller's
   hands. ASGI headers are a list of `(bytes, bytes)` pairs with lowercase names,
   hence `b"x-request-id"` and `.encode()`.

`await send(message)` then forwards unconditionally — the wrapper is a
pass-through, and anything not forwarded never reaches the client. Body chunks
fall straight through, which is what keeps streaming responses working.

It is a closure defined inside `__call__`, so it captures this request's
`request_id`, `send` and `status`. Every concurrent request gets its own wrapper;
instance state on the middleware would race.

---

## 6. What is the request id actually for?

Not for matching a response to its request — HTTP already guarantees that. It is
a join key across three surfaces that HTTP does not connect:

| Surface | Where | Who reads it |
|---|---|---|
| `x-request-id` response header | `middleware.py:46` | the caller — quotes it in a bug report |
| `request_id` in the problem body | `api/errors.py:53` | the caller, on any error response |
| `request_id` on **every log line** | `logging.py:37` | you, in CloudWatch |

The third is the payoff. `JsonFormatter.format` reads the ContextVar for every
record from every logger, so one id turns into

```
filter request_id = "8662dd1781574b338cf9702a6e0e49da"
```

and returns the whole request's story out of a log group holding every request
from every task.

It is a **distributed** key, not a local one — `middleware.py:30` reads an
inbound header first and mints a uuid4 only when there is none:

```python
request_id = Headers(scope=scope).get("x-request-id") or uuid.uuid4().hex
```

so when a caller or upstream proxy already assigned an id, these logs join to
theirs. From Phase 6 that is what tells you which colour served a given request.

### Where ASGI genuinely comes into it

ASGI is not the reason to want a request id — it is the reason the plumbing looks
like this, in two places. The response side needs `send_wrapper` (§5) because
responses are emitted, not returned. The log side needs a **`ContextVar`**, not a
thread-local: under async many requests share one thread, so a thread-local
would leak one request's id into another's log lines. A `ContextVar` is per-task
and propagates through the `await` chain, so a `logger.info` twelve frames deep
in the repository carries the id without anyone passing it along. That is also
what the middleware's docstring is protecting: `BaseHTTPMiddleware` runs the
downstream app in a *separate* anyio task, and context set in the middleware does
not reliably reach it — hence raw ASGI.

---

## 7. What does `get_waiter` do, and is `_wait_for_endpoint` only a ping?

Two different waits, doing different jobs.

### `get_waiter("table_exists")`

`create_table` is **asynchronous on the server side**: it returns as soon as the
request is accepted, with `TableStatus: CREATING`, and the table is not usable
yet. A waiter is botocore's canned polling loop for that gap — it calls
`DescribeTable` repeatedly until an *acceptor* matches. Read off the client:

```
waiter: TableExists | delay: 20s | max_attempts: 25 | ceiling: 500s
  success  <- path  Table.TableStatus == ACTIVE
  retry    <- error ResourceNotFoundException
```

It hides two things: the `CREATING → ACTIVE` transition, and the fact that a
just-created table can briefly still answer `ResourceNotFoundException` — a retry
condition, not a failure. Those rules come from botocore's service model, not
from this code; `client.waiter_names` also offers `table_not_exists`, which a
teardown script would use.

Two details about its placement:

- **It sits outside the `try`/`except`**, so it runs on both branches — waiting
  for a table just created, and for one left `CREATING` by an earlier interrupted
  run. Either way, when `main()` returns, both tables are `ACTIVE`.
- **That is what makes `make run-local` safe.** The recipe is `local-tables` then
  `uvicorn`, which starts the instant this process exits. Without the waiter the
  first request could hit a `CREATING` table and get a `ResourceNotFoundException`
  that looks like a repository bug. On DynamoDB Local creation is effectively
  instant, so the first poll succeeds; against real AWS this is where the time
  goes.

### `_wait_for_endpoint`

Yes, it is a connectivity gate — but narrower than "see if it is connected":

- **It catches only `EndpointConnectionError`**, the "nothing is accepting TCP on
  that port" error. Anything else — bad credentials, a 4xx, wrong region —
  propagates on the *first* attempt, so a genuine misconfiguration fails
  immediately with its real message and only the startup race is retried. A
  blanket `except Exception` would turn every mistake into a 30-second silence
  followed by a misleading error.
- **`list_tables()` is just the cheapest call needing no arguments and no
  pre-existing state** — it has to work before any table exists, which rules out
  `describe_table`. Worth contrasting with `/ready`, which pings via `get_item`
  on a key that does not exist (`repository/dynamodb.py:288`) because
  `ListTables`/`DescribeTable` are control-plane calls that throttle under
  polling. Here it runs once at startup, so the control plane is fine.
- **Why the race exists:** `make local-tables` depends on `local-up`, which is
  `docker compose up -d`. That returns when the *container* has started, not when
  the JVM inside has bound port 8000 — a gap of a second or two. The loop
  converts the race into a wait, prints progress so a human does not think it
  hung, and re-raises on the last attempt so failure is loud.

One caveat, connected to open finding F9: the 30-second ceiling assumes each
failed attempt returns fast. Against `localhost` it does — nothing listening
means connection-refused, instantly. Against a host that black-holes packets,
each attempt burns botocore's default 60-second connect timeout plus retries, so
"30 attempts × 1 s" becomes many minutes. The explicit `botocore.config.Config`
scoped for F9 would bound this loop too.

---

## 8. How is the exception message kept out of the 500 response?

`_boom` raises `RuntimeError("secret internal detail")`, and
`test_an_unhandled_exception_becomes_a_500_that_leaks_nothing` asserts the string
never appears in the body. It does not, because `_unhandled` **never reads
`exc`** — every string in the response is a literal:

```python
logger.exception("unhandled exception", extra={...})            # detail goes HERE
return problem_response(500, "INTERNAL_ERROR",
                        "an unexpected error occurred", ...)     # …and nowhere else
```

Measured, for one request:

```
BODY -> {"detail":"an unexpected error occurred","code":"INTERNAL_ERROR", …}
LOG  -> logger=bgd.api.errors  traceback_has_secret=True
```

The contrast with `_domain`, which *does* pass `exc.message` through, is
deliberate: domain error messages are written for the caller ("the account
balance is too low"), whereas an arbitrary `Exception` message is written for you
and may carry a connection string, a key or a file path. The test asserts against
`response.text`, the raw body, so it catches a leak anywhere in the document —
including inside a nested `errors` array.

### A bug this question surfaced, and its fix

The body's `request_id` was `"-"` — the ContextVar default — and so was the
`request_id` on the log line carrying the traceback. Only the access line had the
real id. Cause: `middleware.py` resets the ContextVar in its `finally`, which
runs as the exception propagates *out* of that middleware, while `_unhandled`
runs afterwards in `ServerErrorMiddleware`, one layer further out. The docstring's
claim — "request_id is the link to the log line that does carry the detail" —
did not hold on precisely the path it was written for, and the test passed
because `assert response.json()["request_id"]` is truthy for `"-"`.

Fixed test-first:

- `middleware.py` stashes the id on the ASGI scope, which outlives the reset:
  `scope.setdefault("state", {})["request_id"] = request_id`.
- `_unhandled` reads it from there and passes it explicitly to both sinks:
  `getattr(request.state, "request_id", request_id_var.get())`, then
  `extra={"request_id": ...}` on the log call and `request_id=...` on
  `problem_response`. Both win, because `JsonFormatter`'s promotion loop
  (`logging.py:39`) and `body.update(extra)` (`api/errors.py:55`) each run after
  the ContextVar read.
- The weak assertion became `!= "-"`, and a new test pins the value exactly by
  sending `x-request-id: known-id-123` and asserting the body echoes it.

Both new assertions failed before the change and passed after:

```
LOG  -> logger=bgd.access      request_id='demo-42'
LOG  -> logger=bgd.api.errors  request_id='demo-42'   traceback_has_secret=True
BODY -> {"code":"INTERNAL_ERROR","request_id":"demo-42"}
leaks? -> False
```

Domain errors were never affected: `ExceptionMiddleware` is *inside*
`RequestContextMiddleware`, so `/probe/domain-error` always carried the real id.

---

## 9. What is `yield` doing in the `dynamodb_tables` fixture?

It turns the fixture into **setup / teardown around the test**. Everything before
the `yield` runs first, the yielded value is handed to the test, and everything
after it runs when the test is done:

```
SETUP    (before yield)
TEST     got: 'the value the test receives'
.        TEARDOWN (after yield)          passing test

SETUP    (before yield)
TEST     about to fail
F        TEARDOWN (after yield)          failing test: teardown still runs

SETUP    raising before yield            setup failed:
                                         no teardown, test never ran, reported as "error"
```

Mapped onto the fixture:

| Phase | Code | What happens |
|---|---|---|
| setup | `create_table(**definition)` ×2 | a private pair of tables with a uuid suffix |
| hand-off | `yield client, accounts, transactions` | the test's `dynamodb_tables` parameter, unpacked at `conftest.py:94` |
| teardown | `delete_table(...)` ×2 | runs after the test, **pass or fail** |

With `return` there would be nowhere to put the deletes — the function ends
there. `yield` lets pytest suspend the fixture mid-function, run the test, and
resume it afterwards. (The pre-`yield`-only alternative is
`request.addfinalizer(...)`, the older style, which separates cleanup from the
setup it undoes.)

Three properties worth knowing:

- **Exactly one `yield`.** A second is an error, not a second test run.
- **Teardown runs on failure**, so a red contract test does not leave orphan
  tables behind — which matters *because* the names are unique: a leak would not
  collide, it would accumulate silently.
- **Teardown does not run if setup raised.** If `accounts` is created and
  `transactions` then fails, the first table leaks. Bounded by the compose
  command, `["-jar", "DynamoDBLocal.jar", "-sharedDb", "-inMemory"]` — `-inMemory`
  means the whole store dies with the container, so `make local-down` is a
  complete reset. That is also why unique names per test cost nothing here.

The scope is the default, `function`, which is what makes "per test" true —
contrast `dynamodb_endpoint` just above it, which is `scope="session"` so the
reachability check runs once per run rather than 21 times.

---

## 10. What is `capsys`?

pytest's built-in **stdout/stderr capture**. It is needed because `main()` is a
CLI whose entire observable behaviour is `print()` — which is why
`pyproject.toml` allowlists ruff's `T201` for `src/bgd/cli/*`. There is no return
value to assert on.

Two things it does: it redirects `sys.stdout`/`sys.stderr` for the duration of
the test, and `readouterr()` **returns and drains** — handing back everything
captured since the last call, then emptying the buffer. That drain is what lets
the test take two clean windows:

```python
main()
first = capsys.readouterr().out    # buffer now empty
main()
second = capsys.readouterr().out   # only the second run's lines
```

which is what makes the idempotency claim testable, because the two runs print
different things:

```
--- run 1 ---            --- run 2 ---
created  …-accounts      exists   …-accounts
created  …-transactions  exists   …-transactions
tables ready             tables ready
```

**A stronger assertion the drain earns.** The test asserts only *presence*
(`"exists  …" in second`), so it would still pass if a bug made the second run
print both `created` and `exists`. Having drained the buffer, the absence can be
asserted too — `assert f"created  {accounts}" not in second` — which is the
sharper statement of idempotency. Verified to hold; not yet added.

**A gotcha for later:** `capsys` captures at the `sys.stdout` *object* level. A
`logging.StreamHandler` created before the capture is installed holds a reference
to the original stream and writes straight past it. To assert on the structured
logs, use `caplog`; `capfd`, which captures at the file-descriptor level, is the
option for subprocess and C-extension output.

---

## 11. What is the `PIN` regex for?

```python
PIN = re.compile(r"^(?P<name>[A-Za-z0-9._-]+)==(?P<version>[^\s;\\]+)")
```

A **one-line parser for pip-compile's lock format**. `_pins()` needs to turn a
lock file into `{package: version}` so the four tests can compare the two files
as dictionaries — and doing that without adding a runtime parsing dependency
means a regex.

The format it cuts through: `requirements.txt` is 627 lines, of which **27** are
actual pins. The rest are comments, `# via` provenance, and two or more
`--hash=sha256:…` continuation lines per package.

```
annotated-doc==0.0.5 \                      ->  MATCH name='annotated-doc' version='0.0.5'
    --hash=sha256:117bac03a25ede5df5440…    ->  no match
    # via fastapi                           ->  no match
```

| Fragment | Why |
|---|---|
| `^` | anchors to line start, so a name mentioned mid-line in a `# via` comment cannot match |
| `[A-Za-z0-9._-]+` | the legal characters in a distribution name |
| `==` | the discriminator. `--hash=sha256:…` contains `=` but never `==`, and `-r requirements.txt` has none — which excludes both despite `-` being a legal name character |
| `[^\s;\\]+` | the version stops at whitespace, at `;`, and at `\` |

That last class is what makes the comparison sound. `--generate-hashes` writes
the trailing backslash on the same line, and environment markers appear as
`foo==1.2 ; python_version < "3.13"`. Without excluding `\`, `\s` and `;`, the
version would come out as `0.0.5 \`, and if the two locks wrapped differently
`test_dev_lock_agrees_with_the_runtime_lock` would report drift that does not
exist.

The named groups then feed the normalisation in `_pins`:

```python
pins[match["name"].lower().replace("_", "-")] = match["version"]
```

PEP 503-style name folding, so `pytest_cov` in one file and `pytest-cov` in the
other compare as the same package. (Full PEP 503 also collapses `.` and runs of
separators — `zope.interface` → `zope-interface`. Not handled, and it does not
bite because pip-compile emits normalised names on both sides.)

So `PIN` is what makes the drift assertion in the module docstring *checkable*:
it turns two 600-line text files into two comparable dicts, so "the boto3 the
tests exercise is the boto3 the image ships" is proven on every run rather than
assumed.

---

## 12. Why both `requirements.in` and `requirements.txt`?

Two files, two jobs: **`.in` is what you asked for; `.txt` is what you got.** The
pip-tools convention, and the lock states its own provenance in its header:

```
# This file is autogenerated by pip-compile with Python 3.14
#    pip-compile --allow-unsafe --generate-hashes --output-file=requirements.txt --strip-extras requirements.in
```

| | `requirements.in` | `requirements.txt` |
|---|---|---|
| Written by | you | `make deps-compile` |
| Contains | 5 direct dependencies | **27** pinned packages |
| Size | 7 lines | 627 lines |
| Versions | unpinned, or bounded like `pip<26` | exact `==`, plus `--hash=sha256:` |
| Answers | "what does this app need?" | "what exactly gets installed?" |

The lock holds 27 pins because it is the full **transitive closure**, and it
records who dragged each one in:

```
annotated-doc==0.0.5      # via fastapi              transitive
fastapi==0.141.1          # via -r requirements.in   direct: you asked for this one
```

That provenance is the practical reason to keep both. With only the lock,
dropping `boto3` means guessing which of the 27 pins came along for the ride.
With only the `.in`, two installs a month apart get different versions — which is
what design §4.1's reproducibility requirement forbids, and what
`pip install --require-hashes` (the image, and the CI step) refuses to do without
hashes.

The `.in` also carries the *reasoning* a generated file would erase on every
recompile: the `pip<26` bound with its F7 explanation, the `httpx2 # F5` note,
and the standing statement that no AWS mocking library is present.

Three details specific to this setup:

- **`-r requirements.in` at the top of `requirements-dev.in`** makes the dev set a
  superset, so one install gives a working test environment. pip-compile then
  resolves the two files *independently*, which is exactly the silent drift
  `test_requirements_lock.py` exists to catch (§11).
- **`--strip-extras`** is why `uvicorn[standard]` in the `.in` becomes plain
  `uvicorn==…` in the `.txt`, with the extra's dependencies pinned individually.
- **`--allow-unsafe`** is the F7 fix: without it pip-compile leaves `pip` and
  `setuptools` unpinned and warns that `pip install --require-hashes` may reject
  the result — the exact command CI runs.

The extensions themselves are convention; pip will `install -r` either file. What
matters is which one is installed: the dev lock locally and in CI, the runtime
lock in the image.

---

## Left open

Both were found while answering the questions above and were deliberately not
fixed here.

**No `x-request-id` header on unhandled 500s.** `ServerErrorMiddleware` emits
that response outside `RequestContextMiddleware`'s send wrapper, so no header
injection reaches it. Since §8, the body carries the id, so a caller can still
quote it. Fixing the header means restructuring where it is added — grouped with
F9 for Phase 9.

**`get_account` is an eventually-consistent read.** `post_transaction` re-reads
the account to return the new balance (`repository/dynamodb.py:201`), and
`get_account` issues a plain `get_item` with no `ConsistentRead=True`. On real
DynamoDB that read can land on a replica that has not caught up and return the
*pre-transaction* balance, so a 201 could report a balance that does not include
the transaction just posted. DynamoDB Local is single-node and always returns
fresh data, so no test here can catch it — the divergence the plan's §7 accepts
as a known risk. It would first appear in Phase 5. The fix is `ConsistentRead=True`
on that one read path (2× RCU on a single-item read), not on `list_accounts`.
