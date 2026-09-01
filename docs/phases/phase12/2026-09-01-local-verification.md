# Phase 12 — local verification record

**Date:** 2026-09-01
**Branch:** `feat/Phase12_UI_implementation`
**AWS resources created:** none. No AWS session was used at any point in this
session — every command below ran against a local Docker daemon and a local
DynamoDB Local container.

Everything below was executed. Where a command's output is quoted, it is the
output, not a description of it.

**Companion documents:**
[the implementation plan](./2026-09-01-phase-12-implementation-plan.md) ·
[the runbook](../../runbooks/phase-12-frontend-demo.md) ·
[Phase 8 verification record](../phase8/2026-08-30-local-verification.md)

---

## 1. The gate

Six commands, run in order, from Task 7's own execution (2026-09-01):

```
$ make test
 Container bgd-dynamodb-local  Running
........................................................................ [ 46%]
........................................................................ [ 92%]
............                                                             [100%]
================================ tests coverage ================================
_______________ coverage: platform darwin, python 3.14.6-final-0 _______________

Name                                  Stmts   Miss Branch BrPart  Cover   Missing
---------------------------------------------------------------------------------
src/bgd/__init__.py                       0      0      0      0   100%
src/bgd/api/__init__.py                   0      0      0      0   100%
src/bgd/api/dependencies.py              14      0      0      0   100%
src/bgd/api/errors.py                    34      0      2      0   100%
src/bgd/api/main.py                      24      2      2      1    88%   26-28
src/bgd/api/middleware.py                41      4      8      2    88%   27-28, 109-110
src/bgd/api/routers/__init__.py           0      0      0      0   100%
src/bgd/api/routers/accounts.py          18      0      0      0   100%
src/bgd/api/routers/health.py            20      0      0      0   100%
src/bgd/api/routers/transactions.py      18      0      2      0   100%
src/bgd/api/routers/ui.py                17      0      0      0   100%
src/bgd/api/schemas.py                   22      0      0      0   100%
src/bgd/cli/__init__.py                   0      0      0      0   100%
src/bgd/cli/create_tables.py             33      6     12      2    78%   21->exit, 25-29, 58
src/bgd/config.py                        19      0      0      0   100%
src/bgd/domain/__init__.py                0      0      0      0   100%
src/bgd/domain/errors.py                 21      0      0      0   100%
src/bgd/domain/models.py                 56      2     16      2    94%   63, 89
src/bgd/domain/services.py               39      1      8      1    96%   115
src/bgd/logging.py                       27      0      6      0   100%
src/bgd/repository/__init__.py            0      0      0      0   100%
src/bgd/repository/base.py               14      0      6      6    70%   26->28, 26->exit, 28->30, 28->exit, 39->41, 39->exit
src/bgd/repository/dynamodb.py          110     17     16      5    83%   65->73, 127, 134-135, 144-145, 160->163, 198-199, 220, 248, 256-257, 277-278, 298-299, 303-304
src/bgd/repository/memory.py             47      0     10      0   100%
src/bgd/repository/schema.py              3      0      0      0   100%
---------------------------------------------------------------------------------
TOTAL                                   577     32     88     19    92%
Required test coverage of 90.0% reached. Total coverage: 92.03%
156 passed, 15 deselected in 1.59s
```

```
$ make lint
All checks passed!
47 files already formatted
All checks passed!
5 files already formatted
```

```
$ make build
  ! working tree is dirty — tagging as 3db80c7-dirty
==> building bgd-us-east-1-api:0.1.0-3db80c7-dirty
  platform           linux/arm64
  release colour     blue
  SOURCE_DATE_EPOCH  1788282635 (2026-09-01T17:10:35Z)
...
  ✓ built bgd-us-east-1-api:0.1.0-3db80c7-dirty
  digest    sha256:872dfd8b24b9eabea31f342f6889805a735cb605f32f4c76f69bd745d83ac3e4
  archive   app/dist/image.oci.tar
```

