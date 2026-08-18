# Phase 2 — Reproducible container build: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-12
**Status:** Proposed, awaiting approval
**Branch:** `feat/reproducible_container_build`
**AWS cost incurred by this phase:** $0 — no AWS API call is made. The image is built, run and inspected entirely locally; it does not reach ECR until Phase 3.
**Companion documents:**
[design research](../../2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 0 findings](../phase0/2026-08-04-phase-00-verification-findings.md) ·
[Phase 1 plan](../phase1/2026-08-05-phase-01-implementation-plan.md) ·
[naming and tagging convention](../../naming-and-tagging-convention.md)

**Goal:** Turn the Phase 1 application into an artifact whose reproducibility can be *pointed at* rather than asserted — a digest-pinned, non-root, multi-stage image whose manifest digest is a pure function of the source, proved by building it twice.

**Architecture:** Two stages on one digest-pinned base. A *builder* stage compiles a virtualenv at `/opt/venv` from the hash-locked requirements; a *runtime* stage copies that venv and `src/`, runs as a numeric non-root UID, and receives its build identity through three `ARG`s that become the `BGD_*` environment variables `/version` already reads. Around the image sit four shell scripts — build, SBOM, repeatability, run — and one pytest suite that exercises the running container over real HTTP.

**Tech stack:** Docker 28.3.2, buildx v0.26.1 with BuildKit v0.23.2, `python:3.14.6-slim` pinned by digest, syft 1.51.0 run from a digest-pinned container, and the Phase 1 test toolchain (pytest 9.1.1, httpx2 2.10.0).

> **Branch note.** Roadmap §2 names this branch `feat/Phase2_ContainerBuild`. The branch already in flight when work started is `feat/reproducible_container_build`, and that is the one used. The roadmap table is amended in Task 8 rather than the branch renamed, following the precedent Phase 0 set when it amended the same table.

---

## 0. Purpose and non-goals

Phase 2 produces the artifact every phase from 3 onward deploys. Like Phase 1, it is verifiable completely on this machine, and so it is verified completely.

**This phase deliberately does not:**

- create any AWS resource, call any AWS API, or require an SSO session
- push to ECR — that is Phase 3, which seeds the registry with the image built here
- write any Terraform
- change any application source under `app/src/` — the image packages Phase 1's service unchanged
- scan the image for vulnerabilities. An SBOM is an *inventory*, not a scan; ECR scan-on-push (Phase 3) and any later scanning tool consume it

### 0.1 Decisions taken before this plan was written

Eight questions were asked and answered on 2026-08-12. Each is recorded with the consequence that follows from it, because in every case the consequence — not the decision — is what later phases inherit.

#### D1 — Target architecture: **`linux/arm64` only**

The image targets arm64 and nothing else.

**Consequences:**

- Builds are **native** on this Apple Silicon machine. No QEMU emulation, so build times stay in seconds and `pip` resolves the same wheels it would resolve anywhere on arm64. This matters more than convenience: an emulated build is a different build, and the repeatability claim in D4 would be measuring the emulator as much as the Dockerfile.
- **Phases 5 and 6 must set `runtime_platform { cpu_architecture = "ARM64" }`** on both task definitions. This is not optional and it is not the provider default — a task definition left at the `X86_64` default will fail to start this image with an exec-format error. This is the single most important line this decision writes into a later phase.
- Fargate ARM64 (Graviton) is roughly 20% cheaper per vCPU-hour than x86, which compounds with the destroy-when-idle policy of roadmap §0.
- **Phase 8's CodeBuild project must use an ARM compute type** (`ARM_CONTAINER` with an `aarch64` standard image). An x86 CodeBuild project would have to cross-build under emulation, which re-introduces exactly what this decision avoids.
- The `Dockerfile` itself stays architecture-neutral — the base is pinned by *index* digest (see D2), so adding amd64 later is a change to the build command, not to the Dockerfile.

#### D2 — Base image: **`python:3.14.6-slim`, pinned by digest**

Not `python:3.14-slim`, which today resolves to 3.14.7.

**Consequences:**

- **Design §1.6's parity argument becomes literally true.** `.python-version` says 3.14.6, the venv is 3.14.6, CI's `setup-python` reads the same file, and the container is 3.14.6. There is no patch-level divergence to caveat.
- Patch upgrades become a **deliberate, reviewable commit** that moves `.python-version`, the base digest and both requirement locks together, rather than arriving silently the next time a tag is re-pulled.
- The pin is the **index** digest `sha256:7bec7ddcddeff…`, not the arm64 manifest digest inside it. Both freeze the content equally; the index keeps `--platform` selection working, so D1 can be revisited without touching the Dockerfile.
- A dated comment records how to re-resolve the digest, matching the convention `docker-compose.yml` already uses for DynamoDB Local.

#### D3 — SBOM: **syft, run from a digest-pinned container**

`anchore/syft:v1.51.0` → `sha256:678bfa565b60…`. Nothing is installed on the host.

**Consequences:**

- `scripts/verify-tools.sh` gains **no syft row**, because there is no host syft to check. The tool is pinned the same way every other dependency in this repository is pinned — by digest.
- **The identical command works unchanged in Phase 8's CodeBuild**, where installing a tool into the build image would otherwise be a second, divergent code path.
- syft scans the **OCI archive**, not the local Docker daemon — `syft oci-archive:/work/image.oci.tar`. This means **no Docker socket is mounted into the syft container**, which would otherwise hand a third-party image root-equivalent control of the daemon. It also means the SBOM describes the artifact of record rather than whatever the daemon happens to have tagged.
- The SBOM is written to `app/dist/sbom.spdx.json`, gitignored. Phase 8 uploads it to the versioned artifact bucket, satisfying design §4.2.

#### D4 — Repeatability: **attempt bit-for-bit, fall back to content-identical**

**It did not need the fallback.** See F1 and F2 — bit-for-bit holds, and the plan enforces it.

**Consequences:**

- The exit criterion is the strongest available form: **two clean builds produce the same image manifest digest**, which is the same identifier ECS deploys against and ECR stores.
- It costs a **`docker-container` buildx builder**, because the default `docker` driver's exporter silently ignores `rewrite-timestamp` (F1). `scripts/build-image.sh` creates the builder idempotently; no manual setup step is added to any runbook.
- It costs three lines of bytecode discipline in the Dockerfile (F2).
- **`BUILT_AT` is derived from the commit timestamp, not the wall clock** (see §2). A wall-clock timestamp would make every build differ and would reduce this exit criterion to a tautology dodged by pinning one variable. Deriving it from the commit makes the digest a function of the source alone — which is the actual claim being made.

#### D5 — Version source: **`app/VERSION` holding `0.1`**

**Consequences:**

- One file is the MAJOR.MINOR source for both this phase and Phase 8's buildspec, so the two cannot drift.
- The middle number is the build number: `CODEBUILD_BUILD_NUMBER` when set, **`0` locally**. A local artifact is therefore always `0.1.0-…` and can never be confused with a pipeline artifact, which starts at `0.1.1`.
- An uncommitted tree appends **`-dirty`**, so a tag can never claim to be a commit it is not. Phase 3's ECR seed must be built from a clean tree, and this is what makes that visible rather than assumed.
- The image name is **`bgd-us-east-1-api`** — the same name the ECR repository takes under the naming convention. Phase 3's seed is then a push, not a retag.

#### D6 — `image_digest`: **injected at deploy time, not build time**

The image cannot contain its own digest: the digest is the hash of the finished image, so writing it in changes it.

**Consequences:**

- Three `ARG`s only — `APP_VERSION`, `GIT_SHA`, `BUILT_AT`. `BGD_IMAGE_DIGEST` keeps its Phase 1 default of `unknown` inside the image.
- **Phases 5 and 6 must set `BGD_IMAGE_DIGEST` in the ECS task definition's container environment**, from the digest Terraform deploys. That is the correct owner: the task definition is the only place that knows which digest is actually running.
- Locally, `make run-image` passes the digest the build just recorded, so `/version` is complete on this machine too.
- Until then, a `/version` response showing `image_digest: "unknown"` means "not deployed by Terraform" — a useful signal in itself, not a gap.

#### D7 — Image tests: **shell builds, pytest asserts**

**Consequences:**

