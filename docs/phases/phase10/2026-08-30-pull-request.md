# Phase 10 — pull request description

**Date:** 2026-08-30
**Branch:** `feat/Phase10_TeardownRebuild` → `main`
**Title:** feat(phase10): teardown and rebuild automation, and the marker that stops a merge redeploying a torn-down account
**Companion documents:**
[implementation plan](./2026-08-30-phase-10-implementation-plan.md) ·
[local verification record](./2026-08-30-local-verification.md) ·
[runbook](../../runbooks/phase-10-teardown-and-rebuild.md)

Recorded here because the description is the one summary of this phase written
for a reviewer rather than for an implementer, and a pull request body lives on
a forge rather than in the repository it describes. The sections below follow
`.github/PULL_REQUEST_TEMPLATE.md` exactly, so this file can be pasted into the
PR unchanged.

---

## Description

Makes "destroy when idle" a command rather than a discipline. Three operator scripts over one new piece of shared state.

`make teardown` destroys `prod` → `staging` → `network` behind **one typed confirmation** instead of three consecutive Terraform prompts, skips a layer whose state is already empty, and prints a measured timing table. `make rebuild` is the way back — `network` → `staging` → `prod`, taking `image_tag` from SSM rather than a gitignored `terraform.tfvars`, and smoke-testing each environment as it lands, so staging failing aborts before prod applies. `make verify-idle` proves nothing billable survived by reading AWS directly and **opening no state file** — state is exactly what is wrong in the three cases that check exists for. All three take `SCOPE` to stop earlier, and no `SCOPE` value or flag on any of them reaches `foundation` or `bootstrap`.

The shared state is `/bgd/platform/deployed_scope`, one SSM parameter in `foundation` holding `foundation | network | staging | all`. Teardown lowers it **before** the first destroy; rebuild raises it **after each** layer. Both pipeline drivers clamp their own scope to it, so a merge to `main` while the platform is torn down validates, applies `foundation`, builds and pushes an image, and **skips every stage whose layer no longer exists — green**, so Phase 9's change-failure-rate does not count it. This closes by name the gap Phase 8's runbook §11 handed to this phase: there is no longer anything to disable in the console after a teardown, and nothing to re-enable before a rebuild. The corollary is deliberate and worth knowing before merging — **a merge can no longer rebuild a torn-down layer**; `make rebuild` is the only thing that raises the marker, and the new runbook's §9 has the one-line escape hatch.

Everything was written and verified with **no AWS session** — `aws sts get-caller-identity` returns `InvalidClientTokenId` throughout — and **no AWS resource was created**. `make test-scripts` is new and adds **116 checks across three files, 0 failed**; it joins both the offline gate and `pipelines/infra-validate.yml`'s Validate stage, first, because it is pure bash with no container and the scripts it tests are the scripts that stage runs. It is deliberately not `bats`: a harness that has to be installed is a harness the offline gate cannot depend on. `make tf-check` reports `all infra checks passed` with `foundation` at 76 passed / 0 failed, `make test-lambdas` 45 passed at 97.46% coverage, and checkov 490 passed / **0 failed** / 110 skipped — a delta of exactly one pass and one skip from Phase 9's baseline, both from the single resource this branch adds.

**The exit criterion is not met by this branch**, and neither is the roadmap's fourth task-list bullet asking for an executed cycle. Both need a real teardown and a real rebuild against a live account. They are met by the new runbook's steps 3–6, ending with `make rebuild` exiting 0 — which by design happens only after both environments were smoke-tested and served the digest Terraform deployed. That is stated plainly in the roadmap amendment and in the verification record rather than letting a green gate imply a proven cycle.

Deliberately unchanged: no IAM role, no pipeline stage, no application code, and **no new trigger pattern** — the infra trigger stays at seven of its eight permitted `filePaths.includes`, because the three watched files this branch edits are already matched and the operator scripts are not pipeline content.

Two notes on the boxes below. **Breaking:** a merge to `main` after a teardown no longer recreates the destroyed layers — the point of the phase rather than a regression, but it changes what a merge does and should not be discovered by surprise. **Refactoring:** the layer-name-to-directory map moved out of three scripts into `lib/common.sh` as `layer_dir()`, since `rebuild.sh` would have been its fourth copy and `tf.sh`'s own comment asked for the move; `lint-infra.sh` keeps a variant, because its contract differs.

## Phase Addressed

**Phase 10 — Teardown and rebuild automation.** The roadmap's Phase 10 section is amended in this branch, with cross-phase notes added to the Phase 7 and Phase 8 sections for the pipeline clamp, and Phase 8's runbook §11 rewritten.

## Type of change

- [ ] Bug fix (non-breaking change which fixes an issue)
- [x] New feature (non-breaking change which adds functionality)
- [x] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [x] Refactoring
- [x] Documentation update

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013PXjHDN5cL8QFb1no9iVCG