The `-dirty` tag is expected and unrelated to Phase 12's own files: the
working tree carries pre-existing, task-unrelated uncommitted files at the
repository root (`fixIssues.md`, `instructions.md`, `summary.md`, out of
scope per this task's brief) alongside the roadmap amendment this task
verifies and commits below. `git_sha` in every build in this session is
`3db80c7`, the tip commit at the time these commands ran (Task 6's smoke
commit).

```
$ make image-test
  ! working tree is dirty — tagging as 3db80c7-dirty
==> building bgd-us-east-1-api:0.1.0-3db80c7-dirty
  platform           linux/arm64
  release colour     blue
  SOURCE_DATE_EPOCH  1788282635 (2026-09-01T17:10:35Z)
...
  ✓ built bgd-us-east-1-api:0.1.0-3db80c7-dirty
  digest    sha256:872dfd8b24b9eabea31f342f6889805a735cb605f32f4c76f69bd745d83ac3e4
  archive   app/dist/image.oci.tar
 Container bgd-dynamodb-local  Running
exists   bgd-us-east-1-local-accounts
exists   bgd-us-east-1-local-transactions
tables ready
...............                                                          [100%]
15 passed, 156 deselected in 2.16s
```

Both `make build` and `make image-test` rebuilt the image independently and
produced the same digest twice from the same input — `sha256:872dfd8b24b9eabea31f342f6889805a735cb605f32f4c76f69bd745d83ac3e4`, from `app/RELEASE_COLOR = blue` at the same commit. Two sequential builds seconds
apart on one machine is not what "reproducible" means; that claim is `make
image-verify`, below.

```
$ make image-verify
==> build one of 2
==> build two of 2

  build 1  sha256:872dfd8b24b9eabea31f342f6889805a735cb605f32f4c76f69bd745d83ac3e4
  build 2  sha256:872dfd8b24b9eabea31f342f6889805a735cb605f32f4c76f69bd745d83ac3e4

  ✓ reproducible — both builds produced the same manifest digest
```

```
$ make docs-check
  ✓ 288 relative links across 65 files all resolve
```

That count is with the runbook (`phase-12-frontend-demo.md`) and its
cross-references present but **before** this record itself existed as a file
— `make docs-check` scans untracked-and-not-ignored markdown too, and this
file did not exist yet at the moment that command ran. The baseline
established at the start of this task was `✓ 283 relative links across 64
files`; five new relative links and one new file (the runbook) account for
the rise to 288/65.

All six commands passed.

---

## 2. The three digests from Task 4 Step 5

Recorded there, quoted here as values:

| # | `app/RELEASE_COLOR` | digest |
|---|---|---|
| 1 | blue  | `sha256:83babd613fdae6de397ad3c6c261f51f345290201632ca58b946a96e0d991f56` |
| 2 | green | `sha256:60f25246a318174dd82401d9c01eead62aca6abd391361a0378daca98429eaa8` |
| 3 | blue  | `sha256:83babd613fdae6de397ad3c6c261f51f345290201632ca58b946a96e0d991f56` |

Both required relations held:

- **blue ≠ green**: digest 1 (`83babd61…`) is not digest 2 (`60f25246…`) — a
  colour change produces a different image.
- **blue = blue**: digest 3 (`83babd61…`) equals digest 1 (`83babd61…`) —
  restoring the colour restores the digest; the colour is the only varying
  input.

`make image-verify` was independently green in that task, and again in §1
above, on a later commit.

---

## 3. The smoke run from Task 6 Step 5, both directions

### Against the built image on `scripts/run-image.sh`, port 8081

```
$ BGD_SMOKE_URL=http://localhost:8081 \
  BGD_SMOKE_DIGEST="$(cat app/dist/image-digest.txt)" \
  scripts/smoke.sh prod

==> smoke — prod
  url     http://localhost:8081
  digest  sha256:65fc7eb1c7b5cbcdb0dcf5b469e6a45eed1f14e3dad604e1b6ef9b774392efe3

  /health    ✓
  /ready     ✓
  /version   ✓
  digest     ✓
  page       ✓
  colour     ✓

  ✓ prod is serving sha256:65fc7eb1c7b5cbcdb0dcf5b469e6a45eed1f14e3dad604e1b6ef9b774392efe3
```

All six checks green, against a real, built container.

### Against `make run-local`, port 8080

```
$ BGD_SMOKE_URL=http://localhost:8080 BGD_SMOKE_DIGEST=unknown scripts/smoke.sh prod

==> smoke — prod
  url     http://localhost:8080
  digest  unknown

  /health    ✓
  /ready     ✓
  /version   ✓
  digest     ✗ serving none, Terraform deployed unknown
  page       ✓
  colour     ✗ /version reports 'slate' — RELEASE_COLOR never reached the image; check both --build-arg lines

  ✗ 2 smoke check(s) failed against prod
```

Check 6 fails exactly as designed: `make run-local` runs from the host
virtualenv with no build arguments, so `/version` reports `release_color:
"slate"` — the local default — and smoke's colour check refuses to pass a
deployment reporting it. Check 4 also fails, on the pre-existing digest
check, for the same underlying reason (no build arguments reached this
process at all).

---

## 4. What this does not prove

**Exit criterion 1 is not met by this branch.** Exit criterion 1 reads:
*"During a production blue/green shift, the production listener and the test
listener serve visibly different buttons, captured as a screenshot."* No AWS
resource was created in this session, so there was no production
deployment, no ALB, no two listeners, and no shift in flight to screenshot.

A locally built page proves the page, not the platform. Two containers on
one laptop — Section A of the runbook — are two builds on one machine; they
are not two listeners in front of one ECS service. Both local containers
also share one `git_sha`, because editing `app/RELEASE_COLOR` on a laptop
leaves the tree dirty rather than producing a second commit — the two
windows differ in colour but not in build identity in the way a real
pipeline deployment would. Only the runbook's Section B, run against a real
production environment with two genuinely distinct commits, can produce the
screenshot exit criterion 1 asks for.

Exit criteria 2 and 3 **are** met by this branch:

- **Exit criterion 2** — `/version` reporting a `release_color` equal to
  `app/RELEASE_COLOR` at the commit that built the image — is met for a
  locally built container by §3 above (the `scripts/run-image.sh` run, check
  6 green), and its negative is equally demonstrated by the `make run-local`
  run failing for exactly the right reason.
- **Exit criterion 3** — two clean builds of one commit producing the same
  manifest digest, and a colour change producing a different one — is met by
  §2 above, in both directions, with the digests recorded as measured
  values.

What this session does prove: the offline gate is green (§1), the build
input reaches the image and is reproducible (§2), and the smoke check
correctly passes a colour-carrying deployment and correctly fails one that
never received the build argument (§3). What it cannot prove, by
construction, is that a real ECS blue/green shift puts two different colours
in front of two different listeners at once — that needs a deployment in
flight, and this branch created none.

---

## 5. `app/RELEASE_COLOR` check

```
$ cat app/RELEASE_COLOR
blue

$ git status --short app/RELEASE_COLOR
```

No output from the second command — `app/RELEASE_COLOR` is clean and reads
`blue`.