- Docker orchestration lives in `scripts/`, consistent with the makefile's own three-line rule; assertions live in pytest, where the Phase 1 suite already sets the standard.
- A new **`image` marker**, registered in `pyproject.toml` and **deselected by default** via `addopts`. `make test` therefore stays fast and needs no Docker build, which keeps the Phase 1 inner loop intact.
- `make image-test` runs the suite with **`--no-cov`**: the container is a separate process, so it exercises no in-process lines and the 90% gate would fail for a reason that has nothing to do with coverage.

#### D8 — CI: **pr-validate.yml gains a build-and-smoke job**

**Consequences:**

- A Dockerfile that only works on this Mac cannot reach `main`.
- The job needs an **arm64 runner** (`ubuntu-24.04-arm`), which follows from D1. This is **free on public repositories and billed on private ones** — `gh` is not authenticated in this working copy, so which applies here is confirmed when the PR runs.
- `pr-validate.yml`'s docstring, which currently claims a source-only role, is amended rather than left contradicting the file.
- The workflow still needs **no AWS credentials and no OIDC federation**. It builds and runs a container; it touches nothing in the account.

---

## 1. Findings recorded before this plan was written

Four probes were run on 2026-08-12 against real Docker, before this plan was written. Two of them changed it materially.

### F1 — `rewrite-timestamp` is silently ignored by the default builder

The first repeatability attempt used the ordinary `docker` driver:

```
SOURCE_DATE_EPOCH=0 docker buildx build --platform linux/arm64 \
  --output type=docker,name=probe:a,rewrite-timestamp=true --no-cache .
```

The flag was **accepted without warning** and two builds produced different images:

```
probe:a  sha256:8f31b57c3ca081610ba9fc0fb70f5c43397f6dff4612c3bbd863fc6de77fdc2d
probe:b  sha256:4a7d5d6f1b7a95e62497b10f26ca02f58338e5bd544c5ebaf21bb502534ab4b8

layer 1..4  SAME   (the base image)
layer 5     DIFF
layer 6     DIFF
```

After the F2 fix below, **every file in the image was byte-identical** — a `find | shasum -a 256` manifest over all 3,779 files diffed to zero lines — and layers 5 and 6 *still* differed. Identical content in a differently-digested layer means the difference is in the tar metadata, i.e. the timestamps `rewrite-timestamp` claims to normalise.

Repeated on a `docker-container` driver with the OCI exporter:

```
docker buildx create --name bgd-repro --driver docker-container --bootstrap
SOURCE_DATE_EPOCH=<commit epoch> docker buildx build --builder bgd-repro \
  --platform linux/arm64 --provenance=false --no-cache \
  --output type=oci,dest=image.oci.tar,rewrite-timestamp=true,name=<tag> .
```

Both builds produced the **same manifest digest**:

```
build 1  sha256:4953f5ee84dfc8ef2dcb2c160de36cffe033e6e746c3fc65ac548f3dc7135c87
build 2  sha256:4953f5ee84dfc8ef2dcb2c160de36cffe033e6e746c3fc65ac548f3dc7135c87
```

The only difference between the two OCI layouts was the `io.containerd.image.name` annotation, because the two probe builds were deliberately given different tags. Tag names are not image content.

**Consequences:**

- The build path is the **`docker-container` driver plus the OCI exporter**, created idempotently by `scripts/build-image.sh`. The default driver cannot produce the artifact of record.
- The comparison metric is the **manifest digest**, read from `index.json` — the same identifier ECR stores and ECS deploys against, not a local image ID.
- `--provenance=false`. A provenance attestation records build-time metadata and turns the output into an index carrying an extra `unknown/unknown` manifest. Neither is wanted: the first is a nondeterminism risk, and the second is a shape the ECS deploy path has no use for.
- Because the registry (`type=image`) and archive (`type=oci`) exporters share this behaviour, the digest recorded here is the digest that appears in ECR when Phase 3 pushes.

### F2 — The only content-level nondeterminism was pip's own bytecode

Before the fix, the file-by-file comparison of two builds differed on exactly one category:

```
< opt/venv/lib/python3.14/site-packages/pip/__pycache__/__init__.cpython-314.pyc
> opt/venv/lib/python3.14/site-packages/pip/__pycache__/__init__.cpython-314.pyc
< opt/venv/lib/python3.14/site-packages/pip/_internal/__pycache__/build_env.cpython-314.pyc
> …
```

Nothing else. A default `.pyc` header embeds the **source file's mtime**, and the venv's own pip is written fresh on every build, so its mtimes differ and its bytecode differs with them. The application's dependencies did not appear because they were installed with `--no-compile`; pip's bytecode was written by pip *running*, not by pip installing.

The fix is three ideas in one `RUN`:

```dockerfile
ENV PYTHONDONTWRITEBYTECODE=1
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --require-hashes --no-compile -r requirements.txt \
 && find /opt/venv -name '__pycache__' -type d -prune -exec rm -rf {} + \
 && /opt/venv/bin/python -m compileall -q --invalidation-mode unchecked-hash /opt/venv/lib
```

`--invalidation-mode unchecked-hash` is PEP 552: the `.pyc` header carries a **hash of the source** instead of its mtime and size, so identical source yields identical bytecode regardless of when it was written. `unchecked` rather than `checked` because the source cannot change inside an immutable image, so re-validating it on every import is wasted work.

**Consequence:** the image keeps precompiled bytecode — cold start is not sacrificed for reproducibility. The two goals only appeared to conflict.

**One honest caveat about F1 and F2.** Both were measured on a throwaway probe Dockerfile that installed with `--no-deps` to keep the loop short. The Dockerfile this plan ships does not, because the lock is a complete transitive closure and pip should be allowed to verify that. The measurements therefore establish the *mechanism*, not the final artifact. Task 5 re-runs the same comparison against the real Dockerfile, and that run — not this finding — is the exit criterion.

### F3 — `python:3.14.6-slim` exists and gives exact parity

```
python:3.14.6-slim  index      sha256:7bec7ddcddeff7975d6ba9b4be7dd6f6b2f55e7491539145e2978f7f97ce9144
                    linux/arm64/v8  sha256:34bf30c914ac17d2a0f7ecf94866e54380669d618ae4673672445516603ad8d7
                    linux/amd64     sha256:b921fe7e7522f828d45197a47656ec465a9b15689b27fa8e1fba2864fca5b967
                    org.opencontainers.image.version: 3.14.6-slim-trixie
                    base: debian:trixie-slim
```

For contrast, the tag the roadmap names resolves elsewhere:

```
python:3.14-slim    org.opencontainers.image.version: 3.14.7-slim-trixie
```

**Consequence:** D2 is available at no cost, and the roadmap's `python:3.14-slim` wording is amended in Task 8 rather than followed into a documented divergence.

### F4 — syft runs from a container and reports a pinned version

```
$ docker run --rm anchore/syft@sha256:678bfa565b60… version
Version:       1.51.0
GoVersion:     go1.26.3
SchemaVersion: 16.1.10
```

`anchore/syft:v1.51.0` and `anchore/syft:latest` resolve to the same index digest today; the versioned tag is what the comment records, and the digest is what the script uses.

### F5 — `httpx2` imports as `httpx2`

Phase 1 §F5 replaced `httpx` with `httpx2` for the Starlette TestClient. The image suite makes **real** HTTP calls to a container, so it imports the library directly, and the module name is not `httpx`:

```
$ app/.venv/bin/python -c "import httpx"
ModuleNotFoundError: No module named 'httpx'
$ app/.venv/bin/python -c "import httpx2; print(httpx2.__version__)"
2.10.0
```

`httpx2.Client` takes **keyword-only** arguments, so `base_url` must be passed by name.

**Consequence:** `tests/image/` imports `httpx2`, and `httpx2.ConnectError` is the exception the readiness wait catches. No new dependency is added — `httpx2` is already in `requirements-dev.txt`.

---

## 2. Global constraints

Every task's requirements implicitly include this section, in addition to Phase 1 §2, which still stands.

- **The artifact of record is `app/dist/image.oci.tar`**, built by the `bgd-repro` `docker-container` builder with the OCI exporter. The image loaded into the local Docker daemon is a convenience for running and testing, not the thing whose digest is quoted.
- **`SOURCE_DATE_EPOCH` and `BUILT_AT` both derive from the last commit**, never from the wall clock:
  ```bash
  SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
  BUILT_AT="$(TZ=UTC git log -1 --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format=%cd)"
  ```
  `git` does the formatting because BSD `date` and GNU `date` disagree on how to render an epoch, and this repository runs on both (macOS locally, Linux in CI and CodeBuild).
