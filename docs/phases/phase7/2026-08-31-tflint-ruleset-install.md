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


---

## 7. Postscript — applying this cancelled the run that applied it

The merge that delivered this fix produced an infra run that ended `Cancelled`,
with every action green:

```
Source ✓  Validate ✓  Foundation: Plan ✓ Approve ✓ Apply ✓
statusSummary: "Pipeline definition was updated"
```

Foundation's apply added `scripts/lint-infra.sh` to the trigger — a change to
`aws_codepipeline.infra` itself — and **CodePipeline cancels any in-flight
execution when the pipeline definition changes.** The run cancelled itself by
succeeding, so Network, Staging and Prod never ran.

This is the self-management caveat of §1's layer note, in a form neither that
note nor roadmap §4 describes. Both cover the **broken** case: *a broken change
to the pipeline definition must be repaired by a local apply*. This is the
**successful** case, and it is quieter — nothing errors, nothing is broken,
every action is green, and the run simply stops after Foundation. The only
evidence of why is `statusSummary` on the execution, which no console view shows
by default:

```bash
aws codepipeline list-pipeline-executions --pipeline-name bgd-us-east-1-infra-pipeline \
  --max-items 1 --query 'pipelineExecutionSummaries[].[status,statusSummary]' --output text
```

**The operational rule:** a `foundation` change that alters the pipeline's own
definition takes **two runs**. The first applies the definition and cancels
itself; the second, started by hand or by the next merge, does everything
downstream. Worth knowing before a change to the pipeline is made during an
incident, when "the run cancelled and production never got the fix" is an easy
thing to misread as a second failure.


---

## 8. The same failure again, one registry over

The very next run — the re-trigger after §7's self-cancellation — failed at the
same Validate stage, on the line immediately after the one just fixed:

```
==> checkov — infra/
docker: Error response from daemon: toomanyrequests:
You have reached your unauthenticated pull rate limit.
```

**Docker Hub rate-limits unauthenticated pulls per source IP**, and CodeBuild
egresses through a shared AWS NAT address. That is the identical mechanism as
§2's GitHub API limit, against a different service, hit within minutes of fixing
the first one — which is the useful part of this finding. The problem was never
tflint. It is that **this project pulls third-party images at build time over an
IP it shares with strangers**, and every such pull is a dependency on someone
else's generosity.

`ghcr.io` applies no anonymous pull limit, which is why the tflint image sitting
one line above checkov had been pulling cleanly all along, and why nobody had
reason to suspect the registry as a variable.

### The fix, and why it is unusually cheap

Both `checkov` and `syft` publish the same images to `ghcr.io`, and the digests
are **identical**:

| Image | Docker Hub | ghcr.io | Digest |
|---|---|---|---|
| checkov 3.3.13 | `bridgecrew/checkov` | `ghcr.io/bridgecrewio/checkov` | `c5fb7154bed7…` — unchanged |
| syft v1.51.0 | `anchore/syft` | `ghcr.io/anchore/syft` | `678bfa565b60…` — unchanged |

So this swaps the *registry* without swapping the *artifact*. The pin still names
the same bytes, and checkov returned the same `490 passed, 0 failed` afterwards,
which is the evidence that nothing but the source changed.

`syft` had not failed yet. It was moved in the same commit because it runs in the
**application** pipeline's Build stage, so its version of this failure would have
arrived during a deployment rather than during a lint — and would have looked
like a broken release rather than a broken registry.

### The exposure closed, an hour later, on a production deployment

Two Docker Hub pulls were deliberately left in place: `python:3.14.6-slim` and
`amazon/dynamodb-local`, both in the application pipeline's Build stage. The
reasoning was that their `public.ecr.aws` counterparts are different
repositories needing digests re-recorded, and that the base image sits under
design §4.1's reproducibility claim — deliberate work, not an incident fix.

**They failed within the hour**, on the deployment this whole evening was
building toward:

```
==> starting DynamoDB Local          ← pulled, using the last of the quota
==> running the test suite
docker: Error response from daemon: toomanyrequests
```

The Build stage pulls the base image **twice** — once for the test suite, once
as the build's `FROM` — plus DynamoDB Local: three Docker Hub pulls per build
against a limit of roughly ten per hour shared with strangers. The judgement to
defer was reasonable on the merits and wrong on the odds.

Both moved, and both turned out to be free:

| Image | To | Digest |
|---|---|---|
| python 3.14.6-slim | `public.ecr.aws/docker/library/python` | `7bec7ddc…` **unchanged** |
| DynamoDB Local | `public.ecr.aws/aws-dynamodb-local/aws-dynamodb-local` | `ff89bd48…` **unchanged** |

AWS mirrors both with identical manifests, so this is the same base image over a
different registry and the reproducibility claim is untouched — confirmed by
running `make image-verify` afterwards: two clean builds, one digest.

**A second defect surfaced only because of the move.**
`scripts/pipeline-app-build.sh` extracted both pins with `sed` patterns anchored
on `python:` and `amazon/`. After the move they would have matched nothing and
the script would have died on *"cannot read the base image pin from
app/Dockerfile"* — a loud failure with a cause nobody would connect to a
registry change. Both patterns now anchor on the ARG name and the service name
instead. The lesson generalises: **a pattern that hard-codes today's value of
the thing it extracts breaks silently when that value moves**, and the `die`
that catches it fires a build too late.

`.github/workflows/pr-validate.yml` pulls the same image in two jobs and was
moved with them.

**The remaining registry inventory** — no Docker Hub left:

```
ghcr.io/terraform-linters/tflint            no anonymous limit
ghcr.io/bridgecrewio/checkov                no anonymous limit
ghcr.io/anchore/syft                        no anonymous limit
quay.io/skopeo/stable                       no anonymous limit
public.ecr.aws/docker/library/python        AWS; authenticated inside AWS
public.ecr.aws/aws-dynamodb-local/…         AWS; authenticated inside AWS
```

ECR Public does rate-limit anonymous pulls, so a laptop can still hit it —
generously, and it is raised with
`aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws`.
A build inside AWS authenticates with its role and does not meet the limit at
all.
