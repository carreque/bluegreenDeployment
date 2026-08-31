# Phase 5 — the smoke test raced the rollout it was testing

**Date:** 2026-08-31
**Found:** the application pipeline's `Smoke` action, on a healthy deployment
**Fixed:** `wait_for_steady_state = true` on `aws_ecs_service.api`
**Files:** `infra/environments/staging/ecs.tf`,
`infra/environments/staging/tests/compute.tftest.hcl`

```
==> smoke — staging
  /health    ✓
  /ready     ✓
  /version   ✓
  digest     ✗ serving sha256:b477abea…, Terraform deployed sha256:d593cc5f…
```

Three checks green, the fourth red, on a deployment that was correct and
finished seconds later.

---

## 1. What happened

`terraform apply` on this layer returned as soon as ECS accepted the new task
definition. The `Smoke` action runs immediately after it, and
`scripts/smoke.sh`'s fourth assertion compares the digest **being served**
against the digest **Terraform deployed**. The rolling replacement was still in
flight, so smoke read the previous task's `/version` and reported a mismatch.

## 2. This file already said so

The gap was written down in Phase 5, in a comment about something else — the
`depends_on` block that orders the IAM policies before the service:

> *"…deployment_circuit_breaker below has rollback = true but no previous task
> set to roll back to on a first apply, and there is no `wait_for_steady_state`,
> so `terraform apply` reports SUCCESS while the service never actually
> stabilises."*

That was an accurate observation about IAM propagation on a first apply. Its
consequence arrived three phases later, when Phase 8 attached a smoke test to
this apply and nobody re-read the comment. **The observation and the thing it
invalidated were separated by three phases and one file.**

Worth naming as a pattern rather than an incident: a caveat recorded in passing,
in a comment whose subject is something else, is not a caveat the next phase will
find.

## 3. It fails closed, which is why nothing shipped wrong

The assertion can only pass when the intended digest is actually being served.
So no bad deployment was ever waved through — the failure mode is entirely in
the other direction: **good deployments go red at random**, depending on whether
the rollout happened to beat the check.

That is not harmless. A pipeline that reddens for reasons unrelated to the change
is a pipeline whose failures stop being read, and the habit it teaches — re-run
it and see — is exactly the habit that lets a real failure through. This one
already cost a production deployment window while it was diagnosed.

## 4. The fix

`wait_for_steady_state = true`, which prod has carried since Phase 6 for the
argument its §D11 makes — *an apply must not report success over a deployment
that rolled back*. The same sentence covers this case: an apply must not report
success over a deployment that has not happened yet.

It does not weaken staging's stated job of failing fast. The circuit breaker
still ends a bad rollout rather than retrying it forever; the difference is that
the ending now reaches the caller instead of being reported as success.

`compute.tftest.hcl` gains
`the_apply_does_not_return_before_the_rollout_is_done`, which asserts the
setting and carries the reason, so removing it fails the offline gate rather than
resurfacing as a random red pipeline months later.

**Verified:** `terraform test` on staging — 17 passed, 0 failed (16 before).