- **The base image is referenced by digest exactly once**, through a global `ARG` consumed by both `FROM` lines, so the two stages cannot drift apart.
- **No `latest` tag is ever produced**, per design §4.1.
- **The runtime stage runs as a numeric UID**, `10001:10001`. See §3.1 for why no user is created.
- **Nothing writes to `app/dist/`** except the build, SBOM and repeatability scripts, and the directory is gitignored.
- **`make test` behaviour is unchanged.** The `image` marker is deselected by default; a contributor who never runs Docker sees exactly the Phase 1 experience.
- **TDD.** The image suite is written and watched to fail before the Dockerfile exists. Test commits precede implementation commits (roadmap §2).

### 2.1 Two things this phase must not accidentally break

**The 90% coverage gate.** It is enforced by `fail_under` in `pyproject.toml` and applies to whatever pytest run invokes coverage. Adding `tests/image/` under `testpaths` is safe only because the marker deselects it by default and `make image-test` passes `--no-cov`.

**`--strict-markers`.** Phase 1 turned it on. An unregistered `@pytest.mark.image` is therefore an error, not a warning, so the marker must be registered in `pyproject.toml` in the same commit that first uses it.

---

## 3. File structure

```
app/
  Dockerfile                        NEW — two stages, digest-pinned, non-root
  .dockerignore                     NEW — keeps .venv, tests and .git out of the context
  VERSION                           NEW — "0.1", the MAJOR.MINOR source
  dist/                             NEW — gitignored build outputs:
                                      image.oci.tar      the artifact of record
                                      image-digest.txt   its manifest digest
                                      image-ref.txt      the local tag, for the test suite
                                      sbom.spdx.json     the SBOM
  docker-compose.yml                MODIFIED — gains the `api` service Phase 1 promised
  pyproject.toml                    MODIFIED — `image` marker, default deselection, ruff ignores
  tests/
    image/                          NEW
      __init__.py
      conftest.py                   starts the container, waits for /health, yields a base URL
      test_image_endpoints.py       every endpoint, over real HTTP, against the real image
      test_image_metadata.py        /version reports the injected build identity
      test_image_hygiene.py         non-root, port, env, and a digest-pinned FROM
scripts/
  build-image.sh                    NEW — the canonical build; writes app/dist/
  generate-sbom.sh                  NEW — pinned syft against the OCI archive
  verify-image-repeatability.sh     NEW — two clean builds, one digest comparison
  run-image.sh                      NEW — run the built image against DynamoDB Local
  README.md                         MODIFIED — the four new scripts
.github/workflows/
  pr-validate.yml                   MODIFIED — arm64 build-and-smoke job
.gitignore                          MODIFIED — app/dist/
makefile                            MODIFIED — build, sbom, image-verify, image-test, run-image
docs/phases/phase2/
  2026-08-12-phase-02-implementation-plan.md   this document
  2026-08-12-local-verification.md             NEW — Task 8's completion record
```

### 3.1 Why a numeric UID and no `useradd`

`useradd` writes an `/etc/shadow` entry whose third field is the **number of days since the epoch on which the password was last changed**. That value increments once per day, so an image built today and an image built tomorrow from identical source would differ — and the failure would appear as a mysterious, intermittent break in the D4 exit criterion that reproduces only across a midnight boundary.

A numeric `USER 10001:10001` needs no account and no writes to `/etc/passwd`, `/etc/group` or `/etc/shadow`. The cost is that `ps` inside the container shows a bare UID instead of a name, which nothing in this design reads. This is the same trade-off distroless images make, for the same reason.

### 3.2 Why there is no `HEALTHCHECK` instruction

Fargate does not act on a Docker `HEALTHCHECK`. Container health is declared in the **ECS task definition**, which Terraform owns in Phases 5 and 6, and endpoint health is polled by the **ALB target group**, which Terraform also owns. A `HEALTHCHECK` here would be a third, unread declaration of the same intent, and the first place someone looks when the other two disagree.

### 3.3 Why the container reaches DynamoDB through `host.docker.internal`

The image suite runs the API in a container while DynamoDB Local runs in its own container with port 8000 published on the host. `localhost` inside the API container is the API container, so the tests pass `--add-host=host.docker.internal:host-gateway` to `docker run` and point `BGD_DYNAMODB_ENDPOINT_URL` at it.

That flag is what makes the same command work in CI: `host.docker.internal` resolves natively on Docker Desktop, and `host-gateway` is what makes it resolve on a Linux runner. The alternative — a dedicated Docker network shared with DynamoDB Local — would duplicate what `docker-compose.yml` already expresses.

---

## Task 1: Build inputs — version, context and ignore rules

Nothing here builds anything. It establishes the three inputs every later task reads, and asserts the two contracts that would fail silently.

**Files:**
- Create: `app/VERSION`, `app/.dockerignore`
- Create: `app/tests/unit/test_build_inputs.py`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `app/VERSION` containing `0.1`; a build context that excludes `.venv`, `tests`, `dist` and `__pycache__`.

- [ ] **Step 1: Write the failing test**

`app/tests/unit/test_build_inputs.py`:

```python
"""The inputs the image build reads, asserted rather than assumed.

Both contracts here fail silently if broken. A malformed VERSION produces a
nonsense image tag that still pushes; a .dockerignore that stops excluding
app/.venv silently ships a 400 MB host virtualenv built for macOS into a Linux
image, where it would shadow /opt/venv on PYTHONPATH.
"""

import re
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[2]

MAJOR_MINOR = re.compile(r"^\d+\.\d+$")


def _dockerignore_patterns() -> set[str]:
    lines = (APP_ROOT / ".dockerignore").read_text().splitlines()
    return {line.strip() for line in lines if line.strip() and not line.startswith("#")}


def test_version_is_major_minor_only() -> None:
    """The patch position is the build number, supplied at build time."""
    version = (APP_ROOT / "VERSION").read_text().strip()
    assert MAJOR_MINOR.match(version), f"VERSION must be MAJOR.MINOR, got {version!r}"


def test_dockerignore_excludes_the_host_virtualenv() -> None:
    assert ".venv" in _dockerignore_patterns()


def test_dockerignore_excludes_tests_and_build_output() -> None:
    patterns = _dockerignore_patterns()
    for expected in ("tests", "dist", "__pycache__"):
        assert expected in patterns, f".dockerignore must exclude {expected}"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/unit/test_build_inputs.py --no-cov -q`
Expected: FAIL — `FileNotFoundError` on `app/VERSION`.

- [ ] **Step 3: Write `app/VERSION`**

```
0.1
```

A single line, no trailing prose. Phase 8's buildspec reads this file with `cat`.

- [ ] **Step 4: Write `app/.dockerignore`**

```
# Keep the build context to what the image actually needs: src/ and the two
# requirements files. Everything else here is either useless in the image or
# actively harmful in it.
#
# .venv is the harmful one. It is a macOS-arm64 virtualenv built by
# scripts/create-venv.sh; copied into a Linux image it would be several hundred
# megabytes of unusable binaries, and its site-packages would sit on the same
# PYTHONPATH as the one the builder stage produces.

.venv
tests
dist
__pycache__
*.pyc
.pytest_cache
.ruff_cache
.coverage
.env
docker-compose.yml
README.md
```

> `.git` is not listed because the context root is `app/`, which contains no
> `.git`. The repository's `.git` is one level up and never enters the context.

- [ ] **Step 5: Add `app/dist/` to `.gitignore`**

Append to the existing "Local scratch" block at the end of `.gitignore`:

```
# Phase 2 build outputs: the OCI archive, its digest, the local image ref and
# the SBOM. All are regenerated by `make build` and `make sbom`; Phase 8 keeps
# the durable copies in the versioned artifact bucket.
app/dist/
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd app && ../app/.venv/bin/python -m pytest tests/unit/test_build_inputs.py --no-cov -q`
Expected: 3 passed.

- [ ] **Step 7: Commit**

```bash
git add app/VERSION app/.dockerignore app/tests/unit/test_build_inputs.py .gitignore
git commit -m "build: declare the image build inputs and assert their contracts

VERSION carries MAJOR.MINOR only; the build number occupies the patch position
and comes from CODEBUILD_BUILD_NUMBER, or 0 locally. Both contracts asserted
because both fail silently."
```

---

## Task 2: The image test suite, written first

The suite is written against an image that does not exist yet, so every test fails for the right reason: there is nothing to run.

