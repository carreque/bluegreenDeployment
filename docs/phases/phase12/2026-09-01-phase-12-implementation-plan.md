# Phase 12 — Demonstration frontend: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-09-01
**Status:** Proposed
**Branch:** `feat/Phase12_UI_implementation`
**AWS cost incurred by this phase as planned:** **$0**, and $0 once applied. The phase creates no AWS resource and changes no `.tf` file (D10, F1). It adds three static files to an image that is already being built and pushed, and the only recurring cost it can produce is CloudWatch log volume from the banner's polling — bounded by D7 to roughly one line every two seconds per open tab, and zero when no tab is open.
**Companion documents:**
[design research](../../2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 2 plan](../phase2/2026-08-12-phase-02-implementation-plan.md) ·
[Phase 6 plan](../phase6/2026-08-28-phase-06-implementation-plan.md) ·
[Phase 6 isolation defect, closed](../phase6/2026-08-31-blue-green-does-not-isolate.md) ·
[Phase 8 plan](../phase8/2026-08-30-phase-08-implementation-plan.md) ·
[naming and tagging convention](../../naming-and-tagging-convention.md)

**Goal:** Make a traffic shift visible to somebody who is not reading a terminal. A single page served by the task itself — a create-account form whose submit button is tinted by the running build's release colour, the account list it writes into, and a banner that polls `/version` and re-tints live — so that opening the production listener and the test listener side by side shows two colours during a deployment, and one colour after it.

Eleven phases have made this platform's release behaviour correct, gated and measured. All of that evidence is textual: a `git_sha` in a JSON body, a CloudTrail entry, a CloudWatch metric. This phase adds the one surface that can be pointed at rather than read out.

**Architecture:** No new AWS resource, no new Terraform, no new pipeline stage, no new runtime dependency. The release colour becomes a build input — a file in the repository, read by `image_build_identity()`, injected as a Docker build argument, surfaced by `/version` alongside `version` and `git_sha`. The page is three static files served by a new FastAPI router from the same container as the API, and it learns its colour by fetching `/version` rather than by templating, which is what makes the tint follow a live traffic shift instead of a page load.

**Tech stack:** Nothing new. FastAPI 0.141.1 / Starlette 1.6.0 `Response`, the existing `pydantic-settings` 2.15.0 `Settings`, raw-ASGI middleware in the shape `RequestContextMiddleware` already uses, and vanilla browser JavaScript with no build step, no bundler and no framework.

