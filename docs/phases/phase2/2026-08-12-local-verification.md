# Phase 2 — Local Verification

**Date:** 2026-08-12
**Branch:** `feat/reproducible_container_build`
**Plan:** [Phase 2 implementation plan](./2026-08-12-phase-02-implementation-plan.md)
**Status:** All six exit criteria met. Six findings came out of implementation; five were defects in the plan or in the first cut of the code, and all five are fixed.

Every command below was run on this machine. The output is the evidence, not a
summary of it.

> **On the digests quoted here.** They were produced from a **dirty working
> tree**, so every tag carries `-dirty` and every digest is a digest of
> uncommitted work. Committing changes `GIT_SHA`, and with it the digest — by
> design, since the digest is a function of the source. What is being evidenced
> is the *property* (identical inputs give an identical digest), not any
> particular value.

---

## 1. Exit criteria

| # | Criterion | Result |
|---|---|---|
| 1 | The image builds locally | ✅ `bgd-us-east-1-api:0.1.0-84d4eb0-dirty`, 222 MB |
| 2 | The container serves every endpoint | ✅ 13 image tests pass against a running container |
| 3 | `/version` reports the injected metadata | ✅ all four fields populated under `make run-image` |
| 4 | An SBOM is produced | ✅ 130 packages, locked versions match `requirements.txt` |
| 5 | Two clean builds produce the same manifest digest | ✅ identical, with a negative control proving the check can fail |
| 6 | The image does not run as root | ✅ `User=10001:10001`, and the observed runtime UID is `10001` |

### The full pass

```
########## 1. make lint ##########
All checks passed!
45 files already formatted
########## 2. make test ##########
Required test coverage of 90.0% reached. Total coverage: 92.01%
135 passed, 13 deselected in 1.76s
########## 3. make build ##########
  ✓ built bgd-us-east-1-api:0.1.0-84d4eb0-dirty
  digest    sha256:8795c7225b10648dd4477482dc499989331e91d67c2896885034678eb56a8963
########## 4. make image-test ##########
13 passed, 135 deselected in 2.25s
########## 5. make image-verify ##########
  build 1  sha256:8795c7225b10648dd4477482dc499989331e91d67c2896885034678eb56a8963
  build 2  sha256:8795c7225b10648dd4477482dc499989331e91d67c2896885034678eb56a8963
  ✓ reproducible — both builds produced the same manifest digest
########## 6. make sbom ##########
  ✓ SBOM written — 130 packages
```

`make test` reports **13 deselected** and builds nothing: the `image` marker
keeps the Phase 1 inner loop docker-free, which was the point of D7.

### Image properties

```
bgd-us-east-1-api:0.1.0-84d4eb0-dirty  222MB
User=10001:10001  Arch=arm64/linux
```

### `/version` under `make run-image`

```json
{
  "version": "0.1.0",
  "git_sha": "84d4eb0-dirty",
  "image_digest": "sha256:9ccb10a1df21129e0079ff93cf0f32d26e9ee980b1d73a5cd4550b8dfcbb9e7d",
  "built_at": "2026-08-12T19:44:12Z"
}
```

`image_digest` matched `app/dist/image-digest.txt` exactly. This is the local
stand-in for what the ECS task definition does in Phases 5 and 6 — the deployer
knows the digest, the image cannot know its own. Under `make image-test` the
same field is `unknown`, which a test asserts deliberately.

### SBOM spot-check

```
boto3 1.43.67        boto3==1.43.67
fastapi 0.141.1      fastapi==0.141.1
pydantic 2.13.4      pydantic==2.13.4
starlette 1.6.0      starlette==1.6.0
uvicorn 0.52.1       uvicorn==0.52.1
```

Left column from `sbom.spdx.json`, right from `requirements.txt`. 130 packages
in total, the excess over the 27 pins being the Debian packages of the base
image.

---

## 2. Criterion 5 in detail: the reproducibility evidence