**Files:**
- Create: `app/tests/image/__init__.py`, `conftest.py`, `test_image_endpoints.py`, `test_image_metadata.py`, `test_image_hygiene.py`
- Modify: `app/pyproject.toml`

**Interfaces:**
- Consumes: `app/dist/image-ref.txt`, written by Task 3's build script.
- Produces: the `image` pytest marker; a `container` fixture yielding a base URL.

- [ ] **Step 1: Register the marker and deselect it by default**

In `app/pyproject.toml`, amend `[tool.pytest.ini_options]`:

```toml
addopts = "-q --strict-markers --strict-config --cov --cov-report=term-missing -m 'not image'"
markers = [
    "image: runs against the built container image; needs docker and `make build`",
]
```

`--strict-markers` is already on (Phase 1), so registering the marker is mandatory, not tidy. The `-m 'not image'` in `addopts` is what keeps `make test` docker-free; `make image-test` overrides it with an explicit `-m image`.

Add to `[tool.ruff.lint.per-file-ignores]`:

```toml
# S603/S607 flag subprocess calls with a non-absolute program name. Driving
# `docker` by name is the entire job of this suite, and pinning an absolute
# path would break between macOS and the CI runner.
"tests/image/**" = ["S101", "S603", "S607"]
```

- [ ] **Step 2: Write `app/tests/image/conftest.py`**

```python
"""Fixtures for the image suite.

Everything here talks to a real container over real HTTP. Nothing imports bgd:
the point of this suite is to test the artifact, and importing the source would
quietly test the source instead.

The container reaches DynamoDB Local through host.docker.internal rather than
localhost, because localhost inside the container is the container. The
--add-host=host.docker.internal:host-gateway flag is what makes that name
resolve on a Linux CI runner; on Docker Desktop it already resolves and the
flag is harmless.
"""

import json
import subprocess
import time
from collections.abc import Iterator
from pathlib import Path

import httpx2
import pytest

APP_ROOT = Path(__file__).resolve().parents[2]
DIST = APP_ROOT / "dist"

CONTAINER_PORT = 8080
READY_TIMEOUT_SECONDS = 30

# No module-level `pytestmark` here: a conftest.py is not a test module, and a
# pytestmark set in one does not mark the tests it serves. Each test module in
# this directory declares the marker itself.


def _read_artifact(name: str) -> str:
    path = DIST / name
    if not path.exists():
        pytest.fail(f"{path} is missing — run `make build` first")
    return path.read_text().strip()


@pytest.fixture(scope="session")
def image_ref() -> str:
    """The local tag of the image under test, recorded by build-image.sh."""
    return _read_artifact("image-ref.txt")


@pytest.fixture(scope="session")
def image_config(image_ref: str) -> dict:
    """`docker image inspect`'s Config block, for the hygiene assertions."""
    raw = subprocess.run(
        ["docker", "image", "inspect", image_ref, "--format", "{{json .Config}}"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return json.loads(raw)


@pytest.fixture(scope="session")
def container(image_ref: str) -> Iterator[str]:
    """Run the image, wait for /health, yield its base URL, then remove it.

    -P publishes the exposed port on a random free host port, so a developer
    already running `make run-local` on 8080 does not collide with this suite.
    """
    container_id = subprocess.run(
        [
            "docker", "run", "--rm", "--detach",
            "--publish-all",
            "--add-host", "host.docker.internal:host-gateway",
            "--env", "BGD_ENVIRONMENT=test",
            "--env", "BGD_DYNAMODB_ENDPOINT_URL=http://host.docker.internal:8000",
            "--env", "BGD_ACCOUNTS_TABLE=bgd-us-east-1-local-accounts",
            "--env", "BGD_TRANSACTIONS_TABLE=bgd-us-east-1-local-transactions",
            image_ref,
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()

    try:
        port = subprocess.run(
            ["docker", "port", container_id, f"{CONTAINER_PORT}/tcp"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip().splitlines()[0].rsplit(":", 1)[1]

        base_url = f"http://127.0.0.1:{port}"
        _wait_for_health(base_url, container_id)
        yield base_url
    finally:
        subprocess.run(["docker", "rm", "--force", container_id], capture_output=True)


def _wait_for_health(base_url: str, container_id: str) -> None:
    """Poll /health until the process is serving, or fail with the logs.

    A container that dies on startup would otherwise present as a connection
    error thirty seconds later, with the actual traceback discarded.
    """
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            if httpx2.get(f"{base_url}/health", timeout=1.0).status_code == 200:
                return
        except httpx2.ConnectError:
            pass
        time.sleep(0.25)

    logs = subprocess.run(
        ["docker", "logs", container_id], capture_output=True, text=True
    )
    pytest.fail(
        f"container never served /health within {READY_TIMEOUT_SECONDS}s\n"
        f"--- stdout ---\n{logs.stdout}\n--- stderr ---\n{logs.stderr}"
    )


@pytest.fixture
def client(container: str) -> Iterator[httpx2.Client]:
    with httpx2.Client(base_url=container, timeout=10.0) as http_client:
        yield http_client
```

- [ ] **Step 3: Write `app/tests/image/test_image_endpoints.py`**

```python
"""Every endpoint, against the real image, over real HTTP.

tests/api/ already covers these against an in-process app and an in-memory
fake. This suite answers a different question: does the packaged artifact —
this interpreter, this virtualenv, this PYTHONPATH, this unprivileged UID —
actually serve them.
"""

import uuid

import httpx2
import pytest

pytestmark = pytest.mark.image


def test_health_is_alive(client: httpx2.Client) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_ready_reports_dynamodb_reachable(client: httpx2.Client) -> None:
    """Proves the container's egress to DynamoDB Local, not just its liveness."""
    response = client.get("/ready")
    assert response.status_code == 200, response.text
    assert response.json()["checks"]["dynamodb"] == "ok"


def test_an_account_can_be_created_and_read_back(client: httpx2.Client) -> None:
    created = client.post(
        "/api/accounts",
        json={"owner_name": "Container Smoke", "currency": "EUR"},
    )
    assert created.status_code == 201, created.text
    account_id = created.json()["account_id"]

    fetched = client.get(f"/api/accounts/{account_id}")
    assert fetched.status_code == 200
    assert fetched.json()["owner_name"] == "Container Smoke"


def test_a_transaction_moves_the_balance(client: httpx2.Client) -> None:
    account_id = client.post(
        "/api/accounts", json={"owner_name": "Ledger Smoke", "currency": "EUR"}
    ).json()["account_id"]

    posted = client.post(
        "/api/transactions",
        json={
            "account_id": account_id,
            "type": "CREDIT",
            "amount_minor": 5000,
            "currency": "EUR",
            "idempotency_key": uuid.uuid4().hex,
        },
    )
    assert posted.status_code == 201, posted.text

    balance = client.get(f"/api/accounts/{account_id}").json()["balance_minor"]
    assert balance == 5000


def test_a_missing_account_is_a_problem_document(client: httpx2.Client) -> None:
    """The RFC 9457 envelope survives packaging, headers included."""
    response = client.get("/api/accounts/acc_does_not_exist")
    assert response.status_code == 404
    assert response.headers["content-type"].startswith("application/problem+json")
    assert response.json()["code"] == "ACCOUNT_NOT_FOUND"
```

> Every field name above was checked against `app/src/bgd/api/schemas.py` before this plan was written: `AccountCreateRequest` and `TransactionCreateRequest` both set `extra="forbid"`, so a stray field is a 422 rather than a silent no-op, and `AccountResponse.balance_minor` is the field the balance assertion reads. Phase 2 changes no application source — if one of these fails, the test is wrong, not the service.

- [ ] **Step 4: Write `app/tests/image/test_image_metadata.py`**

```python
"""/version must report what the build injected.

This is the endpoint Phase 6 curls against the :443 and :8443 listeners during
a blue/green shift, where two different git_sha values are the direct proof of
which colour serves whom. If the build arguments do not reach it, that evidence
does not exist.
"""

from pathlib import Path

import httpx2
import pytest

APP_ROOT = Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.image


def test_version_reports_the_injected_build_identity(client: httpx2.Client) -> None:
    body = client.get("/version").json()
    expected_prefix = (APP_ROOT / "VERSION").read_text().strip()

    assert body["version"].startswith(f"{expected_prefix}."), body["version"]
    assert body["git_sha"] not in ("", "unknown"), "GIT_SHA never reached the image"
    assert body["built_at"].endswith("Z"), body["built_at"]


def test_image_digest_is_unknown_until_terraform_injects_it(
    client: httpx2.Client,
) -> None:
    """An image cannot contain its own digest — the digest is its hash.

    Phases 5 and 6 set BGD_IMAGE_DIGEST in the ECS task definition, which is
    the only place that knows which digest is actually deployed. This asserts
    the deliberate gap so that closing it wrongly, at build time, is a red test.
    """
    assert client.get("/version").json()["image_digest"] == "unknown"
```

