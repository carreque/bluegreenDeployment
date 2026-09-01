# Runbook — Phase 12: the demonstration page

**Date:** 2026-09-01
**Layer:** `app/` only. No Terraform layer, no pipeline definition, no AWS
resource created by this phase.
**Needs:** for Section A, nothing but Docker and this repository. For Section
B, a healthy production environment from the Phase 6 runbook — the ALB, both
listeners, both target groups and a running service.
**Costs:** Section A costs nothing; it runs on one laptop. Section B costs a
production deployment, which is already running and already billed under
Phase 6's estimate — this runbook adds no new resource and no new spend.

**Companion documents:**
[the Phase 12 implementation plan](../phases/phase12/2026-09-01-phase-12-implementation-plan.md) ·
[the Phase 6 runbook](./phase-06-prod-blue-green.md) ·
[the blue/green isolation defect record](../phases/phase6/2026-08-31-blue-green-does-not-isolate.md)

---

## Section A — the local preview. No AWS, no spend.

This section proves the *page* works, independently of whether the *platform*
does. It builds two images from the same commit with two different values of
`app/RELEASE_COLOR` and runs them side by side on one machine.

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

**Two honest limitations, stated here because a preview that oversells is
worse than none:**

- **The two windows will show the same `git_sha`.** Editing `app/RELEASE_COLOR`
  leaves the working tree dirty, so `image_build_identity()` tags both builds
  `<sha>-dirty` — the same `<sha>`, because it is the same commit. The two
  local windows therefore differ in **colour** but show the **same
  `git_sha`**. Only the pipeline path (Section B) produces two genuinely
  distinct builds, because only there does a colour flip go through a commit.
- **The second `make build` overwrites `app/dist/`.** The first container
  keeps running from the image it already has — Docker holds its own copy —
  but `prune_orphaned_images` cannot remove an image with a running container
  and fails silently by design. Do not read a `prune_orphaned_images` skip
  during this section as an error.

F7 is why this is two builds rather than two `docker compose` services:
compose passes no build arguments, and both services would report `slate`.

---

## Section B — the real demonstration.

1. Confirm production is healthy:

   ```bash
   make smoke-prod
   ```

   Six green checks, and the colour check reports the incumbent's colour —
   `blue` or `green`, never `slate`.

2. Open two browser windows side by side — `https://<api host>/` and
   `https://<api host>:8443/`. The test listener is directly reachable from
   any network (F2); no tunnel, no security-group change.

   If the ALB was rebuilt recently, confirm the hostname still resolves to
   the current ALB before opening either window: a rebuild creates a new ALB,
   and a stale local resolver serving the destroyed one reads exactly like an
   unstable rollout. [The Phase 6 runbook](./phase-06-prod-blue-green.md)
   works around this with `curl --resolve`, but a browser has no equivalent —
   flush the resolver or re-check with `dig` first.

3. Flip the colour and push:

   ```bash
   printf 'green\n' > app/RELEASE_COLOR     # or blue, whichever is not current
   git commit -am "demo: flip the release colour"
   git push
   ```

   This is an `app/**` change, so it drives the application pipeline end to
   end, with one approval (roadmap §2.1).

4. Watch. **During the shift** the `:8443` window re-tints to the incoming
   colour while the `:443` window still shows the incumbent — two colours, one
   moment, one screenshot. **After the shift** the `:443` window re-tints
   **without a reload** (D4, D7), because the banner polls `/version` every
   two seconds and the listener rule has moved under it.

5. Capture both windows, and save the pair under `docs/evidence/` beside
   `phase-06-exit-criterion-2.txt`.

This run is also the pipeline-path re-confirmation Phase 6's §7 left open
(F10) — a colour flip *is* a pipeline deployment. Record the outcome of that
re-confirmation here as well as the screenshot pair: whether the colours
alternated as expected, and whether the production listener held the
incumbent for the whole test-shift window.

---

## Section C — reading it honestly, and what to do if both windows agree.

**The colour names the build, not the target group.** A green button means
"the build whose `RELEASE_COLOR` file said green", not "the green target
group". Which slot is serving is ECS's to assign, `prod/alb.tf` hands it over
with `ignore_changes`, and `scripts/lint-infra.sh` fails the build if anyone
takes it back.

The one troubleshooting entry this runbook needs. If both windows show the
same colour there are exactly two causes, and `git_sha` in the two banners
separates them in one look:

| Both windows show | `git_sha` in the two banners | Cause |
|---|---|---|
| the same colour | **different** | the build argument did not reach one image. Task 6's smoke check 6 should already have failed the staging deploy; check `app/RELEASE_COLOR` at that commit and both `--build-arg` lines (plan F5) |
| the same colour | **the same** | the listeners are not isolated — a regression of the defect closed on 2026-09-01. Go to [§7 of the defect record](../phases/phase6/2026-08-31-blue-green-does-not-isolate.md#7-resolution-2026-09-01) and confirm `ignore_changes = [action]` is still on both rules in `alb.tf` |

The second row is why the banner shows `git_sha` at all, and why
`scripts/lint-infra.sh` carries a textual guard for the `lifecycle` blocks
that `terraform test` cannot see.

One more row, for the symptom that will actually happen first:

| Symptom | Cause |
|---|---|
| the banner reads `slate` on a deployed host | the image was built without the build argument, or by `docker compose`. A deployed `slate` is check 6's failure; it is never correct |
| `make rebuild` stops at staging, with checks 5 and 6 red | the image being restored predates Phase 12. `scripts/rebuild.sh` takes its tag from `/bgd/<env>/image_tag` — the last thing actually deployed — so the first rebuild after this phase merged restores an image with no page and no `release_color`. Since 2026-09-01 both checks **warn** rather than fail on that image and the rebuild continues; if you are on an older `smoke.sh`, run `make build && make seed-ecr` first to record a Phase 12 tag |
| a rollback to an older image reports checks 5 and 6 red | the same cause, and the same fix. Phase 11 restores pre-Phase-12 images on purpose; a correct rollback must not read as a broken deploy |