A check that has never failed is not known to work, so the claim is supported
from three directions.

**The positive result** — two clean, uncached builds of identical source:

```
build 1  sha256:8795c7225b10648dd4477482dc499989331e91d67c2896885034678eb56a8963
build 2  sha256:8795c7225b10648dd4477482dc499989331e91d67c2896885034678eb56a8963
```

**The negative control** — the same script with `BUILT_AT` taken from the wall
clock, which is exactly what §D4 rejected:

```
build 1  sha256:f2ef90ac42fdbd7fd4a6ce47b203b3d832747b118df131545624e3144b7be0b7
build 2  sha256:564dd908ce63fbd8be752b11eb51fe27198f606685341b426a422b65595dcd55
✓ negative control behaved correctly — wall-clock BUILT_AT produced different digests
```

So the comparison detects a difference when one exists, and deriving both
timestamps from the commit is what makes the property hold rather than being
incidental.

**Source sensitivity** — one added comment line in `src/bgd/__init__.py`:

```
baseline                    sha256:d0b9997b096129f9d6b1d62d3ce62b9e7a06a80c43f66b77fb6a776a9e94fab1
one comment line added      sha256:bef1cf6d6c9087edd2df993dfc01623d5a199181b2eeda9200434dd7df17a535  (both builds agreed)
```

The digest tracks the source rather than being a constant, and reproducibility
holds for the changed source too.

---

## 3. Findings from implementation

Six things were learned by running the code that were not visible when writing
the plan. Five were defects.

### F6 — `rewrite-timestamp` normalises only *newer* timestamps

**The plan was wrong about what the option does.** It is not "set every
timestamp to `SOURCE_DATE_EPOCH`"; measured, it applies
**`min(mtime, SOURCE_DATE_EPOCH)`**. Files newer than the commit are clamped;
files *older* than it are left exactly as they are.

Found because the digest changed after a source file was edited and restored: the
restore updated the mtime from `Aug 10` (before the commit) to `now` (after it),
which moved that file from the preserved branch to the clamped branch.

Isolated by building the same source four times with only the mtime varying:

```
mtime 2026-08-01 (older than epoch) -> sha256:c0ff1d9e646b2fbb33680a6dbf6ceff226ec5890d7fe8ffb23edfacc5e4f0601
mtime 2026-08-02 (older than epoch) -> sha256:17532943aa161283786838b399a103413b90468c5b554313e0386c9a98aa1e83
mtime 2026-12-31 (newer than epoch) -> sha256:5d0cb39faddd733e2c7b97e78fd6178e1d10c748f343d45aa17106538bc7c888
mtime now        (newer than epoch) -> sha256:5d0cb39faddd733e2c7b97e78fd6178e1d10c748f343d45aa17106538bc7c888
```

Two different *old* mtimes give two different digests; two different *new* ones
give the same digest. That is the clamp, visible directly.

**Why it mattered more than it looks.** A fresh `git clone` stamps every file
with the clone time, which is newer than any commit in it, so everything gets
clamped and the build is deterministic. CI and CodeBuild always clone fresh, so
CI would have agreed with itself forever while quietly disagreeing with any
developer whose checkout predated the commit being built. The failure mode is
"reproducible everywhere except the machine you are debugging on".

**Fix:** the builder stage now forces the timestamps itself, and the runtime
stage copies from the builder rather than from the context:

```dockerfile
ARG SOURCE_DATE_EPOCH=0
COPY src/ /build/src/
RUN find /build/src -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
...
COPY --from=builder /build/src /app/src
```

Re-measured with the same four mtimes, all four now produce
`sha256:9ccb10a1df21129e0079ff93cf0f32d26e9ee980b1d73a5cd4550b8dfcbb9e7d`. The
digest no longer depends on checkout history at all.

### F7 — `.dockerignore` patterns are anchored to the context root

**The image was shipping 24 host-compiled `.pyc` files.**