- [ ] **Step 5: Write `app/tests/image/test_image_hygiene.py`**

```python
"""Properties of the image itself, independent of what it serves."""

import re
import subprocess
from pathlib import Path

import pytest

APP_ROOT = Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.image

DIGEST_PINNED_FROM = re.compile(r"^FROM \S+@sha256:[0-9a-f]{64}", re.MULTILINE)


def test_the_image_does_not_run_as_root(image_config: dict) -> None:
    assert image_config["User"] == "10001:10001"


def test_the_running_process_is_not_root(image_ref: str) -> None:
    """Config.User is a declaration; this is the observation."""
    uid = subprocess.run(
        ["docker", "run", "--rm", "--entrypoint", "id", image_ref, "-u"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    assert uid == "10001"


def test_the_application_port_is_exposed(image_config: dict) -> None:
    assert "8080/tcp" in image_config["ExposedPorts"]


def test_the_package_is_reachable_without_being_installed(image_config: dict) -> None:
    """The package is never pip-installed; PYTHONPATH is how it is found."""
    assert "PYTHONPATH=/app/src" in image_config["Env"]


def test_the_base_image_is_pinned_by_digest() -> None:
    dockerfile = (APP_ROOT / "Dockerfile").read_text()
    assert "ARG BASE_IMAGE=" in dockerfile
    assert re.search(r"ARG BASE_IMAGE=\S+@sha256:[0-9a-f]{64}", dockerfile), (
        "the base image must be pinned by digest, not by tag (design §4.1)"
    )
    assert ":latest" not in dockerfile
```

- [ ] **Step 6: Run the suite to verify it fails**

Run: `cd app && ../app/.venv/bin/python -m pytest -m image --no-cov -q`
Expected: every test fails or errors, and the failure names the missing artifact — `app/dist/image-ref.txt is missing — run `make build` first`. The `test_the_base_image_is_pinned_by_digest` case fails on the missing `Dockerfile`.

- [ ] **Step 7: Confirm the default run is unaffected**

Run: `make test`
Expected: the Phase 1 suite passes exactly as before, coverage gate green, **no Docker build attempted**. This is the check that Step 1's deselection works.

- [ ] **Step 8: Commit**

```bash
git add app/tests/image app/pyproject.toml
git commit -m "test(image): assert the container's behaviour before it exists

An image marker, deselected by default, so `make test` stays fast and needs no
docker. The suite talks to a real container over HTTP and never imports bgd —
importing the source would quietly test the source instead of the artifact."
```

---

## Task 3: The Dockerfile and the canonical build

Makes Task 2 green.

**Files:**
- Create: `app/Dockerfile`, `scripts/build-image.sh`
- Modify: `makefile`

**Interfaces:**
- Produces: `app/dist/image.oci.tar`, `image-digest.txt`, `image-ref.txt`; the `make build` target.

- [ ] **Step 1: Write `app/Dockerfile`**

```dockerfile
# The application image: two stages, one digest-pinned base, non-root at runtime.
#
# Reproducibility is a stated requirement (design §4.1), so this file is written
# to be a pure function of its inputs. Two clean builds of the same commit
# produce the same manifest digest — see docs/phases/phase2 §F1 and §F2 for the
# measurements, and note that this only holds through scripts/build-image.sh:
# the default buildx driver silently ignores rewrite-timestamp.
#
# Base pinned by index digest. Recorded 2026-08-12 — re-record with:
#   docker buildx imagetools inspect python:3.14.6-slim --format '{{.Manifest.Digest}}'
# 3.14.6 exactly, not 3.14-slim: it matches .python-version, so the container,
# the local virtualenv and CI all run the same interpreter (design §1.6).
ARG BASE_IMAGE=python:3.14.6-slim@sha256:7bec7ddcddeff7975d6ba9b4be7dd6f6b2f55e7491539145e2978f7f97ce9144

# ---------------------------------------------------------------------------
# builder — resolve the virtualenv, and only the virtualenv
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build
COPY requirements.txt ./

# --require-hashes is the second half of design §4.1's reproducibility pair:
# pip-compile --generate-hashes wrote the locks, and this refuses to install
# anything whose hash does not match.
#
# The three bytecode steps exist because a default .pyc header embeds the
# source file's mtime, and pip's own bytecode is therefore different on every
# build. --no-compile suppresses it during install, the find removes what pip
# wrote while running, and compileall regenerates it with PEP 552 hash-based
# invalidation — same source, same bytes, whenever it is built. Precompiling
# rather than shipping none of it keeps cold start fast.
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --require-hashes --no-compile -r requirements.txt \
 && find /opt/venv -name '__pycache__' -type d -prune -exec rm -rf {} + \
 && /opt/venv/bin/python -m compileall -q --invalidation-mode unchecked-hash /opt/venv/lib

# ---------------------------------------------------------------------------
# runtime — the shipped image
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime

# Build identity, surfaced by /version. BGD_IMAGE_DIGEST is deliberately absent:
# an image cannot carry its own digest, because the digest is its hash. Phases 5
# and 6 set it in the ECS task definition, which is the only place that knows
# which digest is actually deployed.
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG BUILT_AT=unknown

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/app/src \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    BGD_APP_VERSION=${APP_VERSION} \
    BGD_GIT_SHA=${GIT_SHA} \
    BGD_BUILT_AT=${BUILT_AT}

COPY --from=builder /opt/venv /opt/venv
COPY src/ /app/src/

# A numeric UID, with no useradd. useradd writes an /etc/shadow entry recording
# the day it ran, which would make two otherwise identical builds differ across
# a midnight boundary. See §3.1 of the Phase 2 plan.
USER 10001:10001

# Documentation plus the port `docker run --publish-all` picks up. The ALB
# target group and the ECS task definition declare it for real, in Terraform.
EXPOSE 8080

# No HEALTHCHECK: Fargate does not act on one. Container health belongs to the
# task definition and endpoint health to the ALB target group — see §3.2.
CMD ["python", "-m", "uvicorn", "bgd.api.main:create_app", \
     "--factory", "--host", "0.0.0.0", "--port", "8080"]
```

> No `# syntax=` directive. It would pull a frontend image by tag on every build — an unpinned dependency in the middle of a file whose whole subject is pinning. The daemon's built-in BuildKit frontend supplies everything used here.

- [ ] **Step 2: Write `scripts/build-image.sh`**

