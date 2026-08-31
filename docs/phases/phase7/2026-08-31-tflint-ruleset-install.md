# Phase 7 — Validate could not install the tflint ruleset

**Date:** 2026-08-31
**Found:** on the first infra pipeline run that got past `Source`
**File:** `scripts/lint-infra.sh`
**Execution:** `bgd-us-east-1-infra-pipeline`, `b2f83ac1-9543-4116-9248-eaa5650f3109`

The Validate stage failed on `make tf-lint`, for a reason having nothing to do
with the Terraform it was linting.

---

## 1. Symptom

```
[Container] Running command make tf-lint
==> tflint — installing rulesets
Failed to install a plugin; Failed to fetch GitHub releases:
GET https://api.github.com/repos/terraform-linters/tflint-ruleset-aws/releases/tags/v0.44.0:
403 API rate limit exceeded for 34.228.4.223. [rate reset in 25m20s]
make: *** [makefile:218: tf-lint] Error 1
```

`Source` succeeded, `Validate` failed, and the run never reached a plan. Every
`terraform test` in the same build had already passed — 35 run blocks on `prod`
alone — so the failure was three seconds of network, after two minutes of work
that proved the code was fine.

## 2. Root cause

`tflint --init` resolves the pinned ruleset release through **api.github.com**,
which allows **60 unauthenticated requests per hour per source IP**.

Two properties make that free on a laptop and fatal in CodeBuild, and both have
to flip for the failure to appear:

| | Laptop | CodeBuild |
|---|---|---|
| Plugin directory | `infra/.tflint.d` persists between runs, so `--init` downloads **once, ever** | workspace is fresh every build, so `--init` downloads **every build** |
| Source IP | a private 60/hour budget | a shared AWS NAT address whose 60/hour is spent by every AWS customer behind it |

So the same command that had been green on this machine for five phases was
never going to be reliable in the pipeline. It is not flaky in the usual sense —
it fails whenever somebody else on that NAT address has been busy, which is
outside this project's control and unpredictable from inside it.

## 3. Options considered

**A `GITHUB_TOKEN`.** The conventional CI answer, and it works — 5,000
requests/hour instead of 60. Rejected: it is a credential to store, scope and
rotate, and creating it is a **fourth irreducibly manual step** in a project
whose documents state plainly that there are exactly three. Buying reliability
with a standing secret and a permanent correction to the runbook is a bad trade
for a linter.

**`ghcr.io/terraform-linters/tflint-bundle`,** which ships rulesets
preinstalled. Rejected on inspection rather than on principle: the image's
plugin directory is dated **3 September 2023**, `latest` has not been rebuilt
since, and the bundled ruleset is nowhere near the `0.44.0` that
`infra/.tflint.hcl` pins. It would have traded a rate limit for a three-year-old
ruleset.

**A CodeBuild S3 cache of `infra/.tflint.d`.** Reduces the download to cold
starts rather than eliminating it, so it lowers the probability of the failure
without removing it — and the failure it leaves behind is the one that is
hardest to reason about, because it is rare. It also needs a Terraform change to
a CodeBuild project and a buildspec `cache` block, which is more moving parts
than the fix chosen.

## 4. The fix

**Download the release asset directly instead of resolving it through the API.**
Release assets are served by a CDN and carry no such limit. The plugin is placed
where tflint already looks — `$TFLINT_PLUGIN_DIR/github.com/terraform-linters/tflint-ruleset-aws/<version>/`
— so tflint finds an installed plugin and makes **no network call at all**.
`tflint --init` is gone from the script.

Four properties worth stating, because each was a deliberate choice:

- **The version is read from `infra/.tflint.hcl`**, not repeated in the script.
  That file is what tflint enforces; a second copy could disagree with it. A
  guard refuses a version the checksums were not recorded for, so a bump fails
  by name rather than as a confusing checksum mismatch.
- **The checksums are pinned and verified**, following the precedent
  `scripts/install-terraform.sh` set. An unverified download is a worse problem
  than the one being fixed.
- **The architecture is asked of the image, not of the host.** The plugin is a
  native binary executed *by* the container, and the two diverge routinely here:
  Docker Desktop on Apple silicon runs this image as `arm64`, while CodeBuild's
  `LINUX_CONTAINER` is `amd64` (plan §D7). `uname -m` inside the container is the
  only answer correct in both places.
- **`sha256sum` or `shasum`,** whichever exists. This script runs on macOS and in
  CodeBuild; `install-terraform.sh` could assume `sha256sum` because it is
  CodeBuild-only, and this one cannot.

The side effect is the property worth having: **once the plugin is present the
lint runs entirely offline**, on the laptop and in the pipeline alike. Before
this change, `make tf-check` — advertised throughout these documents as needing
no AWS session and no network — quietly needed GitHub.

## 5. Verification

Run locally with the existing plugin directory moved aside, so the install path
actually executed rather than being skipped:

```
==> tflint — installing the aws ruleset 0.44.0 (linux_arm64)
  ✓ aws ruleset 0.44.0 installed
==> tflint — foundation
  ✓ foundation clean
```

Then the full gate, which also proves the second run makes no network call:

```
$ make tf-lint
  ✓ aws ruleset 0.44.0 already installed
  ✓ bootstrap clean      ✓ foundation clean     ✓ network clean
  ✓ staging clean        ✓ prod clean
==> checkov — infra/
Passed checks: 490, Failed checks: 0, Skipped checks: 110
  ✓ static analysis passed
```

`make test-scripts` — 3 test files, 0 failed.

**The amd64 path is not exercised locally**, because this machine is arm64. Its
checksum comes from the release's own `checksums.txt` rather than from a
download performed here, and the first green Validate stage in CodeBuild is what
confirms it. Said plainly rather than letting the green local run imply both
architectures were tested.

## 6. The trigger did not watch this file — a third gap of the same shape

`scripts/lint-infra.sh` was matched by **none** of the trigger's seven path
patterns. Every Validate stage runs it, so by Phase 7 §D12's own argument it is
this pipeline's executable content and always was. A commit that fixed only this
script would not have run the pipeline it fixes.

That is the third pre-existing gap of exactly this shape:

| Found in | File nobody was watching | Why it was missed |
|---|---|---|
| Phase 8 | `scripts/tf.sh`, `scripts/lib/common.sh` | unchanged since Phase 3 |
| Phase 9 | `lambdas/**` | packaged since Phase 6, never edited alone |
| **Here** | `scripts/lint-infra.sh` | unchanged since Phase 3 |

The common cause is worth naming rather than fixing three times: a file joins
the pipeline's executable content when a stage starts running it, and nothing
connects that moment to the trigger list. Each gap surfaced only when somebody
finally edited the file — which is the worst possible time, because the edit is
usually the fix for whatever made them open it.

`"scripts/lint-infra.sh"` is added, and both copies of the pattern-set assertion
are updated in the same commit — `foundation/tests/pipeline_shape.tftest.hcl` and
the duplicate in `app_pipeline_shape.tftest.hcl`, exactly as Phase 9 had to.

**This is the eighth pattern, and eight is the documented maximum**
`filePaths.includes` accepts (§F7). The next gap of this kind cannot be closed by
adding a line: it needs a second `push` block, each repeating the branch filter —
the shape the application pipeline already uses for its eleven. Recorded here
because the cheap fix has just been spent.