`.dockerignore` entries match against the whole relative path from the context
root, so a bare `__pycache__` excludes `app/__pycache__` and **never**
`app/src/bgd/__pycache__` — which is the only place bytecode actually appears.

```
app/src/bgd/__pycache__/__init__.cpython-314.pyc
app/src/bgd/api/__pycache__/main.cpython-314.pyc
…
count of .pyc under /app/src in the image: 24
```

Found while chasing a digest that moved with no source change: `make test`
regenerates the host's `__pycache__`, and the build swept it in. So the image
digest depended on **whether the developer had run the test suite**.

The Task 1 unit test passed throughout, because it asserted that the pattern was
*present*, not that it *worked* — a good reminder that asserting on a config
file's contents is not the same as asserting on its effect.

**Fix, in three places:**

- `.dockerignore` uses `**/__pycache__` and `**/*.pyc`.
- the unit test now asserts the recursive form specifically, with the reason.
- a new image test asserts the *outcome* — zero `.pyc` under `/app/src` — since
  nothing in the build compiles the application. That is the assertion that
  would have caught this.

Verified afterwards by building, running the full test suite to regenerate 24
host `.pyc` files, and rebuilding:

```
no host bytecode present -> sha256:9b6540c497e0634218cdb5e9bc1b24425a47080407be92155444ae5b189dacb0
after make test          -> sha256:9b6540c497e0634218cdb5e9bc1b24425a47080407be92155444ae5b189dacb0
```

### F8 — the readiness poll must tolerate a reset, not just a refusal

The image suite's wait loop caught `httpx2.ConnectError` only, and every
container test errored on the first run with:

```
httpx2.ReadError: [Errno 54] Connection reset by peer
```

The container was healthy — verified by running it by hand and reading its logs.
The cause is Docker's host-side port proxy, which **accepts** the TCP connection
as soon as the container exists, so a request made before uvicorn binds is
answered with a reset rather than refused.

**Fix:** poll on `httpx2.TransportError`, the common ancestor of `ConnectError`,
`ReadError` and `RemoteProtocolError`. All three mean "not up yet"; the deadline
is what should decide failure.

### F9 — the compose `api` service had to be profiled

Adding the service the Phase 1 comment promised made `docker compose up -d`
start it — and `make local-up` is a prerequisite of `make test`, `make
image-test` and `make run-image`. The consequences were immediate: an image
rebuilt as a side effect of running unit tests, and port 8081 taken out from
under `make run-image`, whose container then could not bind.

This is what produced the one genuinely confusing symptom of the session — a
`/version` full of default values, served by the compose container rather than
by the one under test.

**Fix:** `profiles: ["app"]`. A profiled service is skipped unless asked for by
name, so `docker compose --profile app up` gives the full stack and every make
target keeps getting only DynamoDB Local.

### F10 — macOS bash 3.2 rejects an empty array under `set -u`

`run-image.sh` chooses `-it` only when stdin is a terminal, so that a piped or
backgrounded invocation does not die on `the input device is not a TTY`. The
obvious spelling fails on this machine:

```
./scripts/run-image.sh: line 35: TTY_FLAGS[@]: unbound variable
```

`bash --version` → **3.2.57**, where expanding an empty array as `"${arr[@]}"`
under `set -u` is itself an unbound-variable error. The fix is
`${arr[@]+"${arr[@]}"}`. Recorded in `scripts/README.md` alongside the existing
`set -e` note, because it will recur — this is the same 3.x-vintage constraint
the makefile already carries for GNU Make 3.81.

### F11 — the builds fill the Docker Desktop disk, twice over

Two builds failed mid-phase with:

```
ERROR: failed to build: failed to solve: ResourceExhausted:
  failed to copy files: copy file range failed: no space left on device
```

The host had 178 GB free; the exhausted disk is Docker Desktop's VM. Two
independent accumulations, both caused by this phase's own design:

1. **BuildKit cache.** Every build runs `--no-cache`, so the cache the builder
   writes is never read — roughly a gigabyte per build of pure dead weight.