```bash
#!/usr/bin/env bash
#
# Build the application image reproducibly and record what was built.
#
# The artifact of record is the OCI archive, not the image in the local Docker
# daemon. Only the OCI exporter honours rewrite-timestamp; the docker exporter
# accepts the option and ignores it, producing a different digest every time
# (Phase 2 §F1). The daemon copy exists so `make run-image` and the image test
# suite have something to run, and it is a convenience, not the artifact.
#
# Both timestamps come from the last commit rather than the wall clock, which
# is what makes the digest a function of the source. git does the formatting
# because BSD date and GNU date disagree about rendering an epoch, and this
# runs on macOS locally and Linux in CI.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker
require_cmd git
require_cmd jq

ROOT="$(repo_root)"
APP="$ROOT/app"
DIST="$APP/dist"
BUILDER="bgd-repro"
PLATFORM="linux/arm64"
IMAGE_NAME="bgd-us-east-1-api"

MAJOR_MINOR="$(tr -d '[:space:]' <"$APP/VERSION")"
BUILD_NUMBER="${CODEBUILD_BUILD_NUMBER:-0}"
APP_VERSION="${MAJOR_MINOR}.${BUILD_NUMBER}"

GIT_SHA="$(git -C "$ROOT" rev-parse --short=7 HEAD)"
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  GIT_SHA="${GIT_SHA}-dirty"
  warn "working tree is dirty — tagging as ${GIT_SHA}"
fi

SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct)"
BUILT_AT="$(TZ=UTC git -C "$ROOT" log -1 --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format=%cd)"
IMAGE_REF="${IMAGE_NAME}:${APP_VERSION}-${GIT_SHA}"

export SOURCE_DATE_EPOCH

# The docker-container driver is required, not preferred: the default driver's
# exporter ignores rewrite-timestamp. Creating it is idempotent, so no runbook
# gains a manual setup step.
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  info "creating the $BUILDER buildx builder"
  docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null
fi

mkdir -p "$DIST"

info "building $IMAGE_REF"
dim "  platform           $PLATFORM"
dim "  SOURCE_DATE_EPOCH  $SOURCE_DATE_EPOCH ($BUILT_AT)"

# Two exporters, one build. The OCI archive is the artifact; the docker export
# loads the same content into the daemon for running and testing.
#
# --provenance=false: a provenance attestation records build-time metadata and
# turns the output into an index carrying an extra unknown/unknown manifest.
# Neither is wanted here.
docker buildx build \
  --builder "$BUILDER" \
  --platform "$PLATFORM" \
  --no-cache \
  --provenance=false \
  --build-arg "APP_VERSION=$APP_VERSION" \
  --build-arg "GIT_SHA=$GIT_SHA" \
  --build-arg "BUILT_AT=$BUILT_AT" \
  --output "type=oci,dest=$DIST/image.oci.tar,rewrite-timestamp=true,name=$IMAGE_REF" \
  --output "type=docker,name=$IMAGE_REF" \
  "$APP"

DIGEST="$(tar -xOf "$DIST/image.oci.tar" index.json | jq -r '.manifests[0].digest')"

printf '%s\n' "$DIGEST" >"$DIST/image-digest.txt"
printf '%s\n' "$IMAGE_REF" >"$DIST/image-ref.txt"

ok "built $IMAGE_REF"
dim "  digest    $DIGEST"
dim "  archive   ${DIST#"$ROOT"/}/image.oci.tar"
```

Then `chmod +x scripts/build-image.sh`.

> **If `--output` twice is rejected by this buildx version**, split it into two invocations: the second reuses the first's cache and costs about a second. Record which was needed in the Task 8 verification document — do not silently drop the OCI export, which is the artifact whose digest is quoted.

- [ ] **Step 3: Add the `build` and `image-test` targets**

In `makefile`, after the Phase 1 block:

```make
# ---------------------------------------------------------------------------
# Phase 2 — container image
#
# The build itself lives in scripts/, because reproducibility needs a specific
# buildx driver, two exporters and timestamps derived from git — none of which
# fits a three-line recipe. See docs/phases/phase2/…-implementation-plan.md.
# ---------------------------------------------------------------------------

.PHONY: build
build: ## Build the container image reproducibly and record its digest
	@./scripts/build-image.sh

# --no-cov: the container is a separate process, so it executes none of the
# lines coverage measures, and the 90% gate would fail for an unrelated reason.
.PHONY: image-test
image-test: deps build local-tables ## Run the image suite against the built container
	@cd $(APP_DIR) && $(PY) -m pytest -m image --no-cov
```

Delete this line from the `# PLANNED:` block:

```
# PLANNED: build          Build the container image (Phase 2)
```

- [ ] **Step 4: Build the image**

Run: `make build`
Expected: a successful build; `app/dist/` holds `image.oci.tar`, `image-digest.txt` and `image-ref.txt`; the printed digest starts `sha256:`.

- [ ] **Step 5: Run the image suite**

Run: `make image-test`
Expected: every test in `tests/image/` passes. If `/ready` fails, DynamoDB Local is not reachable from inside the container — check that `make local-up` ran and that `host.docker.internal` resolves.

- [ ] **Step 6: Confirm the default suite is still green**

Run: `make test && make lint`
Expected: both green.

- [ ] **Step 7: Commit**

```bash
git add app/Dockerfile scripts/build-image.sh makefile
git commit -m "feat(image): add the reproducible multi-stage image

Two stages on a digest-pinned python:3.14.6-slim, non-root at a numeric UID,
hash-verified dependencies and PEP 552 hash-based bytecode. Timestamps derive
from the commit, not the clock, so the manifest digest is a function of source."
```

---

## Task 4: SBOM

**Files:**
- Create: `scripts/generate-sbom.sh`
- Modify: `makefile`

- [ ] **Step 1: Write `scripts/generate-sbom.sh`**

```bash
#!/usr/bin/env bash
#
# Generate the image's SBOM with syft, per design §4.1.
#
# syft runs from a digest-pinned container rather than a host install: nothing
# to install, nothing for verify-tools.sh to check, and the identical command
# works in Phase 8's CodeBuild.
#
# It reads the OCI archive, not the Docker daemon. That keeps the daemon socket
# out of a third-party container — mounting it would hand that image
# root-equivalent control of this machine — and it describes the artifact of
# record rather than whatever the daemon happens to have tagged.
#
# Pinned 2026-08-12, anchore/syft:v1.51.0. Re-record with:
#   docker buildx imagetools inspect anchore/syft:v1.51.0 --format '{{.Manifest.Digest}}'

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker

ROOT="$(repo_root)"
DIST="$ROOT/app/dist"
SYFT="anchore/syft@sha256:678bfa565b60f747aac0f8e964fe5588a24445b8d0a480e91f6efd70020dfbb0"
OUTPUT="$DIST/sbom.spdx.json"

[[ -f "$DIST/image.oci.tar" ]] || die "no image archive — run 'make build' first"

info "generating the SBOM with syft"
docker run --rm \
  --volume "$DIST:/work:ro" \
  "$SYFT" \
  "oci-archive:/work/image.oci.tar" \
  --output spdx-json >"$OUTPUT"

count="$(grep -c '"SPDXID": "SPDXRef-Package' "$OUTPUT" || true)"
ok "SBOM written — $count packages"
dim "  ${OUTPUT#"$ROOT"/}"
dim "  image digest $(cat "$DIST/image-digest.txt" 2>/dev/null || echo unknown)"
```

Then `chmod +x scripts/generate-sbom.sh`.

- [ ] **Step 2: Add the `sbom` target**

```make
.PHONY: sbom
sbom: build ## Generate the SBOM for the built image with syft
	@./scripts/generate-sbom.sh
```

Delete from the `# PLANNED:` block:

```
# PLANNED: sbom           Generate the SBOM with syft (Phase 2)
```

- [ ] **Step 3: Generate and inspect it**

Run: `make sbom`
Expected: `app/dist/sbom.spdx.json` exists and the package count is greater than the 27 pins in `requirements.txt`, because the SBOM also covers the Debian packages in the base image.

Spot-check that the locked application dependencies are present and at the locked versions:

```bash
jq -r '.packages[]
       | select(.name | ascii_downcase
                | test("^(fastapi|boto3|pydantic|uvicorn|starlette)$"))
       | "\(.name) \(.versionInfo)"' app/dist/sbom.spdx.json | sort
```

> Compare the versions against `app/requirements.txt`. A mismatch means the image did not install the lock, which is a genuine finding rather than a reporting quirk — and one that `--require-hashes` should have made impossible, so investigate rather than adjust the expectation.

- [ ] **Step 4: Commit**

```bash
git add scripts/generate-sbom.sh makefile
git commit -m "feat(image): generate an SPDX SBOM with a digest-pinned syft

syft reads the OCI archive rather than the docker socket, so no third-party
container is handed control of the daemon and the SBOM describes the artifact
of record."
```

---

## Task 5: The repeatability proof

The claim this phase exists to make, turned into a command anyone can run.

**Files:**
- Create: `scripts/verify-image-repeatability.sh`
- Modify: `makefile`

- [ ] **Step 1: Write `scripts/verify-image-repeatability.sh`**

