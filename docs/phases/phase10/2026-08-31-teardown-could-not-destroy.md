# Phase 10 — `make teardown` could not destroy either environment layer

**Date:** 2026-08-31
**Found:** the first time `make teardown` was run against a real account
**Files:** `scripts/lib/common.sh`, `scripts/teardown.sh`,
`scripts/tests/test_operator_scripts.sh`

```
==> terraform destroy — prod
│ Error: No value for required variable
│   on variables.tf line 41:
│   41: variable "image_tag" {
  ✗ destroy failed for prod; later layers were not touched.
```

The command whose entire purpose is destroying `prod` and `staging` could
destroy neither of them.

---

## 1. Cause

Both environment layers declare `image_tag` with **no default**, deliberately —
Phase 5 §D3: a stale default would silently deploy an old image. Terraform
requires a value for every declared variable on a **destroy** exactly as it does
on an apply.

`rebuild.sh` resolved the tag from SSM before each apply. `teardown.sh` passed no
variables at all. The two scripts were written in the same phase, to the same
plan, and diverged on the one input both needed.

## 2. Why nothing caught it

Two independent reasons, and both are worth keeping in mind for the rest of this
project's tooling:

1. **Phase 10 created no AWS resource.** Its exit criterion asked for *a full
   teardown and rebuild cycle executed and verified, not merely written*, and
   the phase's own amendment said plainly that the branch did not meet it. The
   cycle was never run until tonight.
2. **The shell suite drives a fake AWS CLI.** It proves the guards, the scope
   arithmetic and the refusals — 113 checks of real value — but a fake CLI
   answers every call and the suite therefore never reaches Terraform's own
   variable validation. **No amount of that suite could have found this**, which
   is not a criticism of it; it is the boundary of what an offline gate can do,
   and the reason the runbook exists.

## 3. The fix

`resolve_image_tag <layer>` moves into `lib/common.sh` rather than being copied
into `teardown.sh`, because the **divergence between the two scripts was the
defect** — a second copy would preserve the cause while fixing the symptom. This
is the same argument that moved `layer_dir` and the rank helpers into
`common.sh` in Phase 10 itself.

It resolves the real recorded tag rather than a placeholder, because a destroy
still refreshes `data.aws_ecr_image`, and a tag absent from the registry fails
the read before anything is destroyed.

Two regression checks were added, with an explicit note on what they do and do
not prove: they catch the wiring being removed or renamed again; they cannot
reproduce the original failure, because the suite never reaches Terraform. Only
the runbook can.

**Verified:** `make test-scripts` — **116 checks, 0 failed** (113 before), and a
real `make teardown SCOPE=prod` followed by `make rebuild SCOPE=prod` completed
against the account.

> **A correction, recorded rather than quietly fixed.** This section first
> claimed "119 checks (116 before)", having taken the *before* figure from [the
> Phase 10 amendment](../../2026-08-04-implementation-phase-roadmap.md)'s "116
> shell checks" instead of running the suite. The suite reported **113** before
> tonight and reports **116** now. The roadmap's figure was an overstatement of
> three when written, and the suite has only just grown into it — which is
> exactly the kind of number this project claims to measure rather than
> remember. Counted from source: 110 `check` invocations at `e3583cf` against 113
> now, the difference being the three added here; the runtime total runs three
> higher than the source count in both cases, because some checks sit inside
> loops.

## 4. A second defect found in the same command

`read_deployed_scope` failed once, transiently, and reported:

```
✗ cannot read /bgd/platform/deployed_scope — apply the foundation layer,
  which is what creates it
```

The parameter existed and `foundation` was applied. The function names **one**
cause for a call that fails many ways — an expired session, a throttle, a wrong
region, a genuinely absent parameter — and `2>/dev/null` discarded the only
evidence that distinguishes them. The operator was sent to apply a layer that
was already applied.

It now captures stderr, still names `foundation` specifically for
`ParameterNotFound` because that cause has a specific remedy, and otherwise
reports what AWS actually said.

The general form is worth carrying into the rest of the tooling: **a confident
diagnosis attached to a generic failure is worse than no diagnosis**, because it
sends the reader somewhere specific and wrong.

## 5. What the cycle did prove

The teardown and rebuild ran end to end once fixed — `prod` destroyed, `prod`
recreated from nothing, smoke-tested, marker restored to `all`. That is the
first half of Phase 10's exit criterion met for real.

The **marker behaved exactly as designed** under a failure, which is better
evidence than a clean run would have been: the failed destroy left
`/bgd/platform/deployed_scope` reading `staging` while prod was still fully
deployed. That is the safe direction — both pipelines skip a layer whose state is
unknown rather than deploying into it — and the error message said so at the
time.