2. **Orphaned images.** Each build loads a new image under the same tag,
   untagging the previous one and leaving ~220 MB of dangling layers behind.
   Twenty builds is over four gigabytes.

The error is a poor signpost: it names a `COPY` line, which reads as a
Dockerfile bug rather than a full disk.

**Fix:** both scripts now clean up after themselves, via `prune_repro_cache` and
`prune_orphaned_images` in `lib/common.sh`. The second filters on the image's own
`org.opencontainers.image.title` label — added to the Dockerfile for this
purpose — so it can only ever match images built from this repository. A bare
`docker image prune` was rejected deliberately: this machine had three unrelated
dangling images, two of them three months old, and a blanket prune would have
taken them.

Verified by building three times and watching the image count hold steady:

```
images before: 49 | dangling: 4
build 1 -> sha256:8795c722…  images: 50  dangling: 5
build 2 -> sha256:8795c722…  images: 50  dangling: 5
build 3 -> sha256:8795c722…  images: 50  dangling: 5
```

Steady at 50 where it previously grew by one per build. The three unrelated
dangling images were still present afterwards.

### F12 — the SBOM package count was being read wrong

`generate-sbom.sh` counted packages with
`grep -c '"SPDXID": "SPDXRef-Package'` and reported **0 packages** for a
perfectly good 2.3 MB SBOM. syft emits **compact** JSON, so the pattern's space
after the colon matched nothing.

Harmless in itself, but it is the failure mode that matters: an empty SBOM would
have reported `0 packages` too, and the script would still have exited 0.
Replaced with `jq '.packages | length'` plus an explicit guard that a zero count
is a hard error.

---

## 4. Deviations from the plan

| Plan said | What was done | Why |
|---|---|---|
| Add `app/dist/` to the "Local scratch" block of `.gitignore` | Added to the existing **Build artefacts** block | That block already exists and already covers SBOMs |
| Each script derives its own version and SHA | One shared `image_build_identity` in `lib/common.sh` | The two scripts disagreed on the `-dirty` suffix, so `make image-verify` was proving a property of an image nobody ships. They now cannot drift |
| `info "build $label of 2"` inside `build_once` | Same, redirected to stderr | The function's stdout **is** the digest; the log line would have been captured into the compared value |
| Two `--output` flags might need splitting | Not needed — one invocation exports both | Recorded because the plan asked for it either way |
| `.dockerignore` excludes `__pycache__`, `*.pyc` | `**/__pycache__`, `**/*.pyc` | F7 |
| Poll on `httpx2.ConnectError` | Poll on `httpx2.TransportError` | F8 |
| compose `api` service | Same, behind `profiles: ["app"]` | F9 |

Two files gained content the plan did not mention: the Dockerfile carries three
OCI labels (F11 needs one of them), and `lib/common.sh` gained the two cleanup
helpers.

---

## 5. Carried forward

- **Phases 5 and 6 must set `runtime_platform { cpu_architecture = "ARM64" }`**
  on both task definitions. The image is arm64-only; an `X86_64` task definition
  fails at task start with an exec-format error.
- **Phases 5 and 6 must inject `BGD_IMAGE_DIGEST`** into the container
  environment from the digest Terraform deploys, or `/version` reports `unknown`
  in a live environment.
- **Phase 3** seeds ECR from `app/dist/image.oci.tar`. It should be built from a
  **clean tree**, so the tag carries no `-dirty` suffix.
- **Phase 8's CodeBuild project needs ARM compute** (`ARM_CONTAINER`), and reads
  `app/VERSION` for MAJOR.MINOR exactly as `build-image.sh` does.
- **The CI job is unverified until the pull request runs.** It needs
  `ubuntu-24.04-arm`, free on public repositories and billed on private ones, and
  the image suite reaches the DynamoDB service container through
  `host.docker.internal:host-gateway` — sound on a Linux runner, but not
  exercised on one from here.