```bash
#!/usr/bin/env bash
#
# Prove that the same source produces the same image.
#
# Two clean builds, identical inputs, compared on the manifest digest — the
# identifier ECR stores and ECS deploys against, not a local image ID. Both
# builds use the same tag, because the tag appears in the OCI index annotations
# and a differing name would show up as a difference that is not image content.
#
# --no-cache on both, or the second build would return the first one's layers
# and prove only that the cache works.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker
require_cmd git
require_cmd jq

ROOT="$(repo_root)"
APP="$ROOT/app"
WORK="$APP/dist/repeatability"
BUILDER="bgd-repro"

MAJOR_MINOR="$(tr -d '[:space:]' <"$APP/VERSION")"
APP_VERSION="${MAJOR_MINOR}.${CODEBUILD_BUILD_NUMBER:-0}"
GIT_SHA="$(git -C "$ROOT" rev-parse --short=7 HEAD)"
SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct)"
BUILT_AT="$(TZ=UTC git -C "$ROOT" log -1 --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format=%cd)"
IMAGE_REF="bgd-us-east-1-api:${APP_VERSION}-${GIT_SHA}"

export SOURCE_DATE_EPOCH

if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null
fi

rm -rf "$WORK"
mkdir -p "$WORK"

build_once() {
  local label="$1"
  info "build $label of 2"
  docker buildx build \
    --builder "$BUILDER" \
    --platform linux/arm64 \
    --no-cache \
    --provenance=false \
    --build-arg "APP_VERSION=$APP_VERSION" \
    --build-arg "GIT_SHA=$GIT_SHA" \
    --build-arg "BUILT_AT=$BUILT_AT" \
    --output "type=oci,dest=$WORK/$label.tar,rewrite-timestamp=true,name=$IMAGE_REF" \
    "$APP" >/dev/null 2>&1
  tar -xOf "$WORK/$label.tar" index.json | jq -r '.manifests[0].digest'
}

first="$(build_once one)"
second="$(build_once two)"

printf '\n'
dim "  build 1  $first"
dim "  build 2  $second"
printf '\n'

if [[ "$first" == "$second" ]]; then
  ok "reproducible — both builds produced the same manifest digest"
  rm -rf "$WORK"
  exit 0
fi

fail "NOT reproducible — the two builds differ"
dim "  the archives are kept in ${WORK#"$ROOT"/} for diagnosis:"
dim "    tar -xf $WORK/one.tar -C <dir> && tar -xf $WORK/two.tar -C <dir2> && diff -r <dir> <dir2>"
exit 1
```

Then `chmod +x scripts/verify-image-repeatability.sh`.

- [ ] **Step 2: Add the `image-verify` target**

```make
.PHONY: image-verify
image-verify: ## Prove two clean builds produce the same image digest
	@./scripts/verify-image-repeatability.sh
```

- [ ] **Step 3: Run it**

Run: `make image-verify`
Expected: two digests printed, identical, and `reproducible — both builds produced the same manifest digest`. Roughly two to three minutes, since neither build may use the cache.

- [ ] **Step 4: Prove the check can fail**

A check that has never failed is not known to work. Temporarily append a line to `app/src/bgd/__init__.py`, run `make image-verify`, and confirm the digests still match each other (the source changed, but identically for both builds). Then, in a scratch copy of the script only, replace one build's `--build-arg BUILT_AT=…` with `$(date -u +%Y-%m-%dT%H:%M:%SZ)` and confirm the digests **differ**.

Revert both. Record the observed failing digests in the Task 8 document — they are the evidence that the comparison is real.

- [ ] **Step 5: Commit**

```bash
git add scripts/verify-image-repeatability.sh makefile
git commit -m "test(image): prove two clean builds produce one digest

Compares the manifest digest — what ECR stores and ECS deploys against — not a
local image ID. Both builds run --no-cache, or the second would prove only that
the cache works."
```

---

## Task 6: Local development paths

The two conveniences that make the image usable day to day, including the `api` service `docker-compose.yml` has promised since Phase 1.

**Files:**
- Create: `scripts/run-image.sh`
- Modify: `app/docker-compose.yml`, `makefile`, `app/README.md`, `scripts/README.md`

- [ ] **Step 1: Write `scripts/run-image.sh`**

```bash
#!/usr/bin/env bash
#
# Run the built image against DynamoDB Local.
#
# The counterpart to `make run-local`, which runs the same application from the
# host virtualenv. Running both at once is fine — this publishes 8081, so the
# two do not collide and can be curled side by side.
#
# BGD_IMAGE_DIGEST is passed here because this is the local stand-in for what
# Terraform does in Phases 5 and 6: the deployer knows the digest, the image
# cannot know its own.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker

ROOT="$(repo_root)"
DIST="$ROOT/app/dist"
PORT="${PORT:-8081}"

[[ -f "$DIST/image-ref.txt" ]] || die "no image — run 'make build' first"

IMAGE_REF="$(cat "$DIST/image-ref.txt")"
DIGEST="$(cat "$DIST/image-digest.txt" 2>/dev/null || echo unknown)"

info "running $IMAGE_REF on http://localhost:$PORT"
dim "  /version will report image digest $DIGEST"

exec docker run --rm --interactive --tty \
  --publish "$PORT:8080" \
  --add-host "host.docker.internal:host-gateway" \
  --env "BGD_ENVIRONMENT=local" \
  --env "BGD_DYNAMODB_ENDPOINT_URL=http://host.docker.internal:8000" \
  --env "BGD_ACCOUNTS_TABLE=bgd-us-east-1-local-accounts" \
  --env "BGD_TRANSACTIONS_TABLE=bgd-us-east-1-local-transactions" \
  --env "BGD_IMAGE_DIGEST=$DIGEST" \
  "$IMAGE_REF"
```

Then `chmod +x scripts/run-image.sh`.

- [ ] **Step 2: Add the `api` service to `app/docker-compose.yml`**

Amend the file header, replacing the sentence that says the API runs on the host because no Dockerfile exists, and add:

```yaml
  # Phase 2. The full local stack in one command: `docker compose up`.
  #
  # A development convenience, not the artifact. compose builds with the default
  # buildx driver, which does not honour rewrite-timestamp, so the image it
  # produces is functionally identical but not digest-identical to the one
  # `make build` produces. The artifact of record always comes from make.
  #
  # Here the endpoint is the compose service name rather than
  # host.docker.internal, because both containers share a compose network.
  api:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: bgd-api
    depends_on:
      - dynamodb-local
    ports:
      - "8081:8080"
    environment:
      BGD_ENVIRONMENT: local
      BGD_DYNAMODB_ENDPOINT_URL: http://dynamodb-local:8000
      BGD_ACCOUNTS_TABLE: bgd-us-east-1-local-accounts
      BGD_TRANSACTIONS_TABLE: bgd-us-east-1-local-transactions
```

> `docker compose up` does not create the tables. Run `make local-tables` first, or `/ready` reports `unavailable` until it is run.

- [ ] **Step 3: Add the `run-image` target**

```make
.PHONY: run-image
run-image: build local-tables ## Run the built image against DynamoDB Local on :8081
	@./scripts/run-image.sh
```

- [ ] **Step 4: Update the two READMEs**

`app/README.md`: add `make build`, `make sbom`, `make image-test`, `make image-verify` and `make run-image` to the commands table, and replace the closing line — "**Phase 2** adds the multi-stage Dockerfile, digest-pinned base image and SBOM" — with a short section describing the image: two stages, `python:3.14.6-slim` by digest, arm64, non-root UID 10001, `/opt/venv` on `PATH`, `PYTHONPATH=/app/src`, and the fact that `BGD_IMAGE_DIGEST` arrives from the task definition rather than the build.

`scripts/README.md`: add the four new scripts to the table with `2` in the Phase column.

- [ ] **Step 5: Verify both paths by hand**

```bash
make run-image          # then, in another terminal:
curl -s localhost:8081/health  | jq .
curl -s localhost:8081/version | jq .
curl -s localhost:8081/ready   | jq .
```

Expected: `/version` reports the real `version`, `git_sha`, `built_at` **and** a real `image_digest` — the one `run-image.sh` passed in. That last field is the difference from `make image-test`, where it is `unknown` by design.

Then:

```bash
make local-tables
cd app && docker compose up -d && curl -s localhost:8081/health | jq .
docker compose down
```

- [ ] **Step 6: Commit**

```bash
git add scripts/run-image.sh app/docker-compose.yml makefile app/README.md scripts/README.md
git commit -m "feat(image): add the local run paths and the compose api service

run-image passes BGD_IMAGE_DIGEST, standing in locally for what the ECS task
definition does in Phases 5 and 6."
```

---

## Task 7: CI

**Files:**
- Modify: `.github/workflows/pr-validate.yml`

- [ ] **Step 1: Amend the workflow docstring**

The header currently states the workflow "lints and tests source, and touches nothing in the account". The second half stays true and the first no longer is. Amend it to say it lints and tests source **and builds and smoke-tests the container image**, and that it still needs no AWS credentials and no OIDC federation.

- [ ] **Step 2: Add the job**