**Spec:** [phase roadmap §3, Phase 12](../../2026-08-04-implementation-phase-roadmap.md#phase-12--demonstration-frontend).

---

## Global Constraints

Project-wide requirements, with exact values. Every task's requirements implicitly include this section.

- **Naming and tagging:** untouched. This phase creates no AWS resource, so convention §2 has nothing to apply to.
- **Reproducibility is not negotiable.** Design §4.1 and Phase 2's exit criterion: two clean builds of one commit produce the **same manifest digest**. Every decision below that touches the build is subordinate to this, and D3 exists entirely because of it.
- **The offline gate:** `make test`, `make lint` and `make build && make image-test && make image-verify` must all pass on a machine that has never run `aws sso login`.
- **Application coverage stays gated at 90%** (`app/pyproject.toml`, `fail_under = 90`). New Python is tested, not merely added.
- **Ruff, as configured:** `line-length = 100`, rule set `E,F,I,N,UP,B,A,C4,SIM,RUF,ASYNC,S,T20`, and `ruff format` is checked, not merely available. `make lint` runs both, over `app/` and `lambdas/`.
- **Python 3.14.** `requires-python = ">=3.14"`; the image is `python:3.14.6-slim` pinned by digest.
- **Nothing under `infra/` changes.** Not one `.tf` file, not one `.tftest.hcl` file. If this phase appears to need a Terraform change, something has been misread — stop and re-read D10 and F1.
- **Nothing under `pipelines/` or `lambdas/` changes.** The application pipeline reaches the build through `scripts/pipeline-app-build.sh` → `scripts/build-image.sh`, so it inherits the new build argument without editing a buildspec (F5).
- **The API's existing wire format is extended, never altered.** `/version` gains one field; no field is renamed, retyped or removed (F3). No other endpoint's request or response shape changes at all.
- **The three colour tokens are exactly `blue`, `green`, `slate`.** `slate` is the default everywhere a default exists: `Settings.release_color`, `ARG RELEASE_COLOR` in the Dockerfile. Nothing else is a valid value.
- **The Content-Security-Policy is one string, defined once**, in `app/src/bgd/api/middleware.py`, and contains neither `unsafe-inline` nor `unsafe-eval`:
  `default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`
- **Poll cadence:** 2000 ms normally, 10000 ms after 3 consecutive failures, and no fetch at all while `document.visibilityState !== "visible"` (D7).
- **Commits are proposed, never made automatically.** Every task ends with a commit step; run it only after the task's verification is green and the operator has approved.

---

## 0. Purpose and non-goals

After Phase 8 a commit under `app/` becomes a production blue/green deployment on its own. After Phase 9 the platform records that it happened. After Phase 11 there is evidence that a bad build is stopped. None of it is visible without a terminal, an AWS console tab, or both — and the single most convincing artefact this project can produce, two colours at once during a shift, does not exist.

This phase builds that artefact. Its job is **not** a frontend for the ledger. It is that a traffic shift becomes a thing you watch happen in a browser.

**This phase deliberately does not:**

- create any AWS resource, or make any AWS API call, in this session (D1)
- change any `.tf` file, any buildspec, any pipeline, any IAM role or any Lambda (D10)
- add a transaction form, a transaction list, or any second page (D11)
- add a runtime dependency, a template engine, a bundler or a Node toolchain (D4, D12)
- change any existing API request or response shape other than adding one field to `/version` (F3)
- authenticate anybody. The page is exactly as public as the API it calls already is, and it grants no capability that `curl` did not already have
- host anything outside the container. An S3-hosted page would talk to whichever colour the `:443` rule points at and could never show two at once (D12)
- name which ECS slot is serving. It names which **build** is serving (D2), because the colour slot is ECS's to assign and this project has gone to some trouble to keep it that way
- prove that blue/green works. Phase 6 owns that and closed it on 2026-09-01, verified end to end (F10). This phase **displays** a mechanism that has already been demonstrated correct; it is presentation, and it is not evidence

### 0.1 Decisions taken before this plan was written

#### D1 — This session writes and verifies; you build, apply and demonstrate

Same as Phases 3 through 10, and for the same reason. Everything provable without an AWS session is proved on the branch: the unit and API suites, the image suite against a locally built container, and the repeatability check. The deployment and the two-window demonstration are handed over as a runbook, `docs/runbooks/phase-12-frontend-demo.md`, written by Task 7.

**Exit criterion 1 in §4 is not met by this branch.** It needs a real deployment in flight, and this session creates nothing.

#### D2 — The colour belongs to the build, not to the ECS slot

The obvious reading of "show blue and green" is that the page announces which ECS colour it is running as. It cannot, and the reason is a property this project has spent real effort protecting.

`infra/environments/prod/alb.tf` declares the initial blue/green pairing and then hands the assignment over with `lifecycle { ignore_changes = [action] }` on both listener rules (`:218` and `:241`). `scripts/lint-infra.sh` fails the build if anybody takes it back. The comment at `alb.tf:173` states it directly: the colours there are the *initial* assignment only. A task therefore has no supported way to learn which target group it was registered into, and inventing one would mean reintroducing exactly the coupling those two files exist to prevent.

So the colour is a **release marker**, in the same family as `version`, `git_sha` and `built_at`: it says *which build am I*, not *which slot am I in*. The demonstration works anyway, and works honestly, because a blue/green deployment is precisely the state in which two different builds are reachable at two different listeners. The production listener serves the incumbent build; the test listener serves the candidate. Two builds, two colours, one screenshot.

Stated plainly so nobody later reads more into the page than it claims: **a green button does not mean "the green target group". It means "the build whose `RELEASE_COLOR` file said green".** The runbook says this in the same words.

#### D3 — `app/RELEASE_COLOR`, a file in the repository, not a build-time environment variable

The colour has to reach the image somehow. The cheap way is an environment variable read by `build-image.sh` at build time. It is wrong here, and reproducibility is what makes it wrong.

Design §4.1 requires that two clean builds of one commit produce the same manifest digest, and Phase 2 measured it. A build input that comes from the operator's shell is not a function of the source: the same commit built by two people, or by a laptop and by CodeBuild, would produce two digests, and `make image-verify` would be comparing two different images while reporting on one. Phase 2's §F6 already recorded how easily this property is lost by accident; losing it on purpose is worse.

A file next to `app/VERSION` fixes it completely. The colour becomes part of the commit, the digest stays a pure function of the source, and — the part that makes the demonstration better rather than merely correct — **flipping the colour becomes a real commit that flows through the real pipeline**. You do not configure a demo. You ship a release, and the release happens to be a different colour.

`app/VERSION` is the precedent, `image_build_identity()` in `scripts/lib/common.sh:156` is the place that reads it, and F5 records why both build scripts must be changed together.

#### D4 — The page is static and learns its colour from `/version`, not from a template

Two ways to get the colour into the markup: substitute it server-side when the page is built or served, or let the page ask.

Server-side substitution means either a template engine — a new runtime dependency, a new entry in `requirements.in`, a `pip-compile` run, rendering in the request path — or string formatting on HTML, which is how cross-site scripting is invented. Neither is worth it.

Asking is better on the merits, not merely cheaper. The banner polls `/version` anyway (D7), and every poll goes back through the ALB. So a tab left open on the production listener **re-tints itself the moment ECS moves the listener rule**, with no reload. That is the difference between discovering that a shift happened and watching it happen, and it falls out of the simpler design rather than being added to it.

The cost, stated: a few hundred milliseconds of untinted button on first paint. The page renders in a neutral `unknown` state and tints on the first successful poll.

#### D5 — Three files and three routes, so the CSP needs no `unsafe-inline`

A single self-contained HTML file with inline `<style>` and `<script>` is the smallest thing that works, and it forces `script-src 'unsafe-inline'` — which is to say it forces the one Content-Security-Policy directive that makes a CSP close to worthless.

Splitting into `index.html`, `app.css` and `app.js`, each on its own route, buys `script-src 'self'; style-src 'self'` with no exceptions, no nonces to generate and no hashes to keep in sync. Three routes instead of one is not a real cost.

This matters concretely and not theoretically: the page renders `owner_name`, which is user-supplied, unvalidated beyond a length bound, and stored. See D9.

#### D6 — Three colour tokens, and `slate` is the local default

`release_color` is validated against exactly `{blue, green, slate}` and rejected otherwise. Two reasons for a closed set rather than a free-form string:

- The wire format returns a **token**, never a hex value. The CSS owns what blue looks like, so the palette can be adjusted without a redeploy of anything that stores or asserts on the value.
- A typo in `app/RELEASE_COLOR` is a red test at build time instead of an untinted button discovered in front of an audience.

`slate` is the default, and it is deliberately neither of the demo colours. A container started without build arguments — `docker compose --profile app up`, a bare `uvicorn`, any test run — reports `slate`, so a local process can never be mistaken for a deployed one in a screenshot (F7).

#### D7 — The banner polls, and stops when the tab is hidden

Two seconds is fast enough to make a shift feel live and slow enough to be free. `RequestContextMiddleware` logs one line per request, so an open tab writes about 30 log lines a minute into a log group with 14-day retention — negligible, but not nothing, and there is no reason to pay it for a tab nobody is looking at.

The poller therefore checks `document.visibilityState` and skips the fetch when the tab is hidden, resuming on `visibilitychange`. It also backs off to a 10-second interval after three consecutive failures, so a page left open across a `make teardown` does not hammer a dead ALB until somebody closes it.

#### D8 — `no-store` on the page, the assets and `/version`

The entire point is that the response reflects *which build answered this request*. A cached page, or a cached `/version`, silently defeats it — and the failure mode is the worst kind: the demo appears to work and shows the wrong answer.

`Cache-Control: no-store` on all four responses. The three static routes set it in the router; `/version` sets it on its own `Response`, because it is a `response_model` route and has no other place to put a header. There is no CDN in front of the ALB, so this is about the browser and the back/forward cache, and it costs nothing at this request volume.

#### D9 — The list is built with `textContent`, and the server never interpolates user data

`owner_name` is accepted from the browser, stored in DynamoDB, and read back to be rendered. That is a stored-XSS shape, and the mitigation has to be structural rather than a promise.

Two rules, both testable:

- The server never puts request-derived or database-derived data into HTML. It serves three fixed files, byte for byte, and nothing else. Task 3's test asserts the served bytes equal the file on disk.
- The client builds every row with `document.createElement` plus `textContent`. The string `innerHTML` appears nowhere in `app.js`, and Task 3's test greps the served body for it — a lint rule nobody can quietly delete without the test going red.

Together with D5's CSP the page has no injection path that does not first require breaking one of the two.

#### D10 — No Terraform, and no pipeline change

Both listener rules already match `/*` (F1), the health check stays on `/health`, and the colour arrives inside the image rather than through the task definition. The application pipeline reaches the build through `scripts/pipeline-app-build.sh`, which calls `scripts/build-image.sh`, so the new build argument propagates without a buildspec edit (F5).

Recorded as a decision rather than left as an observation, because "add a listener rule for `/`" and "add `BGD_RELEASE_COLOR` to the task definition" are both plausible-looking changes that would be pure harm — the second especially, since it would create a second source of truth for the colour and hand it to the layer that D2 says must not own it.

#### D11 — The account form only; transactions stay out

The subject of the demonstration is the deployment, not the ledger. One form exercises the write path, the read path and the error path, and adding transactions would mean a second form, idempotency-key handling in the browser, and a per-account list — all to demonstrate nothing that the first form does not already demonstrate.

The transaction API is unchanged and still reachable at `/openapi.json` for anybody who wants it. (Not `/docs` — see the note in Task 2 Step 2.)

#### D12 — The page ships in the image

An S3 and CloudFront static site is the conventional answer for a page like this, and it is the one shape that cannot do the job. One page hosted outside the platform would call the ALB, reach whichever colour the `:443` rule points at, and be structurally incapable of showing two colours at once. It would also need a bucket, a distribution, an origin policy and CORS on the API.

Shipping the page inside the container means **the page you are looking at was served by the task you are asking about** — which is the entire evidentiary value.

#### D13 — A row's build attribution is client-side, and says so

The draft of this plan promised a "created by build `<git_sha>`" note on every account row, on the grounds that after a shift the list would hold rows written by two different builds. **The API cannot support that claim.** `AccountResponse` carries `account_id`, `owner_name`, `currency`, `balance_minor` and `created_at`; the creating build is not stored, and storing it would mean a domain field, a repository change and a wire-format change — none of which this phase is scoped to make (§0).

What the page can say truthfully, and does: for accounts **this tab created**, it remembers the `git_sha` the banner was showing at the moment of the POST, and labels the row `opened via build <sha> · this tab`. Rows loaded from the server carry no such label. The distinction is visible in the markup and stated in the runbook, because a label that overstates what it knows is worse than no label in front of an audience.

The demonstration does not depend on it. Two windows, two colours, two `git_sha` values in the two banners is the artefact.

---

## 1. Findings recorded before this plan was written

Each was checked against the working copy on 2026-09-01, at commit `c35015a`.

### F1 — Both listener rules match `/*`, so `/` needs no rule

`infra/environments/prod/alb.tf:212-215` and `:232-235` each declare `condition { path_pattern { values = ["/*"] } }`. The production and test listeners forward every path to their target group, so `/`, `/app.css` and `/app.js` are reachable the moment the container serves them. Staging's listener is likewise a single default forward.

This is what makes D10's "no Terraform" claim true rather than hopeful.

### F2 — The test listener is open to the internet, so the two-window demo needs no security-group change

`infra/network/security.tf:79-88` opens port 8443 to `0.0.0.0/0` on the production ALB security group, described as "Blue/green test listener, production only". A browser on any network can therefore load `https://<api host>:8443/` directly.

Had this been locked to a hook Lambda's security group, the demonstration would have needed either a security-group change or an SSH tunnel, and this plan would look quite different.

### F3 — The lifecycle hook reads `/version` with `.get()`, so a new field cannot break it

`lambdas/lifecycle_hook/handler.py:399-408` decodes the body with `json.loads` and reads `version.get("image_digest", "unknown")` and `version.get("git_sha", "unknown")`. There is no schema validation, no `extra="forbid"`, and no key enumeration.

Adding `release_color` to `VersionResponse` is therefore additive in the strict sense: the dark canary continues to behave identically, and no Lambda test changes.

### F4 — There is no packaging step, so a `static/` directory works in both the tests and the image

`app/pyproject.toml` carries no `[build-system]` and says so in a comment: the package is never pip-installed. Tests reach it through `pythonpath = ["src"]`, and the image sets `PYTHONPATH=/app/src` with `COPY --from=builder /build/src /app/src`.

A directory added under `app/src/bgd/api/static/` is therefore present, unmodified, in both — with no `package_data`, no `MANIFEST.in` and no wheel to rebuild. `app/.dockerignore` was re-read for this: it excludes `.venv`, `tests`, `dist`, the caches, `.env`, `docker-compose.yml`, `README.md` and `**/__pycache__` / `**/*.pyc`. Nothing under `src/` is excluded, so `COPY src/ /build/src/` and the builder's `find … -exec touch` cover the new files automatically — which also means they are covered by the reproducibility guarantee without any change to how it is enforced.

"Automatically" is still an inference about a build, so Task 5 asserts it against the running container rather than trusting this paragraph.

### F5 — `image_build_identity()` is the single derivation point, and the two build scripts repeat the arguments by hand

`scripts/lib/common.sh:156` defines `image_build_identity()`, which sets `APP_VERSION`, `GIT_SHA`, `BUILT_AT`, `IMAGE_REF` and exports `SOURCE_DATE_EPOCH`. Its own comment states why it is shared: if `build-image.sh` and `verify-image-repeatability.sh` derived a value differently, the repeatability check would prove a property of an image nobody ships.

But the `--build-arg` lines themselves are duplicated — `scripts/build-image.sh:55-58` and `scripts/verify-image-repeatability.sh:44-47` each list the same four. **A fifth argument must be added to both.** Adding it only to `build-image.sh` would make `make image-verify` build the colourless default and compare it against a coloured image; adding it only to the verifier would be worse still, because it would pass.

`scripts/pipeline-app-build.sh` calls `build-image.sh` rather than invoking `docker buildx` itself, so the pipeline inherits the change with no edit.

### F6 — `readonlyRootFilesystem = true`, and the page only ever reads

`infra/environments/prod/ecs.tf` sets `readonlyRootFilesystem = true`, measured against the real image in Phase 5's F5. The UI router reads its three files **once at import time** into memory and serves them from there, so there is no per-request disk access at all — and even the import-time read is a read, of files baked into the image layer.

Reading at import rather than per request is also what makes the D9 assertion cheap: the bytes served are fixed at process start and cannot vary by request.

### F7 — `docker compose --profile app up` passes no build arguments, so the local container reports `slate`

`app/docker-compose.yml` documents this already, for `/version`'s existing fields: compose "passes none of the build arguments, so `/version` here reports its defaults and the image is not digest-identical to `make build`'s."

`release_color` joins that list. The consequence for the runbook: a purely local two-colour preview needs **two `make build` runs** with `app/RELEASE_COLOR` edited between them, not two compose services. Task 7 writes it that way, and also records the honest limitation — with an uncommitted edit in the tree both builds tag as `…-dirty`, so the two local windows differ in colour but *not* in `git_sha`. Only the pipeline path produces two distinct shas.

### F8 — `smoke.sh` is not covered by the shell suite

`scripts/tests/` contains `test_operator_scripts.sh`, `test_pipeline_scope.sh` and `test_common.sh`. `grep -rn smoke scripts/tests/` returns nothing; the operator suite covers `teardown.sh`, `verify-idle.sh` and `rebuild.sh` guards only.

Adding assertions to `smoke.sh` therefore changes no asserted check count and breaks no existing test. Recorded because the opposite was assumed when this phase was proposed, and an assumption about a test suite is worth one `grep` before it becomes a task.

### F9 — The image suite already asserts `/version` against `app/VERSION`

`app/tests/image/test_image_metadata.py` reads `app/VERSION` from disk and asserts the running container's `/version` starts with it. `release_color` gets the identical treatment against `app/RELEASE_COLOR` — the same shape, in the same file, proving the same thing: that a build argument survived the journey into the image.

The second test in that file, `test_image_digest_is_unknown_until_terraform_injects_it`, is the model for asserting a *deliberate* gap, and nothing here needs one.

### F10 — Phase 6's isolation defect is closed, so the demonstration has something real to show

[`2026-08-31-blue-green-does-not-isolate.md`](../phase6/2026-08-31-blue-green-does-not-isolate.md) §7 closes it: Terraform was reverting ECS's colour assignment on every apply, because neither `aws_lb_listener_rule` carried `ignore_changes = [action]`. Fixed and verified end to end on 2026-09-01 — `terraform plan` clean against a live production whose rules ECS had moved, the colours alternating across three deployments in both directions, the dark canary reporting the **incoming** `git_sha` both times, and all nine `ModifyRule` calls coming from the blue/green role.

The sampling log in [`docs/evidence/phase-06-exit-criterion-2.txt`](../../evidence/phase-06-exit-criterion-2.txt) is this phase's demonstration in text form:

```
TIME       blueTG greenTG :443           :8443          prodRule→  testRule→
14:38:34   2      2       0.1.6-6f24d09  0.1.5-25153bc  green      blue
14:39:02   2      2       0.1.5-25153bc  0.1.5-25153bc  blue       blue    ← production shift
```

Two listeners, two builds, one moment. Phase 12 puts a colour on it.

**What remains, and it lands in this phase's lap.** §7's closing note: both verification deployments were driven by `scripts/tf.sh apply prod` directly, and the **pipeline** path has not been re-run since the fix. Section B of this phase's runbook flips `app/RELEASE_COLOR` and pushes, which drives the application pipeline end to end — so the demonstration is also the re-confirmation Phase 6 asked for, at no extra cost. Task 7 says so, and the runbook records the result under `docs/evidence/`.

### F11 — The roadmap amendment is already in the working tree, uncommitted

`git diff` on 2026-09-01 shows `docs/2026-08-04-implementation-phase-roadmap.md` already carrying table row 12, the Phase 12 section, "Thirteen phases", and the Phase 6 risk row updated to point at this phase; `docs/phases/README.md` already says "thirteen phases".

Task 7 Step 3 therefore **verifies and commits** that work rather than writing it again. Recorded because a task that says "add the section" would otherwise produce a duplicate one.

---

## 2. File structure

```
app/
  RELEASE_COLOR                          NEW  one line: blue
  src/bgd/
    config.py                            MOD  release_color, validated by Literal
    api/
      main.py                            MOD  include the ui router, add the middleware
      middleware.py                      MOD  + SECURITY_HEADERS, SecurityHeadersMiddleware
      schemas.py                         MOD  VersionResponse.release_color
      routers/
        health.py                        MOD  /version returns it, and sets no-store
        ui.py                            NEW  GET /, /app.css, /app.js
      static/
        index.html                       NEW  form, list, identity banner
        app.css                          NEW  palette keyed by data-release-color
        app.js                           NEW  submit, render, poll
  tests/
    api/
      test_ui.py                         NEW  headers, routes, bytes-equal-disk, no innerHTML
      test_health.py                     MOD  /version carries release_color and no-store
    unit/
      test_config.py                     MOD  the colour token is validated
      test_build_inputs.py               MOD  app/RELEASE_COLOR is well-formed
    image/
      test_image_metadata.py             MOD  the build argument reached the image
      test_image_endpoints.py            MOD  the page is served by the container
  Dockerfile                             MOD  ARG RELEASE_COLOR -> ENV BGD_RELEASE_COLOR
  README.md                              MOD  the page, and how to see two colours locally

scripts/
  lib/common.sh                          MOD  image_build_identity reads RELEASE_COLOR
  build-image.sh                         MOD  --build-arg, and one dim() line
  verify-image-repeatability.sh          MOD  --build-arg  (F5: both, or neither)
  smoke.sh                               MOD  fifth and sixth assertions

docs/
  2026-08-04-implementation-phase-roadmap.md   MOD  already written, uncommitted (F11)
  phases/README.md                             MOD  already written, uncommitted (F11)
  phases/phase12/
    2026-09-01-phase-12-implementation-plan.md  this file
    2026-09-01-local-verification.md            NEW  Task 7
  runbooks/phase-12-frontend-demo.md            NEW  Task 7
  runbooks/README.md                            MOD  the new runbook
```

Nothing under `infra/`, `pipelines/` or `lambdas/` appears in that list, and that is the check: if implementation adds a line to it, re-read D10.

**Responsibilities, so the decomposition is explicit:**

| File | Owns | Does not own |
|---|---|---|
| `config.py` | validating the colour token | what a colour looks like |
| `middleware.py` | the security headers, for every response | anything route-specific |
| `routers/ui.py` | reading three files once, serving them with `no-store` | any request-derived content |
| `static/index.html` | structure and the element ids the script binds to | any colour value |
| `static/app.css` | the palette, keyed on `:root[data-release-color]` | which colour is current |
| `static/app.js` | polling, tinting, submitting, rendering rows | any HTML string |
| `lib/common.sh` | deriving `RELEASE_COLOR` from the repository | passing it to a build |
| both build scripts | passing `--build-arg RELEASE_COLOR` | deriving it |

---

## 3. Tasks

Seven tasks. Tests precede implementation throughout — for the Python that means the test is written and **seen to fail** before the code it asserts on exists.

Every task ends with its suite passing and a commit **proposed for approval, never made automatically**. The full gate runs at Task 5 and again at Task 7.

---

### Task 1: `app/RELEASE_COLOR`, the setting, and `/version`

First, because everything else reads it: the page fetches it, the image test asserts it, the smoke test checks it.

**Files:**
- Create: `app/RELEASE_COLOR`
- Modify: `app/src/bgd/config.py`, `app/src/bgd/api/schemas.py`, `app/src/bgd/api/routers/health.py`
- Test: `app/tests/unit/test_config.py`, `app/tests/unit/test_build_inputs.py`, `app/tests/api/test_health.py`

**Interfaces:**
- Produces: `Settings.release_color: Literal["blue", "green", "slate"]` (default `"slate"`), and `VersionResponse.release_color: str`. `/version` responses gain `"release_color"` and the header `cache-control: no-store`.
- Consumed by: Tasks 3, 4, 5, 6 and `static/app.js`.

- [ ] **Step 1: Write the failing settings tests**

Append to `app/tests/unit/test_config.py`:

```python
def test_release_color_defaults_to_neither_demo_colour() -> None:
    """A container started without build arguments must not look deployed.

    compose, a bare uvicorn and every test run land here. If this defaulted to
    blue, a local window would be indistinguishable from a production one in a
    screenshot. Phase 12 plan, D6.
    """
    assert Settings(_env_file=None).release_color == "slate"


def test_release_color_is_read_from_the_environment(monkeypatch) -> None:
    monkeypatch.setenv("BGD_RELEASE_COLOR", "green")
    assert Settings(_env_file=None).release_color == "green"


def test_an_unknown_release_color_is_rejected(monkeypatch) -> None:
    """A typo in app/RELEASE_COLOR is a container that refuses to start.

    The alternative is an untinted button discovered in front of an audience,
    which is the same defect found several hours later.
    """
    monkeypatch.setenv("BGD_RELEASE_COLOR", "purple")
    with pytest.raises(ValidationError):
        Settings(_env_file=None)
```

That file currently imports only `from bgd.config import Settings, get_settings`. Add the two imports it now needs, at the top, in ruff's import order:

```python
import pytest
from pydantic import ValidationError

from bgd.config import Settings, get_settings
```

- [ ] **Step 2: Write the failing build-input test**

Append to `app/tests/unit/test_build_inputs.py`, whose docstring already explains why this class of contract belongs there — "both contracts here fail silently if broken". A malformed `RELEASE_COLOR` fails in exactly that way: the image builds, pushes, and then refuses to start, discovered at `make image-test` rather than at `make test`.

```python
RELEASE_COLORS = frozenset({"blue", "green", "slate"})


def test_release_color_is_one_of_the_three_tokens() -> None:
    """Read by `tr -d '[:space:]'` in shell and `.strip()` in Python.

    Anything else — a comment, a second line, a capital B — reaches the image
    as BGD_RELEASE_COLOR and is rejected by Settings at startup.
    """
    raw = (APP_ROOT / "RELEASE_COLOR").read_text()
    assert raw.strip() in RELEASE_COLORS, f"RELEASE_COLOR must be one of {sorted(RELEASE_COLORS)}, got {raw!r}"
    assert raw == raw.strip() + "\n", "RELEASE_COLOR must be exactly one token and one newline"
```

- [ ] **Step 3: Write the failing `/version` tests**

In `app/tests/api/test_health.py`, add `release_color="green"` to the fixture's `Settings(...)` — deliberately not the `app/RELEASE_COLOR` value, so the test proves the endpoint reports *the settings it was given* rather than a constant that happens to match:

```python
@pytest.fixture
def client() -> TestClient:
    settings = Settings(
        _env_file=None,
        app_version="1.2.345",
        git_sha="deadbee",
        image_digest="sha256:abc123",
        built_at="2026-08-05T10:00:00Z",
        release_color="green",
    )
    return TestClient(create_app(repository=InMemoryLedgerRepository(), settings=settings))
```

Then extend the existing `test_version_reports_the_injected_build_metadata` — its assertion is an exact-equality check on the whole body, so a new field must be added there or the test goes red for the right reason in the wrong place:

```python
def test_version_reports_the_injected_build_metadata(client) -> None:
    """Phase 6 curls this against :443 and :8443 during a blue/green shift.
    Two different git_sha values is the direct proof of which colour serves
    whom, so these fields are a contract with Phase 6, not decoration.

    Phase 12 adds release_color and polls this endpoint from the browser every
    two seconds; the field is the page's entire input.
    """
    body = client.get("/version").json()
    assert body == {
        "version": "1.2.345",
        "git_sha": "deadbee",
        "image_digest": "sha256:abc123",
        "built_at": "2026-08-05T10:00:00Z",
        "release_color": "green",
    }
```

And add the cache header test (D8) below it:

```python
def test_version_is_never_cached(client) -> None:
    """The whole demonstration is 'which build answered this request'.

    A cached /version defeats it silently: the page keeps showing the previous
    build's colour after a shift and looks like it is working. Phase 12, D8.
    """
    assert client.get("/version").headers["cache-control"] == "no-store"
```

- [ ] **Step 4: Run the tests and see all six fail**

```bash
make test
```

Expected: `test_release_color_defaults_to_neither_demo_colour`, `test_release_color_is_read_from_the_environment` and `test_an_unknown_release_color_is_rejected` fail — the first two on `AttributeError: 'Settings' object has no attribute 'release_color'`, the third because no `ValidationError` is raised (`extra="ignore"` swallows the unknown variable). `test_release_color_is_one_of_the_three_tokens` fails with `FileNotFoundError`. Both `/version` tests fail on the missing key.

- [ ] **Step 5: Create `app/RELEASE_COLOR`**

One line, no trailing commentary — it is read by `tr -d '[:space:]'` in shell and `.read_text().strip()` in Python, exactly as `app/VERSION` is. The comment explaining what it is lives in the Dockerfile and in `app/README.md`, because a file whose entire content is parsed cannot carry one.

```bash
printf 'blue\n' > app/RELEASE_COLOR
```

- [ ] **Step 6: Add the setting**

In `app/src/bgd/config.py`, add the import and the field. The field goes in the build-metadata block beside `app_version` and `git_sha`, because that is what it is:

```python
from typing import Literal
```

```python
    # Build metadata, surfaced by /version. Overwritten at image build time.
    app_version: str = "0.0.0-dev"
    git_sha: str = "unknown"
    image_digest: str = "unknown"
    built_at: str = "unknown"

    # Which release this build announces itself as — the demonstration surface
    # Phase 12 tints its submit button from. NOT which ECS colour slot is
    # serving: that is ECS's to assign (infra/environments/prod/alb.tf), and
    # nothing in a task can read it. See the Phase 12 plan, D2.
    #
    # A closed set, so a typo in app/RELEASE_COLOR is a red build rather than
    # an untinted button discovered in front of an audience. Literal gives the
    # validation for free and keeps the message readable; a field_validator
    # would be more code for a worse one. "slate" is neither demo colour on
    # purpose: a container started without build arguments — compose, a bare
    # uvicorn, any test — must not be mistakable for a deployed one.
    release_color: Literal["blue", "green", "slate"] = "slate"
```

- [ ] **Step 7: Extend the wire format**

In `app/src/bgd/api/schemas.py`:

```python
class VersionResponse(BaseModel):
    version: str
    git_sha: str
    image_digest: str
    built_at: str
    # A token, never a hex value: the CSS owns what blue looks like (D6).
    # `str` rather than the settings' Literal — Settings is the validation
    # boundary, and re-validating here would only create a second place to
    # edit when a colour is added.
    release_color: str
```

In `app/src/bgd/api/routers/health.py`, `version()` already takes `SettingsDep`; add the `Response` parameter (`Response` is already imported in this module for `ready()`):

```python
@router.get("/version", response_model=VersionResponse)
def version(settings: SettingsDep, response: Response) -> VersionResponse:
    """Build identity of the running task.

    Phase 6 curls this against the :443 production listener and the :8443 test
    listener during a blue/green shift; two different git_sha values are the
    direct proof of which colour is serving whom.

    Phase 12 polls it from the browser every two seconds and tints the page
    from release_color, so the same two-listener comparison becomes two
    colours on two screens rather than two JSON bodies in two terminals.

    no-store because a cached body would keep showing the previous build after
    a shift — a demonstration that appears to work and is wrong (D8).
    """
    response.headers["cache-control"] = "no-store"
    return VersionResponse(
        version=settings.app_version,
        git_sha=settings.git_sha,
        image_digest=settings.image_digest,
        built_at=settings.built_at,
        release_color=settings.release_color,
    )
```

- [ ] **Step 8: Run the tests and see them pass**

```bash
make test
make lint
```

Expected: all green, coverage above 90, `ruff check` and `ruff format --check` clean.

- [ ] **Step 9: Commit (propose; do not run without approval)**

```bash
git add app/RELEASE_COLOR app/src/bgd/config.py app/src/bgd/api/schemas.py \
        app/src/bgd/api/routers/health.py app/tests/unit/test_config.py \
        app/tests/unit/test_build_inputs.py app/tests/api/test_health.py
git commit -m "feat(app): add the release colour as a build identity field on /version"
```

**Verification:** `make test` green with coverage above 90; `make lint` green; `/version` from `make run-local` reports `"release_color": "slate"` and a `cache-control: no-store` header:

```bash
curl -is http://localhost:8080/version | grep -i 'cache-control\|release_color'
```

---

### Task 2: Security headers

Before the router, because the router's tests assert on the headers this task adds.

**Files:**
- Modify: `app/src/bgd/api/middleware.py`, `app/src/bgd/api/main.py`
- Test: `app/tests/api/test_ui.py` (created here, extended by Task 3)

**Interfaces:**
- Produces: `SECURITY_HEADERS: tuple[tuple[bytes, bytes], ...]` and `SecurityHeadersMiddleware` in `bgd.api.middleware`.
- Consumed by: every response the application serves, and Task 3's tests.

- [ ] **Step 1: Write the failing header tests**

Create `app/tests/api/test_ui.py`. It asserts against `/health`, which already exists, so the test is about the middleware and not about a route that has not been written yet:

```python
"""The demonstration page, its headers, and the two structural XSS rules.

The page renders owner_name, which is user-supplied, stored, and validated
only for length. The mitigations are structural rather than promised — a CSP
with no unsafe-inline (D5), a server that interpolates nothing (D9), and a
client that never assembles markup from strings — and each one is asserted
here so it cannot be quietly undone.
"""

import pytest
from fastapi.testclient import TestClient

from bgd.api.main import create_app
from bgd.repository.memory import InMemoryLedgerRepository


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_app(repository=InMemoryLedgerRepository()))


def test_every_response_carries_the_security_headers(client) -> None:
    """On the JSON API too, not only on the page.

    One policy for the whole application costs nothing and means a header
    cannot be lost by a route being registered somewhere unexpected.
    """
    headers = client.get("/health").headers
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["referrer-policy"] == "no-referrer"
    assert headers["x-frame-options"] == "DENY"
    assert "content-security-policy" in headers


def test_the_csp_has_no_inline_escape_hatch(client) -> None:
    """The entire reason the page is three files rather than one (D5).

    A single self-contained HTML file forces script-src 'unsafe-inline', which
    is the one directive that makes a CSP close to worthless.
    """
    policy = client.get("/health").headers["content-security-policy"]
    assert "unsafe-inline" not in policy
    assert "unsafe-eval" not in policy
    assert "default-src 'none'" in policy
    assert "script-src 'self'" in policy
    assert "connect-src 'self'" in policy


def test_the_request_id_header_survives_the_new_middleware(client) -> None:
    """Two middlewares now append to http.response.start. Both must land."""
    response = client.get("/health")
    assert len(response.headers["x-request-id"]) == 32
    assert response.headers["x-frame-options"] == "DENY"
```

- [ ] **Step 2: Run the tests and see them fail**

```bash
cd app && ./.venv/bin/python -m pytest tests/api/test_ui.py -v
```

Expected: `test_every_response_carries_the_security_headers` and `test_the_csp_has_no_inline_escape_hatch` fail with `KeyError: 'x-content-type-options'` and `KeyError: 'content-security-policy'`. `test_the_request_id_header_survives_the_new_middleware` fails on the `x-frame-options` line only.

- [ ] **Step 3: Write the middleware**

Append to `app/src/bgd/api/middleware.py`. Raw ASGI, for the reason the module docstring already gives, and it appends headers in `http.response.start` exactly as the request-id header is appended:

```python
# One policy for the whole application, not just for the page. The JSON API
# gets it too, which costs nothing and means a header cannot be lost by a route
# being registered somewhere unexpected.
#
# No 'unsafe-inline' anywhere, which is the whole reason the page is three
# files rather than one (Phase 12 plan, D5). connect-src 'self' is what the
# banner's poll and the form's POST need, and nothing else is permitted to
# leave the page.
#
# form-action 'none' is correct and not an oversight: the form is submitted by
# fetch after preventDefault(), never by a native POST, so nothing legitimate
# needs a form action.
#
# One casualty, accepted: /docs. FastAPI's Swagger UI loads its script and
# stylesheet from a CDN, and default-src 'none' blocks both, so the page
# renders empty. /docs is a development affordance, /openapi.json is
# unaffected, and the alternative is a permanent hole in the policy on every
# production response.
SECURITY_HEADERS = (
    (
        b"content-security-policy",
        b"default-src 'none'; script-src 'self'; style-src 'self'; "
        b"connect-src 'self'; img-src 'none'; base-uri 'none'; "
        b"form-action 'none'; frame-ancestors 'none'",
    ),
    (b"x-content-type-options", b"nosniff"),
    (b"referrer-policy", b"no-referrer"),
    (b"x-frame-options", b"DENY"),
)


class SecurityHeadersMiddleware:
    """Append SECURITY_HEADERS to every HTTP response.

    Raw ASGI rather than BaseHTTPMiddleware, matching RequestContextMiddleware
    above: the two now both wrap send, and mixing the two styles would put an
    anyio task boundary between them for no gain.
    """

    def __init__(self, app: Callable) -> None:
        self.app = app

    async def __call__(self, scope: dict, receive: Callable, send: Callable) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_wrapper(message: dict) -> None:
            if message["type"] == "http.response.start":
                message["headers"] = [*message["headers"], *SECURITY_HEADERS]
            await send(message)

        await self.app(scope, receive, send_wrapper)
```

- [ ] **Step 4: Register it**

In `app/src/bgd/api/main.py`, extend the import and add one line:

```python
from bgd.api.middleware import RequestContextMiddleware, SecurityHeadersMiddleware
```

```python
    app.add_middleware(RequestContextMiddleware)
    # After RequestContextMiddleware, which in Starlette means *outermost*:
    # add_middleware prepends, and the first entry wraps the rest. So this one
    # sees the response last and appends its headers on top of the request-id
    # header the inner middleware has already added. Both land; the ordering
    # only matters if one ever wants to read what the other wrote.
    app.add_middleware(SecurityHeadersMiddleware)
    install_exception_handlers(app)
```

- [ ] **Step 5: Run the tests and see them pass**

```bash
make test
make lint
```

Expected: green, including every pre-existing API test — the headers are additive and no existing assertion enumerates response headers.

- [ ] **Step 6: Commit (propose; do not run without approval)**

```bash
git add app/src/bgd/api/middleware.py app/src/bgd/api/main.py app/tests/api/test_ui.py
git commit -m "feat(app): send a CSP with no unsafe-inline on every response"
```

**Verification:** `make test` green; against `make run-local`:

```bash
curl -sI http://localhost:8080/health | grep -iE 'content-security-policy|x-content-type-options|referrer-policy|x-frame-options'
```

All four present, and the CSP contains no `unsafe-inline`.

---

### Task 3: The UI router and the three static files

**Files:**
- Create: `app/src/bgd/api/routers/ui.py`, `app/src/bgd/api/static/index.html`, `app/src/bgd/api/static/app.css`, `app/src/bgd/api/static/app.js`
- Modify: `app/src/bgd/api/main.py`
- Test: `app/tests/api/test_ui.py`

**Interfaces:**
- Consumes: `/version`'s `release_color` (Task 1), and the four security headers (Task 2).
- Produces: `GET /` (`text/html; charset=utf-8`), `GET /app.css` (`text/css; charset=utf-8`), `GET /app.js` (`text/javascript; charset=utf-8`), all with `cache-control: no-store`. The module exports `router: APIRouter`.
- Consumed by: Task 5's image assertion, Task 6's smoke assertion, and the runbook.

- [ ] **Step 1: Write the failing route tests**

Append to `app/tests/api/test_ui.py`. Its import block grows to this — ruff's isort puts `pathlib` in the standard-library group and `bgd` in the first-party group, plain `import` before `from` within each:

```python
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import bgd.api
from bgd.api.main import create_app
from bgd.repository.memory import InMemoryLedgerRepository
```

Then the module-level constant and the cases:

```python
STATIC = Path(bgd.api.__file__).resolve().parent / "static"


def test_the_page_is_served_at_the_root(client) -> None:
    response = client.get("/")
    assert response.status_code == 200
    assert response.headers["content-type"] == "text/html; charset=utf-8"


def test_the_stylesheet_and_script_are_served(client) -> None:
    """Typed exactly, because nosniff makes the content type load-bearing.

    With X-Content-Type-Options: nosniff a stylesheet served as text/plain is
    not applied and a script served as text/plain is not executed — the page
    would render unstyled and untinted with no error anywhere but the console.
    """
    css = client.get("/app.css")
    assert css.status_code == 200
    assert css.headers["content-type"] == "text/css; charset=utf-8"

    js = client.get("/app.js")
    assert js.status_code == 200
    assert js.headers["content-type"] == "text/javascript; charset=utf-8"


@pytest.mark.parametrize("path", ["/", "/app.css", "/app.js"])
def test_the_page_and_its_assets_are_never_cached(client, path: str) -> None:
    """D8. A cached page shows the previous build's colour after a shift."""
    assert client.get(path).headers["cache-control"] == "no-store"


@pytest.mark.parametrize(
    ("path", "filename"),
    [("/", "index.html"), ("/app.css", "app.css"), ("/app.js", "app.js")],
)
def test_each_response_is_the_file_on_disk_byte_for_byte(client, path: str, filename: str) -> None:
    """D9's first structural rule: the server interpolates nothing.

    Not "the server escapes correctly" — the server has nothing to escape,
    because request-derived and database-derived data never enter these three
    responses at all. This is the assertion that keeps it that way.
    """
    assert client.get(path).content == (STATIC / filename).read_bytes()


def test_the_script_never_assembles_markup_from_strings(client) -> None:
    """D9's second structural rule, as a test rather than a promise.

    owner_name is user-supplied, stored, and rendered back. Every row is built
    with createElement plus textContent; one innerHTML assignment anywhere in
    this file would turn a stored name into stored script.
    """
    source = client.get("/app.js").text
    assert "innerHTML" not in source
    assert "outerHTML" not in source
    assert "insertAdjacentHTML" not in source
    assert "document.write" not in source


@pytest.mark.parametrize("path", ["/health", "/ready", "/version"])
def test_the_operational_routes_still_answer(client, path: str) -> None:
    """The UI router is prefix-free and registered last.

    A mistake in registration order is exactly the kind of thing that silently
    changes what the ALB target-group health check hits, and it would present
    as a deployment that never goes healthy rather than as a broken page.
    """
    assert client.get(path).status_code == 200


def test_the_page_is_not_in_the_openapi_schema(client) -> None:
    """Three HTML routes in the API schema would be noise in /openapi.json."""
    paths = client.get("/openapi.json").json()["paths"]
    assert "/" not in paths
    assert "/app.js" not in paths
```

- [ ] **Step 2: Run the tests and see them fail**

```bash
cd app && ./.venv/bin/python -m pytest tests/api/test_ui.py -v
```

Expected: the eleven new cases fail. `test_the_page_is_served_at_the_root` and the other route cases fail with `assert 404 == 200`; the byte-comparison cases fail with `FileNotFoundError` on `STATIC / "index.html"`. `test_the_operational_routes_still_answer` and `test_the_page_is_not_in_the_openapi_schema` pass already — they are regression guards, and a guard that is green before the change is doing its job.

- [ ] **Step 3: Write `app/src/bgd/api/static/index.html`**

```html
<!DOCTYPE html>
<html lang="en" data-release-color="unknown">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Blue/green deployment platform</title>
<!-- An empty data: icon, deliberately. Without it the browser requests
     /favicon.ico, the API answers with a 404 problem document, and img-src
     'none' logs a CSP violation on every load — console noise in front of an
     audience, for a file that does not exist. -->
<link rel="icon" href="data:,">
<link rel="stylesheet" href="/app.css">
<!-- defer, not inline. The CSP has no unsafe-inline (D5), and defer means the
     script runs after parsing with no DOMContentLoaded race to reason about. -->
<script src="/app.js" defer></script>
</head>
<body>

<header class="banner">
  <p class="banner__label">this page was served by build</p>
  <p class="banner__colour" id="release-color">…</p>
  <dl class="banner__facts">
    <dt>version</dt><dd id="version">…</dd>
    <dt>git_sha</dt><dd id="git-sha">…</dd>
    <dt>image_digest</dt><dd id="image-digest">…</dd>
    <dt>last checked</dt><dd id="last-checked">never</dd>
  </dl>
  <!-- The claim the page makes, narrower than the one a viewer will assume.
       The colour names the build, not the ECS target group. Phase 12, D2. -->
  <p class="banner__caveat">The colour names the build, not the target group.</p>
</header>

<main>
  <section class="card">
    <h1>Open an account</h1>
    <form id="create-account">
      <label for="owner-name">Owner name</label>
      <input id="owner-name" name="owner_name" type="text" required maxlength="120"
             autocomplete="off" placeholder="Ada Lovelace">

      <label for="currency">Currency</label>
      <!-- A select, not a free-text field: the schema demands ^[A-Z]{3}$ and a
           select cannot fail it. The error path is exercised by an empty owner
           name instead, which the API rejects with a problem document. -->
      <select id="currency" name="currency">
        <option value="EUR">EUR</option>
        <option value="GBP">GBP</option>
        <option value="USD">USD</option>
      </select>

      <label for="initial-balance">Opening balance (minor units)</label>
      <input id="initial-balance" name="initial_balance_minor" type="number"
             min="0" step="1" value="0">

      <button class="accent" type="submit">Open account</button>
    </form>
    <p class="alert" id="error" role="alert" hidden></p>
  </section>

  <section class="card">
    <h2>Accounts</h2>
    <ul class="accounts" id="accounts"></ul>
    <p class="empty" id="accounts-empty">No accounts yet.</p>
  </section>
</main>

</body>
</html>
```

- [ ] **Step 4: Write `app/src/bgd/api/static/app.css`**

The palette is keyed off one root attribute, which is what makes a live re-tint a single `setAttribute` call:

```css
/* The whole palette hangs off one attribute on <html>, set by app.js from
   /version. Changing the tint at runtime is therefore one setAttribute, and
   the page states its build identity in the banner as well as the button —
   this is going to be screenshotted and read from across a room.

   Contrast: every --accent below clears WCAG AA against #ffffff ink at the
   button's weight. If a colour is adjusted, that is the constraint to keep. */
:root[data-release-color="blue"]    { --accent: #1f6feb; --accent-ink: #ffffff; }
:root[data-release-color="green"]   { --accent: #1a7f37; --accent-ink: #ffffff; }
:root[data-release-color="slate"]   { --accent: #57606a; --accent-ink: #ffffff; }
/* Before the first successful poll, and after a failed one. Deliberately drab:
   an untinted page must not be mistaken for a deployed colour. */
:root[data-release-color="unknown"] { --accent: #d0d7de; --accent-ink: #24292f; }

:root {
  --page: #f6f8fa;
  --ink: #1f2328;
  --muted: #656d76;
  --line: #d0d7de;
  --card: #ffffff;
  --danger: #cf222e;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  padding: 0 0 3rem;
  background: var(--page);
  color: var(--ink);
  font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
}

.banner {
  background: var(--accent);
  color: var(--accent-ink);
  padding: 1.5rem 2rem;
}

.banner__label {
  margin: 0;
  font-size: 0.9rem;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  opacity: 0.85;
}

.banner__colour {
  margin: 0.2rem 0 0.8rem;
  font-size: clamp(2.5rem, 9vw, 5rem);
  font-weight: 800;
  letter-spacing: -0.02em;
  line-height: 1;
  text-transform: uppercase;
}

.banner__facts {
  display: grid;
  grid-template-columns: max-content 1fr;
  gap: 0.15rem 1rem;
  margin: 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
}

.banner__facts dt { opacity: 0.8; }
.banner__facts dd { margin: 0; overflow-wrap: anywhere; }

.banner__caveat {
  margin: 0.9rem 0 0;
  font-size: 0.8rem;
  opacity: 0.85;
}

main {
  display: grid;
  gap: 1.5rem;
  max-width: 46rem;
  margin: 2rem auto 0;
  padding: 0 1rem;
}

.card {
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: 10px;
  padding: 1.5rem;
}

h1, h2 { margin-top: 0; font-size: 1.25rem; }

form { display: grid; gap: 0.35rem; }

label {
  font-size: 0.85rem;
  font-weight: 600;
  color: var(--muted);
}

input, select {
  padding: 0.55rem 0.7rem;
  margin-bottom: 0.6rem;
  border: 1px solid var(--line);
  border-radius: 6px;
  font: inherit;
  background: var(--card);
  color: var(--ink);
}

button.accent {
  justify-self: start;
  padding: 0.7rem 1.6rem;
  border: 0;
  border-radius: 6px;
  background: var(--accent);
  color: var(--accent-ink);
  font: inherit;
  font-weight: 700;
  cursor: pointer;
}

button.accent:focus-visible { outline: 3px solid var(--ink); outline-offset: 2px; }

.alert {
  margin: 1rem 0 0;
  padding: 0.7rem 0.9rem;
  border-left: 4px solid var(--danger);
  background: #ffebe9;
  color: var(--danger);
  font-size: 0.9rem;
}

.accounts { list-style: none; margin: 0; padding: 0; }

.account {
  display: grid;
  grid-template-columns: 1fr max-content;
  gap: 0.1rem 1rem;
  padding: 0.7rem 0;
  border-bottom: 1px solid var(--line);
}

.account:last-child { border-bottom: 0; }
.account__name { font-weight: 600; }
.account__balance { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }

.account__origin {
  grid-column: 1 / -1;
  font-size: 0.75rem;
  color: var(--muted);
}

.empty { color: var(--muted); font-size: 0.9rem; }
```

- [ ] **Step 5: Write `app/src/bgd/api/static/app.js`**

Four jobs — poll, tint, submit, list — and no framework. Nothing in this file assembles markup from a string; Step 1's test enforces it:

```javascript
"use strict";

// The page learns which build served it rather than being told at render time.
// Phase 12 plan, D4: this is what lets a tab left open on the production
// listener re-tint itself the moment ECS moves the listener rule, with no
// reload — the difference between discovering a shift and watching one.

const FAST_INTERVAL_MS = 2000;
const SLOW_INTERVAL_MS = 10000;
const FAILURES_BEFORE_BACKOFF = 3;

// The closed set from the server's Literal (D6). A token the CSS has no rule
// for would drop the page to the "unknown" palette rather than to no palette.
const COLORS = ["blue", "green", "slate"];

let consecutiveFailures = 0;
let pollTimer = null;
let currentSha = "unknown";

// account_id -> the git_sha this tab was talking to when it POSTed. Client
// side only, and labelled as such: the API does not record which build created
// an account, and this page does not pretend otherwise. Plan D13.
const openedHere = new Map();

function setText(id, value) {
  document.getElementById(id).textContent = value;
}

function showError(message) {
  const box = document.getElementById("error");
  box.textContent = message;
  box.hidden = message === "";
}

function applyVersion(body) {
  const color = COLORS.includes(body.release_color) ? body.release_color : "unknown";
  document.documentElement.setAttribute("data-release-color", color);
  currentSha = body.git_sha;

  // textContent everywhere, including for values the server produced. The
  // habit is the mitigation; an exception "just here" is how the habit ends.
  setText("release-color", body.release_color);
  setText("version", body.version);
  setText("git-sha", body.git_sha);
  setText("image-digest", body.image_digest);
  setText("last-checked", new Date().toLocaleTimeString());
}

async function refresh() {
  const response = await fetch("/version", { cache: "no-store" });
  if (!response.ok) {
    throw new Error("/version answered " + response.status);
  }
  applyVersion(await response.json());
}

function scheduleNext() {
  const backedOff = consecutiveFailures >= FAILURES_BEFORE_BACKOFF;
  pollTimer = window.setTimeout(tick, backedOff ? SLOW_INTERVAL_MS : FAST_INTERVAL_MS);
}

async function tick() {
  // D7. Every poll is an ALB request and one access-log line; a hidden tab
  // pays that for nobody. A page left open across a teardown backs off too,
  // rather than hammering a dead load balancer until somebody closes it.
  if (document.visibilityState !== "visible") {
    scheduleNext();
    return;
  }

  try {
    await refresh();
    consecutiveFailures = 0;
  } catch (error) {
    consecutiveFailures += 1;
    // A stalled poller must be visible rather than silently stale: an old
    // colour on screen with no sign that it stopped updating is the one
    // failure mode that looks exactly like success.
    setText("last-checked", "unreachable");
  }
  scheduleNext();
}

function restartPolling() {
  if (pollTimer !== null) {
    window.clearTimeout(pollTimer);
    pollTimer = null;
  }
  tick();
}

function accountRow(account) {
  const row = document.createElement("li");
  row.className = "account";

  const name = document.createElement("span");
  name.className = "account__name";
  // Stored, user-supplied, and rendered back. textContent is the whole
  // mitigation, and it is why this row is assembled rather than formatted.
  name.textContent = account.owner_name;

  const balance = document.createElement("span");
  balance.className = "account__balance";
  balance.textContent = account.balance_minor + " " + account.currency;

  row.append(name, balance);

  const sha = openedHere.get(account.account_id);
  if (sha !== undefined) {
    const origin = document.createElement("span");
    origin.className = "account__origin";
    origin.textContent = "opened via build " + sha + " · this tab";
    row.append(origin);
  }

  return row;
}

async function listAccounts() {
  const response = await fetch("/api/accounts", { cache: "no-store" });
  if (!response.ok) {
    throw new Error("/api/accounts answered " + response.status);
  }
  const body = await response.json();

  const list = document.getElementById("accounts");
  list.replaceChildren(...body.items.map(accountRow));
  document.getElementById("accounts-empty").hidden = body.items.length > 0;
}

async function submitAccount(event) {
  // The CSP says form-action 'none'; this is what makes that consistent
  // rather than broken. The form is never natively submitted.
  event.preventDefault();
  showError("");

  const form = event.currentTarget;
  const payload = {
    owner_name: form.elements.owner_name.value,
    currency: form.elements.currency.value,
    initial_balance_minor: Number(form.elements.initial_balance_minor.value),
  };

  let response;
  try {
    response = await fetch("/api/accounts", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
      cache: "no-store",
    });
  } catch (error) {
    showError("the API could not be reached");
    return;
  }

  if (!response.ok) {
    // The API answers application/problem+json (errors.py), so the page can
    // surface the real message instead of "something went wrong".
    const problem = await response.json().catch(() => ({}));
    showError(problem.detail || "the API answered " + response.status);
    return;
  }

  const account = await response.json();
  openedHere.set(account.account_id, currentSha);
  form.reset();

  try {
    await listAccounts();
  } catch (error) {
    showError("the account was created, but the list could not be reloaded");
  }
}

document.getElementById("create-account").addEventListener("submit", submitAccount);
document.addEventListener("visibilitychange", restartPolling);

restartPolling();
listAccounts().catch(() => showError("the account list could not be loaded"));
```

- [ ] **Step 6: Write `app/src/bgd/api/routers/ui.py`**

```python
"""The demonstration page.

Three files, read once at import and served from memory. Not per request: the
production task runs with readonlyRootFilesystem (F6) and, more usefully, bytes
fixed at process start cannot vary by request — which is what makes "the server
interpolates nothing" a property rather than a claim (D9).

The page learns its own colour by fetching /version, so a tab left open on the
production listener re-tints itself when ECS moves the listener rule.
Templating it here would have made the colour a property of when the page was
loaded instead. Phase 12 plan, D4.
"""

from pathlib import Path

from fastapi import APIRouter, Response

# ../static from this module: the files live beside the api package, not beside
# the routers package, so this is parents[1] and not .parent.
STATIC = Path(__file__).resolve().parents[1] / "static"

INDEX_HTML = (STATIC / "index.html").read_text(encoding="utf-8")
APP_CSS = (STATIC / "app.css").read_text(encoding="utf-8")
APP_JS = (STATIC / "app.js").read_text(encoding="utf-8")

# D8. The one thing the page must never do is show a previous build's colour
# after a shift, which is exactly what a cached response would do — and it
# would look like the demonstration working.
NO_STORE = {"cache-control": "no-store"}

# include_in_schema=False on the router: these are not API, and three HTML
# routes in /openapi.json would be noise in a document Phase 8 publishes.
router = APIRouter(tags=["ui"], include_in_schema=False)


@router.get("/")
def index() -> Response:
    return Response(content=INDEX_HTML, media_type="text/html", headers=NO_STORE)


@router.get("/app.css")
def stylesheet() -> Response:
    return Response(content=APP_CSS, media_type="text/css", headers=NO_STORE)


@router.get("/app.js")
def script() -> Response:
    # text/javascript exactly. X-Content-Type-Options: nosniff means a wrong
    # type here is a script the browser refuses to execute, on a page whose
    # only behaviour is script.
    return Response(content=APP_JS, media_type="text/javascript", headers=NO_STORE)
```

- [ ] **Step 7: Register the router**

In `app/src/bgd/api/main.py`, extend the import and add the include **last**:

```python
from bgd.api.routers import accounts, health, transactions, ui
```

```python
    app.include_router(health.router)
    app.include_router(accounts.router)
    app.include_router(transactions.router)
    # Last, and prefix-free. Registered ahead of the others a future "/" route
    # could shadow an operational path — and the one it would shadow first is
    # /health, which is what the ALB target group polls. Ordering it last means
    # a collision is a 404 on the page rather than a service that never goes
    # healthy. tests/api/test_ui.py asserts all three still answer.
    app.include_router(ui.router)
```

- [ ] **Step 8: Run the tests and see them pass**

```bash
make test
make lint
```

Expected: green, coverage above 90. `ui.py` is executed at import by every API test, so all of its lines are covered.

- [ ] **Step 9: Look at it**

```bash
make run-local     # then open http://localhost:8080/
```

Check, in this order: the banner reads `slate` (D6 — a local process must not look deployed); "last checked" advances every two seconds; submitting the form adds a row; the row created in this tab carries `opened via build local · this tab`; clearing the owner name and submitting shows the API's own message from the problem document, not a generic one; the browser console is empty, in particular of CSP violations.

- [ ] **Step 10: Commit (propose; do not run without approval)**

```bash
git add app/src/bgd/api/routers/ui.py app/src/bgd/api/static app/src/bgd/api/main.py \
        app/tests/api/test_ui.py
git commit -m "feat(app): serve the demonstration page from the container"
```

**Verification:** `make test` green with coverage above 90; `make lint` green; the manual checks in Step 9 all observed.

---

### Task 4: The build

**Files:**
- Modify: `scripts/lib/common.sh`, `scripts/build-image.sh`, `scripts/verify-image-repeatability.sh`, `app/Dockerfile`

**Interfaces:**
- Consumes: `app/RELEASE_COLOR` (Task 1), and `Settings.release_color`'s default of `slate`.
- Produces: `RELEASE_COLOR` set by `image_build_identity()`; `--build-arg RELEASE_COLOR=…` in both build scripts; `BGD_RELEASE_COLOR` in the image environment.
- Consumed by: Task 5's image assertions and Task 6's smoke assertion.

- [ ] **Step 1: Derive it in `image_build_identity()`**

In `scripts/lib/common.sh`, inside `image_build_identity()`, immediately after the `APP_VERSION` derivation. Note it is **not** added to the `local` declaration on the first line of the function: the callers need it, exactly as they need `APP_VERSION`.

```bash
image_build_identity() {
  local root major_minor
  root="$(repo_root)"

  major_minor="$(tr -d '[:space:]' <"$root/app/VERSION")"
  APP_VERSION="${major_minor}.${CODEBUILD_BUILD_NUMBER:-0}"

  # Phase 12. Read from the repository rather than the environment, because a
  # build input that comes from the operator's shell is not a function of the
  # source — and design §4.1 requires that two clean builds of one commit
  # produce the same digest. A colour flip is therefore a commit that flows
  # through the real pipeline, not a setting somebody exports. Plan D3.
  RELEASE_COLOR="$(tr -d '[:space:]' <"$root/app/RELEASE_COLOR")"
```

Extend the function's header comment, which currently reads "Sets APP_VERSION, GIT_SHA, BUILT_AT, IMAGE_REF and exports SOURCE_DATE_EPOCH":

```bash
# Sets APP_VERSION, GIT_SHA, BUILT_AT, RELEASE_COLOR, IMAGE_REF and exports
# SOURCE_DATE_EPOCH.
```

- [ ] **Step 2: Pass it from both build scripts, in one commit**

F5 is the whole reason this is one step and not two. In `scripts/build-image.sh`, after the `BUILT_AT` argument:

```bash
  --build-arg "APP_VERSION=$APP_VERSION" \
  --build-arg "GIT_SHA=$GIT_SHA" \
  --build-arg "BUILT_AT=$BUILT_AT" \
  --build-arg "RELEASE_COLOR=$RELEASE_COLOR" \
  --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
```

The identical line in `scripts/verify-image-repeatability.sh`, inside `build_once()`, in the same position:

```bash
    --build-arg "APP_VERSION=$APP_VERSION" \
    --build-arg "GIT_SHA=$GIT_SHA" \
    --build-arg "BUILT_AT=$BUILT_AT" \
    --build-arg "RELEASE_COLOR=$RELEASE_COLOR" \
    --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
```

**Both, or neither.** Adding it only to `build-image.sh` makes `make image-verify` build the colourless default and compare it against a coloured image. Adding it only to the verifier is worse, because it fails in the passing direction: two colourless images compare equal and the check reports a property of an image nobody ships.

Then, in `scripts/build-image.sh`, add one line to the pre-build summary so the operator sees the colour before they push it:

```bash
info "building $IMAGE_REF"
dim "  platform           $PLATFORM"
dim "  release colour     $RELEASE_COLOR"
dim "  SOURCE_DATE_EPOCH  $SOURCE_DATE_EPOCH ($BUILT_AT)"
```

- [ ] **Step 3: Accept it in the Dockerfile**

In `app/Dockerfile`, the runtime stage's identity block. Extend the comment that is already there — it explains why `BGD_IMAGE_DIGEST` is deliberately absent, and this is the opposite case:

```dockerfile
# Build identity, surfaced by /version. BGD_IMAGE_DIGEST is deliberately absent:
# an image cannot carry its own digest, because the digest is its hash. Phases 5
# and 6 set it in the ECS task definition, which is the only place that knows
# which digest is actually deployed.
#
# RELEASE_COLOR is the opposite case, and Phase 12 added it for that reason: a
# value that *can* be a function of the source, and therefore is. It comes from
# app/RELEASE_COLOR in the repository rather than from the operator's shell, so
# the digest stays reproducible across machines (plan D3). The default matches
# the settings default, so a plain `docker build` — compose, or anything
# bypassing scripts/build-image.sh — produces a container that reports "slate"
# rather than one that fails validation at startup.
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG BUILT_AT=unknown
ARG RELEASE_COLOR=slate

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/app/src \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    BGD_APP_VERSION=${APP_VERSION} \
    BGD_GIT_SHA=${GIT_SHA} \
    BGD_BUILT_AT=${BUILT_AT} \
    BGD_RELEASE_COLOR=${RELEASE_COLOR}
```

- [ ] **Step 4: Check the shell parses, and build**

```bash
bash -n scripts/lib/common.sh scripts/build-image.sh scripts/verify-image-repeatability.sh
make build
```

Expected: the build summary now prints `release colour     blue`, and the build succeeds.

- [ ] **Step 5: Prove reproducibility survived, in both directions**

The identical-input direction first:

```bash
make image-verify
```

Expected: `✓ reproducible — both builds produced the same manifest digest`. If it fails, D3 has been implemented wrongly, and the likely cause is the colour reaching one build and not the other (F5). Record both digests.

Then the different-input direction, which is the half that proves the colour is genuinely a build input and not decoration:

```bash
cat app/dist/image-digest.txt          # the blue digest — record it
printf 'green\n' > app/RELEASE_COLOR
make build
cat app/dist/image-digest.txt          # must differ — record it
printf 'blue\n' > app/RELEASE_COLOR
make build
cat app/dist/image-digest.txt          # must equal the first — record it
```

Expected: digest 1 ≠ digest 2, and digest 3 = digest 1. All three go into Task 7's verification record as actual values, not as a description.

**The working tree must be back on `blue` before the commit.** Task 1's `test_release_color_is_one_of_the_three_tokens` passes either way, so nothing catches a stray `green` except this instruction and the diff.

- [ ] **Step 6: Commit (propose; do not run without approval)**

```bash
git status --short app/RELEASE_COLOR    # expect no output: it is back on blue
git add scripts/lib/common.sh scripts/build-image.sh \
        scripts/verify-image-repeatability.sh app/Dockerfile
git commit -m "build: carry the release colour from the repository into the image"
```

**Verification:** `bash -n` clean on all three scripts; `make build` prints the colour; `make image-verify` green; the three digests recorded, with 1 ≠ 2 and 3 = 1.

---

### Task 5: The image assertions

**Files:**
- Modify: `app/tests/image/test_image_metadata.py`, `app/tests/image/test_image_endpoints.py`

**Interfaces:**
- Consumes: everything Tasks 1, 3 and 4 produced, through a real container over real HTTP.

- [ ] **Step 1: Write the failing metadata assertion**

Append to `app/tests/image/test_image_metadata.py`, modelled exactly on `test_version_reports_the_injected_build_identity` (F9):

```python
def test_release_color_reaches_the_image(client: httpx2.Client) -> None:
    """The tint the demonstration rests on is a build argument like any other.

    If RELEASE_COLOR does not reach the image, the page renders the "slate"
    default and both listeners show the same colour during a shift — which
    looks like a blue/green failure and is not one. Two causes, one symptom;
    this is the test that rules out the boring cause before anybody starts
    reading CloudTrail for the interesting one.
    """
    expected = (APP_ROOT / "RELEASE_COLOR").read_text().strip()
    assert client.get("/version").json()["release_color"] == expected
```

- [ ] **Step 2: Write the failing packaging assertion**

Append to `app/tests/image/test_image_endpoints.py`. F4 argues from `.dockerignore` and the Dockerfile that `src/bgd/api/static/` ships automatically; this is the observation rather than the argument:

```python
def test_the_demonstration_page_ships_in_the_image(client: httpx2.Client) -> None:
    """F4 reasons that static/ is covered by `COPY src/`. This checks it.

    The failure mode if it is not: `make test` stays green, because the tests
    read the files from the working copy, and the deployed container answers
    500 on `/` — found in a browser rather than in CI.
    """
    page = client.get("/")
    assert page.status_code == 200, page.text
    assert page.headers["content-type"] == "text/html; charset=utf-8"

    for path, media_type in (("/app.css", "text/css"), ("/app.js", "text/javascript")):
        asset = client.get(path)
        assert asset.status_code == 200, path
        assert asset.headers["content-type"] == f"{media_type}; charset=utf-8"
        assert asset.headers["cache-control"] == "no-store"
```

- [ ] **Step 3: Run them**

```bash
make image-test
```

`image-test` depends on `build`, so this rebuilds first and the assertions run against the freshly built container. Expected: green, including both new tests.

To see them fail for the right reason before trusting them, temporarily revert Task 4's `--build-arg` line in `build-image.sh`, run `make image-test`, and observe `test_release_color_reaches_the_image` fail with `assert 'slate' == 'blue'`. Restore the line.

- [ ] **Step 4: Run the full offline gate**

```bash
make test && make lint && make build && make image-test && make image-verify
```

Expected: all five green, on a machine with no AWS session.

- [ ] **Step 5: Commit (propose; do not run without approval)**

```bash
git add app/tests/image/test_image_metadata.py app/tests/image/test_image_endpoints.py
git commit -m "test(image): assert the colour and the page reach the container"
```

**Verification:** `make image-test` green against the freshly built container; the deliberate-failure check in Step 3 observed; the five-command gate green.

---

### Task 6: `smoke.sh`'s fifth and sixth assertions

**Files:**
- Modify: `scripts/smoke.sh`

**Interfaces:**
- Consumes: `GET /` (Task 3) and `/version`'s `release_color` (Task 1) from a deployed environment.
- Produces: a failed deploy when the page is missing or the image is colourless. This is the check that runs on every staging deploy in the application pipeline.

- [ ] **Step 1: Capture `/version`'s body before adding anything**

`probe()` overwrites the shared `LAST_BODY`, and the existing digest check reads it on the assumption that `/version` was the last successful probe. The new checks must not disturb that. Immediately after the three existing `probe` calls:

```bash
probe /health 200 10
probe /ready 200 40
probe /version 200 10

# Held separately because LAST_BODY belongs to whichever probe ran last, and
# the digest check below already depends on that being /version's. The colour
# check needs the same body after further output has been written, so it takes
# its own copy rather than adding a second reader of a shared variable.
VERSION_BODY="$LAST_BODY"
```

- [ ] **Step 2: Add both checks, after the digest check**

At the end of the file, between the digest block and the final `if ((failures > 0))`:

```bash
# 5. The demonstration page is being served. Phase 12.
#
# --output /dev/null and a --write-out format, rather than probe(): this is the
# one check that cares about the content type, because X-Content-Type-Options
# is nosniff and a page served as anything but text/html renders as source.
printf '  %-10s ' "page"
page="$(curl --silent --show-error --max-time 10 --output /dev/null \
  --write-out '%{http_code} %{content_type}' "$BASE_URL/" 2>/dev/null)" || page=""
case "$page" in
  "200 text/html"*) mark_ok ;;
  "") mark_fail "no response within 10s"
     failures=$((failures + 1)) ;;
  *) mark_fail "expected 200 text/html, got '$page'"
     failures=$((failures + 1)) ;;
esac

# 6. The image carries a release identity, and it is not the local default.
#
# This is the useful half. A deployed container reporting "slate" means the
# build argument never reached the image and the deployment succeeded anyway —
# a green pipeline over a colourless demo, discovered in front of an audience.
# Here it is a failed smoke test on the deploy that caused it.
printf '  %-10s ' "colour"
if [[ -z "$VERSION_BODY" ]]; then
  mark_fail "no /version response to check"
  failures=$((failures + 1))
else
  reported="$(printf '%s' "$VERSION_BODY" | jq -r '.release_color // empty')"
  case "$reported" in
    blue | green) mark_ok ;;
    "") mark_fail "/version reports no release_color — this image predates Phase 12"
       failures=$((failures + 1)) ;;
    slate) mark_fail "/version reports 'slate' — RELEASE_COLOR never reached the image; check both --build-arg lines"
       failures=$((failures + 1)) ;;
    *) mark_fail "/version reports '$reported', which is not a release colour"
       failures=$((failures + 1)) ;;
  esac
fi
```

- [ ] **Step 3: Extend the header comment**

The block at the top of the file enumerates what each assertion rules out. Add both in the same form:

```bash
#   4. /version's image_digest equals the     the image Terraform intended is the
#      digest Terraform deployed              image actually serving traffic
#   5. / answers 200 as text/html             the demonstration page is being
#                                             served by the task itself, which
#                                             is what Phase 12 puts on a screen
#   6. /version's release_color is blue       the image carries a release
#      or green, never slate                  identity; "slate" is the default a
#                                             container reports when the build
#                                             argument never reached it, so a
#                                             deployed slate is a colourless
#                                             demo behind a green pipeline
#
# The fourth is the one that makes this a deployment check rather than a
# liveness check, and it is why Phase 8 runs this exact script after deploying
# to staging rather than inventing a smoke stage of its own. The sixth is the
# same idea applied to Phase 12's build input.
```

- [ ] **Step 4: Check it parses**

```bash
bash -n scripts/smoke.sh
```

- [ ] **Step 5: Run it offline against the built image**

Against `make run-image`, not `make run-local`: `run-local` runs from the host virtualenv with no build arguments and reports `slate`, so check 6 would correctly fail and prove nothing. The image was built from `app/RELEASE_COLOR` and reports `blue`.

In one terminal:

```bash
make build            # RELEASE_COLOR is blue
make local-tables
scripts/run-image.sh  # foreground, publishes 8081
```

In another:

```bash
BGD_SMOKE_URL=http://localhost:8081 \
BGD_SMOKE_DIGEST="$(cat app/dist/image-digest.txt)" \
  scripts/smoke.sh prod
```

Expected: all six checks green, ending `✓ prod is serving sha256:…`. `run-image.sh` passes `BGD_IMAGE_DIGEST` from `dist/image-digest.txt`, which is why check 4 passes here too. Nothing in this touches AWS: both values are supplied, so `smoke.sh` never invokes `terraform`.

Then see check 6 fail for the right reason — point the same command at `make run-local` on 8080, which reports `slate`:

```bash
BGD_SMOKE_URL=http://localhost:8080 BGD_SMOKE_DIGEST=unknown scripts/smoke.sh prod
```

Expected: checks 1, 2, 3 and 5 green; check 4 fails on the digest (`unknown`, expected locally) and check 6 fails with `/version reports 'slate' — RELEASE_COLOR never reached the image`.

- [ ] **Step 6: Commit (propose; do not run without approval)**

```bash
git add scripts/smoke.sh
git commit -m "test(smoke): fail a deploy that serves no page or no release colour"
```

**Verification:** `bash -n` clean; six green checks against `run-image.sh`; check 6 observed failing against `run-local`.

---

### Task 7: The runbook, the documentation, and the verification record

**Files:**
- Create: `docs/runbooks/phase-12-frontend-demo.md`, `docs/phases/phase12/2026-09-01-local-verification.md`
- Modify: `docs/runbooks/README.md`, `app/README.md`
- Verify and commit (already written, uncommitted — F11): `docs/2026-08-04-implementation-phase-roadmap.md`, `docs/phases/README.md`

**Interfaces:**
- Consumes: the digests recorded in Task 4 Step 5 and the command output from Tasks 1–6.
- Produces: the procedure that meets exit criterion 1, which this branch cannot meet (D1).

- [ ] **Step 1: Write `docs/runbooks/phase-12-frontend-demo.md`**

Follow the shape of `docs/runbooks/phase-06-prod-blue-green.md`: exact commands, expected output, and what to do when the output differs. Three sections.

**Header block**, matching the other runbooks: date, what it needs, what it costs, and companion links to this plan, the Phase 6 runbook and the isolation defect record. Write them as ordinary markdown links to these three targets — given here as paths rather than links because they are relative to `docs/runbooks/`, and `make docs-check` resolves a link against the directory of the file it appears in:

- `../phases/phase12/2026-09-01-phase-12-implementation-plan.md`
- `./phase-06-prod-blue-green.md`
- `../phases/phase6/2026-08-31-blue-green-does-not-isolate.md`

**Section A — the local preview. No AWS, no spend.**

```bash
# terminal 1 — the incumbent
printf 'blue\n' > app/RELEASE_COLOR
make build
make local-tables
scripts/run-image.sh                    # http://localhost:8081

# terminal 2 — the candidate
printf 'green\n' > app/RELEASE_COLOR
make build
PORT=8082 scripts/run-image.sh          # http://localhost:8082

# restore before committing anything
printf 'blue\n' > app/RELEASE_COLOR
```

Open both. Two windows, two colours, no AWS.

State the two honest limitations in the runbook itself, because a preview that oversells is worse than none:

- **The two windows will show the same `git_sha`.** Editing `app/RELEASE_COLOR` leaves the tree dirty, so `image_build_identity()` tags both builds `<sha>-dirty`. Only the pipeline path (section B) produces two genuinely different builds.
- **The second `make build` overwrites `app/dist/`.** The first container keeps running from the image it already has; `prune_orphaned_images` cannot remove an image with a running container and fails silently by design.

This section exists because it proves the *page* works independently of whether the *platform* does. F7 is why it is two builds rather than two compose services: compose passes no build arguments and both services would report `slate`.

**Section B — the real demonstration.**

1. Confirm production is healthy: `make smoke-prod`. Six green checks, and the colour check reports the incumbent's colour.
2. Open two browser windows side by side — `https://<api host>/` and `https://<api host>:8443/`. The test listener is directly reachable from any network (F2); no tunnel, no security-group change.
3. Flip the colour and push:
   ```bash
   printf 'green\n' > app/RELEASE_COLOR     # or blue, whichever is not current
   git commit -am "demo: flip the release colour"
   git push
   ```
   This is an `app/**` change, so it drives the application pipeline end to end, with one approval (roadmap §2.1).
4. Watch. **During the shift** the `:8443` window re-tints to the incoming colour while the `:443` window still shows the incumbent — two colours, one moment, one screenshot. **After the shift** the `:443` window re-tints **without a reload** (D4, D7), because the banner polls and the listener rule has moved under it.
5. Capture both windows, and save the pair under `docs/evidence/` beside `phase-06-exit-criterion-2.txt`.

Note in the runbook that this run is also the pipeline-path re-confirmation Phase 6's §7 left open (F10) — a colour flip *is* a pipeline deployment — and record the outcome there.

**Section C — reading it honestly, and what to do if both windows agree.**

Open with D2 in the same words the page uses: **the colour names the build, not the target group.** A green button means "the build whose `RELEASE_COLOR` file said green", not "the green target group". Which slot is serving is ECS's to assign, `prod/alb.tf` hands it over with `ignore_changes`, and `scripts/lint-infra.sh` fails the build if anyone takes it back.

Then the one troubleshooting entry this runbook needs. If both windows show the same colour there are exactly two causes, and `git_sha` in the two banners separates them in one look:

| Both windows show | `git_sha` in the two banners | Cause |
|---|---|---|
| the same colour | **different** | the build argument did not reach one image. Task 6's smoke check 6 should already have failed the staging deploy; check `app/RELEASE_COLOR` at that commit and both `--build-arg` lines (plan F5) |
| the same colour | **the same** | the listeners are not isolated — a regression of the defect closed on 2026-09-01. Go to §7 of the defect record (link it as `../phases/phase6/2026-08-31-blue-green-does-not-isolate.md`, relative to `docs/runbooks/`) and confirm `ignore_changes = [action]` is still on both rules in `alb.tf` |

The second row is why the banner shows `git_sha` at all, and why `scripts/lint-infra.sh` carries a textual guard for the `lifecycle` blocks that `terraform test` cannot see.

Add one more row for the case that will actually happen first:

| Symptom | Cause |
|---|---|
| the banner reads `slate` on a deployed host | the image was built without the build argument, or by `docker compose`. A deployed `slate` is check 6's failure; it is never correct |

- [ ] **Step 2: Add the runbook to `docs/runbooks/README.md`**

One row in the table, after Phase 11's. Link text: **The demonstration page: the local two-colour preview, the live shift, and reading it honestly**; target `./phase-12-frontend-demo.md`; phase column `12`. Same three-column shape as every row above it. (Given as parts rather than as a pasteable row for the same reason as Step 1: the target is relative to `docs/runbooks/`.)

And one paragraph after the Phase 9 one, because the README explains what each phase's runbook is *for*:

```markdown
Phase 12 adds the demonstration page and its runbook. It creates nothing: the
page ships inside the application image, both listener rules already match
`/*`, and the release colour arrives as a build argument rather than through
the task definition. The runbook's section B is also the pipeline-path
re-confirmation that Phase 6's §7 left open — a colour flip is an `app/**`
commit, so the demonstration and the re-confirmation are the same run.
```

- [ ] **Step 3: Verify the roadmap amendment, then commit it**

F11: the roadmap and `docs/phases/README.md` already carry this work in the working tree, uncommitted. Do not write it again. Confirm what is there:

```bash
git diff --stat docs/2026-08-04-implementation-phase-roadmap.md docs/phases/README.md
git diff docs/2026-08-04-implementation-phase-roadmap.md | grep -c '^+'
```

Expected: table row `| 12 | Demonstration frontend | 8 | — |`, the `### Phase 12 — Demonstration frontend` section with its exit criteria, "Twelve phases" → "Thirteen phases", the Phase 6 risk row updated to point at this phase, and `docs/phases/README.md` reading "thirteen phases". If any of the five is missing, add it in the style of the surrounding rows.

- [ ] **Step 4: Update `app/README.md`**

Three edits, all small, in the sections that already cover this ground:

Add a row to the **Endpoints** table, after `/version`:

```markdown
| `GET` | `/` | `200` `text/html` | — the demonstration page; `/app.css` and `/app.js` beside it |
```

Extend the `/version` paragraph in the same section:

```markdown
`/version` also reports `release_color`, which the page at `/` polls every two
seconds and tints itself from. **The colour names the build, not the ECS target
group** — which colour slot is serving is ECS's to assign, and nothing in a
task can read it. Two windows showing two colours during a shift is two
*builds* being reachable at two listeners, which is exactly what a blue/green
deployment is.
```

Add a paragraph to **The image**, after the `/version` reports paragraph:

```markdown
`release_color` comes from `app/RELEASE_COLOR`, a file in the repository rather
than an environment variable, so the digest stays a function of the source and
a colour flip is a real commit through the real pipeline. To see two colours
locally: build with `blue`, run `scripts/run-image.sh`, edit the file to
`green`, `make build` again, and run the second one with
`PORT=8082 scripts/run-image.sh`. Compose cannot do this — it passes no build
arguments, so both services would report `slate`.
```

- [ ] **Step 5: Run the full gate**

```bash
make test
make lint
make build
make image-test
make image-verify
make docs-check
```

`make docs-check` last and non-negotiable: this task adds two documents and a dozen cross-references, and the target exists because six links were once broken for weeks. It checks untracked markdown too, so the new runbook and verification record are covered before they land.

- [ ] **Step 6: Write `docs/phases/phase12/2026-09-01-local-verification.md`**

Match the shape of [the Phase 8 record](../phase8/2026-08-30-local-verification.md): a header block naming the branch and stating **AWS resources created: none**, then every command actually run with its actual output, then what it does and does not prove.

It must contain, at minimum:

1. The gate: the six commands from Step 5, with their real output pasted — not described.
2. The three digests from Task 4 Step 5, as values, with the two relations stated: blue ≠ green, and blue = blue.
3. The smoke run from Task 6 Step 5, both directions, with the six-check output.
4. A section headed **what this does not prove**, stating plainly that **exit criterion 1 is not met by this branch** and why (D1): a locally built page proves the page, not the platform. Two containers on one laptop are two builds on one machine; they are not two listeners in front of one ECS service, and only the runbook's section B can produce that.

- [ ] **Step 7: Commit (propose; do not run without approval)**

```bash
git add docs/runbooks/phase-12-frontend-demo.md docs/runbooks/README.md \
        docs/phases/phase12/2026-09-01-local-verification.md \
        docs/2026-08-04-implementation-phase-roadmap.md docs/phases/README.md \
        app/README.md
git commit -m "docs: the Phase 12 runbook, roadmap amendment and verification record"
```

**Verification:** all six gate commands green, with output pasted into the verification record; `make docs-check` reporting every relative link resolving.

---

## 4. Exit criteria

1. **During a production blue/green shift, the production listener and the test listener serve visibly different buttons, captured as a screenshot.**

   **Not met by this branch**, and not blocked either. It needs a deployment in flight, and this session creates no AWS resource (D1). It is met by the runbook, section B, which the Phase 6 fix of 2026-09-01 made reachable (F10). Section B doubles as the pipeline-path re-confirmation that Phase 6's §7 left open.

2. **`/version` on the deployed task reports a `release_color` equal to `app/RELEASE_COLOR` at the commit that built the image.**

   Met on the branch for a locally built container by Task 5, and in a deployed environment by Task 6's check 6, which runs on every staging deploy in the application pipeline.

3. **Two clean builds of one commit still produce the same manifest digest, and a colour change produces a different one.**

   Met on the branch by Task 4 Step 5, in both directions, with the digests recorded. This is Phase 2's exit criterion, re-proved because this phase adds a build input, and D3 is the argument for why it survives.

What the branch gates itself on:

| Check | Command | Covers |
|---|---|---|
| Application behaviour | `make test` | the setting's validation, `/version`'s new field and its `no-store`, all three UI routes and their content types, the four security headers, the CSP having no inline escape hatch, the served bytes matching disk, the absence of `innerHTML`, and the operational routes still answering |
| Coverage | `make test` | the 90% gate, with the new router and middleware included |
| Lint and format | `make lint` | ruff over the new module and the modified ones, `app/` and `lambdas/` |
| The image | `make image-test` | the build argument reached the container, and the three static files shipped in it |
| Reproducibility | `make image-verify` | design §4.1 survived a new build input |
| Shell | `bash -n` on the four modified scripts | the new lines parse |
| Smoke, offline | `scripts/smoke.sh` against `run-image.sh` | all six checks, including the two new ones, against a real container |
| Documentation | `make docs-check` | every new cross-reference resolves |

---

## 5. Risks this phase adds

| Risk | Handling |
|---|---|
| **The demonstration rests on a fix verified once, by hand** | F10. The Phase 6 fix was verified across three deployments with the colours alternating in both directions, which is strong — but by `scripts/tf.sh apply prod`, not through the pipeline, and §7 says so. Section B of the runbook closes that gap by construction, since a colour flip *is* a pipeline deployment. If it regresses, section C's table names the symptom and the file to look at. |
| **A same-colour reading has two causes** | Section C's `git_sha` table, and Task 6's check 6 failing the deploy on the boring one. Worth a row because "both windows are blue" in front of an audience is exactly when nobody wants to be deciding which of two explanations it is. |
| **"Green button" is read as "green target group"** | D2, and the same sentence repeated in `config.py`, on the page itself (`banner__caveat`), in the runbook and in `app/README.md`. The claim the page makes is deliberately narrower than the one a viewer will assume, so it is stated in every place a viewer might read. |
| **A row's "created by" label claims more than the API knows** | D13. The draft of this plan promised a per-row build attribution the wire format cannot support. The page now labels only the rows it created itself, and says `this tab` on them. The demonstration does not depend on the label. |
| **A new build input erodes reproducibility** | D3 puts the input in the repository rather than the environment; Task 4 Step 5 proves the digest in both directions with recorded values; `make image-verify` keeps proving it. The specific failure this avoids — the same commit producing two digests depending on who built it — is the one Phase 2 §F6 already found once. |
| **A half-applied build-argument change passes the check it should fail** | F5. `verify-image-repeatability.sh` duplicates the `--build-arg` list, and adding the argument only there would make the verifier compare two colourless images and report success. Task 4 Step 2 changes both files in one commit and says why. |
| **The page renders user-supplied data** | D9's two structural rules — the server never interpolates, the client never assembles markup from strings — both asserted by tests, under a CSP with no `unsafe-inline` (D5). The API surface is unchanged: the page is a client of endpoints that were already public. |
| **A cached response shows the wrong build** | D8, `no-store` on all four responses, asserted for all four. Called out as a risk rather than a detail because the failure mode is a demo that looks like it worked. |
| **`/docs` stops rendering** | Accepted, and argued in Task 2 Step 3. Swagger UI loads from a CDN that `default-src 'none'` blocks. `/openapi.json` is unaffected and the schema is unchanged, and the alternative is a permanent hole in the policy on every production response. Worth knowing before somebody opens `/docs` during a demo. |
| **Polling adds log volume** | D7 — 2s, paused when hidden, backed off to 10s after three failures. About 30 lines a minute per open tab into a 14-day log group, and zero when nothing is open. |
| **The colour becomes a second place to declare deployment state** | D10 forbids the task definition variable that would start it. Recorded because `BGD_RELEASE_COLOR` in `prod/ecs.tf` looks like an improvement and would hand the colour to exactly the layer D2 says must not own it. |
| **A colour flip is a production deployment** | Intended, and the point of D3 — but worth naming. Changing `app/RELEASE_COLOR` triggers the `app/**` pipeline and ships to production behind one approval, like any other application commit. It is not a display setting. |
| **The working tree is left on the wrong colour** | Task 4 Step 5 flips the file twice to prove the digest changes, and Task 7's section A flips it again. Both say to restore `blue`, and Task 4 Step 6 greps `git status` before committing. Nothing else catches it: `blue` and `green` are both valid, so a stray flip is a silent extra production deployment. |