```yaml
  image:
    # arm64, because the image targets linux/arm64 (Phase 2 §D1) and Fargate
    # runs it on Graviton. An x86 runner would have to emulate, which measures
    # the emulator as much as the Dockerfile.
    #
    # ubuntu-24.04-arm is free on public repositories and billed on private
    # ones. If this repository is private and that is unwanted, delete this job
    # — `make build` and `make image-verify` still prove the same things
    # locally, and Phase 8's CodeBuild proves them again on every merge.
    runs-on: ubuntu-24.04-arm

    services:
      dynamodb-local:
        image: amazon/dynamodb-local@sha256:ff89bd48ff32cd8d9be5fee8873b65b8854dc408f1afe881be6eb00247bc0dab
        ports:
          - 8000:8000

    steps:
      # fetch-depth: 0 is not needed, but the build reads the commit timestamp
      # and the short SHA, so the checkout must not be in detached-empty state.
      - uses: actions/checkout@v5

      - uses: actions/setup-python@v6
        with:
          python-version-file: .python-version
          cache: pip
          cache-dependency-path: app/requirements-dev.txt

      - name: Install hash-pinned dependencies
        working-directory: app
        run: pip install --require-hashes -r requirements-dev.txt

      # BGD_DYNAMODB_ENDPOINT_URL is mandatory, not defensive: create_tables
      # exits with an error when it is unset, deliberately, so that a stray
      # AWS_PROFILE cannot point it at a real account. Locally the value comes
      # from app/.env, which is gitignored and therefore absent on the runner.
      - name: Create the DynamoDB tables
        working-directory: app
        env:
          PYTHONPATH: src
          BGD_DYNAMODB_ENDPOINT_URL: http://localhost:8000
        run: python -m bgd.cli.create_tables

      - name: Build the image
        run: ./scripts/build-image.sh

      - name: Image suite
        working-directory: app
        run: pytest -m image --no-cov

      - name: Generate the SBOM
        run: ./scripts/generate-sbom.sh

      - name: Publish the SBOM
        uses: actions/upload-artifact@v4
        with:
          name: sbom-${{ github.sha }}
          path: app/dist/sbom.spdx.json
```

> `make image-test` is not used here: its `build` and `local-tables` prerequisites are expressed as separate, individually-reported steps, and `local-tables` would try to start a compose container the runner already provides as a service.
>
> **`make image-verify` is deliberately not run in CI.** Two uncached builds cost two to three minutes of runner time on every pull request to re-prove a property that does not change between commits. It is a local and pre-merge check; Task 8 records its result for this branch.

- [ ] **Step 3: Confirm the guard the workflow depends on**

`create_tables` refuses to run without `BGD_DYNAMODB_ENDPOINT_URL`, which is why the step above sets it explicitly. Confirm that refusal is real, because the workflow's correctness rests on it:

```bash
cd app && env -u BGD_DYNAMODB_ENDPOINT_URL PYTHONPATH=src \
  ../app/.venv/bin/python -m bgd.cli.create_tables
```

Expected: a non-zero exit with `BGD_DYNAMODB_ENDPOINT_URL is not set. Refusing to create tables against real AWS`. That guard is the reason the runner — which has no `.env`, since it is gitignored — cannot silently create tables in the real account.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/pr-validate.yml
git commit -m "ci: build and smoke-test the container image on arm64

A Dockerfile that only works on one machine can no longer reach main. Still no
AWS credentials and no OIDC federation — it builds and runs a container."
```

---

## Task 8: Verification record, document amendments, and the pull request

**Files:**
- Create: `docs/phases/phase2/2026-08-12-local-verification.md`
- Modify: `docs/2026-08-04-implementation-phase-roadmap.md`, `docs/2026-08-04-blue-green-deployment-platform-design-research.md`

- [ ] **Step 1: Write the verification record**

Following the shape of `docs/phases/phase1/2026-08-09-local-verification.md`: each exit criterion, the command that proves it, and the actual output — not a summary of the output.

Must include, as raw captured output:

- `make build` — the image reference and digest
- `make image-test` — the pass count
- `make image-verify` — **both digests**, identical
- the deliberate-failure digests from Task 5 Step 4, which prove the comparison can fail
- `make sbom` — the package count and the spot-checked versions
- `curl /version` from `make run-image`, showing all four fields populated
- `docker image inspect` showing `User` as `10001:10001`
- the final image size, from `docker images bgd-us-east-1-api`
- whether the two-`--output` build worked or had to be split (Task 3 Step 2)

- [ ] **Step 2: Amend the roadmap**

In `docs/2026-08-04-implementation-phase-roadmap.md`:

- §2 branch table: `feat/Phase2_ContainerBuild` → `feat/reproducible_container_build`, with a note in the same style as the Phase 0 amendment already there.
- §3 Phase 2: `python:3.14-slim` → `python:3.14.6-slim`, giving F3's reason.
- §3 Phase 2: add the arm64 decision and its consequence for Phases 5, 6 and 8, since a reader of the roadmap alone would otherwise not know a task definition needs `ARM64`.
- §3 Phase 5 and Phase 6: note that both task definitions must set `runtime_platform` to ARM64 and must inject `BGD_IMAGE_DIGEST`.

- [ ] **Step 3: Amend the design document**

In `docs/2026-08-04-blue-green-deployment-platform-design-research.md` §4.1, in the same "Amended in Phase N" style §5 already uses:

- the base image is `python:3.14.6-slim`, pinned by index digest, arm64
- reproducibility is proved by digest comparison, and requires the `docker-container` driver plus `rewrite-timestamp`
- SBOM by syft 1.51.0 from a digest-pinned container, reading the OCI archive
- the tag scheme's build number is `0` locally and `CODEBUILD_BUILD_NUMBER` in the pipeline, with `-dirty` on an unclean tree

- [ ] **Step 4: Full verification pass**

```bash
make lint
make test
make build
make image-test
make image-verify
make sbom
```

All six green, in this order, from a clean checkout of the branch.

- [ ] **Step 5: Commit and open the pull request**

```bash
git add docs/
git commit -m "docs: record the Phase 2 verification and amend the roadmap and design

The base image is 3.14.6 rather than 3.14-slim, the target is arm64, and the
reproducibility claim is a measured digest comparison rather than an assertion."
```

The pull request description is the exit criteria below and how each was verified, per roadmap §2. It must state plainly that **Phases 5 and 6 inherit two obligations** — `runtime_platform = ARM64` and injecting `BGD_IMAGE_DIGEST` — because that is the part of this phase most easily lost between branches.

---

## 4. Exit criteria

From roadmap §3, plus the two this plan adds.

| # | Criterion | Proved by |
|---|---|---|
| 1 | The image builds locally | `make build` |
| 2 | The container serves every endpoint | `make image-test` — `tests/image/test_image_endpoints.py` |
| 3 | `/version` reports the injected metadata | `tests/image/test_image_metadata.py`, and `curl` under `make run-image` |
| 4 | An SBOM is produced | `make sbom`, with the locked versions spot-checked against `requirements.txt` |
| 5 | **Two clean builds produce the same manifest digest** | `make image-verify`, plus the deliberate failure of Task 5 Step 4 |
| 6 | **The image does not run as root** | `tests/image/test_image_hygiene.py`, asserted both as configuration and as observed UID |

## 5. What this phase hands to Phase 3

- `app/dist/image.oci.tar` and its digest — the image ECR is seeded with, per roadmap §0's app-before-infra ordering.
- The image name `bgd-us-east-1-api`, already matching the ECR repository name, so the seed is a push rather than a retag.
- A build whose digest is a function of the commit, which is what makes "deployments reference the digest, not the tag" (design §4.1) mean something: the digest identifies a commit, not a moment.

## 6. Risks carried forward

| Risk | Handling |
|---|---|
| **A task definition left at the `X86_64` default cannot start this image** | Called out in the roadmap, the design document and the pull request description. It fails loudly at task start with an exec-format error, so it cannot ship silently. |
| **`ubuntu-24.04-arm` is billed on private repositories** | The job carries a comment saying so and how to remove it. Confirmed when the pull request first runs. |
| **The base image digest goes stale** | Expected, and the point of pinning. A patch upgrade is a deliberate commit moving `.python-version` and the base digest together; the parity claim of D2 is what makes the pair obvious. |
| **`--provenance=false` discards supply-chain attestation** | Accepted here. The SBOM is the supply-chain artefact this design commits to, and it is produced and stored. Signing and attestation are out of scope for the whole project, not just this phase. |
| **The compose `api` service builds a digest-different image** | Documented in the file itself. It is a development convenience; every command that produces an artifact of record goes through `scripts/build-image.sh`. |
