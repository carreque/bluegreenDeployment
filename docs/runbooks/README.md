# docs/runbooks — Phase 3 onward

Operational procedures, each written to be followed under pressure by someone who
did not write it: exact commands, expected output, and what to do when the output
differs.

Planned, in the order they are needed:

| Runbook | Phase |
|---|---|
| [Bootstrap and foundation apply, including all three manual steps](./phase-03-bootstrap-and-foundation.md) | 3 |
| [Network apply, NAT-egress verification and teardown](./phase-04-network.md) | 4 |
| [Staging apply, verification and teardown](./phase-05-staging.md) | 5 |
| [Production apply and the blue/green demonstration](./phase-06-prod-blue-green.md) | 6 |
| [The infra pipeline apply, both exit criteria, and repairing a broken pipeline definition by local apply](./phase-07-infra-pipeline.md) | 7 |
| [The app pipeline apply, the exit criterion, and both narrow-scope runs](./phase-08-app-pipeline.md) | 8 |
| [The observability plane apply, a deliberate pipeline failure, and the dashboard's first real data](./phase-09-observability.md) | 9 |
| [Teardown, the idle check, and the rebuild — what survives, what does not, how long it takes](./phase-10-teardown-and-rebuild.md) | 10 |
| The three rollback demonstrations | 11 |
| [The demonstration page: the local two-colour preview, the live shift, and reading it honestly](./phase-12-frontend-demo.md) | 12 |

From Phase 7 the infra pipeline applies `infra/`, and **merging to `main` is
what fires a deployment** (roadmap §2.1). The four manual approvals are what
stand between a merge and production. One consequence has its own step in the
Phase 7 runbook: the pipeline manages the layer that contains it, so a change
that breaks the pipeline definition cannot be repaired by the pipeline and
needs a local `make apply-foundation`.

From Phase 8 the same is true of `app/`, with **one** approval rather than
four — the compensating controls there are Phase 6's dark canary hook and bake
alarms, not more gates. Both pipelines live in `infra/foundation`, so both have
the repair caveat above, and **both survive a teardown**: after `make teardown`
they are still armed.

From Phase 10 that is safe rather than a hazard. `make teardown` lowers
`/bgd/platform/deployed_scope`, and both pipeline drivers clamp their own scope
to it, so a merge to `main` while the platform is down validates, applies
`foundation`, builds and pushes an image, and **skips every stage whose layer no
longer exists** — green, creating nothing, and not counted as a failed
deployment. There is nothing to disable and nothing to re-enable; `make rebuild`
raises the marker again as its last act on each layer. The corollary is
deliberate and worth knowing: a merge can no longer rebuild a torn-down layer.

Phase 9 adds the observability plane — one collector Lambda, two EventBridge
rules, a dashboard, and `alarm_actions` on Phase 6's four bake alarms — in the
same `infra/foundation` layer, so it also survives a teardown. From this phase
on, a wrong bake-alarm threshold is not only a mis-gated deployment; it is an
email at 3am, because those alarms now notify. The Phase 9 runbook's steps 8,
10 and 12 exist specifically to settle what could not be checked with no AWS
session: the real ECS event vocabulary, whether a dashboard widget's `SEARCH`
actually matches anything, and the real alarm thresholds under real traffic.

Phase 12 adds the demonstration page and its runbook. It creates nothing: the
page ships inside the application image, both listener rules already match
`/*`, and the release colour arrives as a build argument rather than through
the task definition. The runbook's section B is also the pipeline-path
re-confirmation that Phase 6's §7 left open — a colour flip is an `app/**`
commit, so the demonstration and the re-confirmation are the same run.

The project has exactly **three** irreducibly manual steps, all in Phase 3:
authorising the CodeConnections link, confirming the SNS email subscription, and
activating the cost allocation tag keys in Billing. The runbook states all three
plainly rather than burying them in a list.

> **Amended in Phase 3 (2026-08-24).** This said *two*, omitting the SNS
> confirmation — as did the roadmap and `infra/foundation/README.md`. An email
> subscription is created `PendingConfirmation` and stays there until the link
> is clicked; Terraform reports success and `plan` stays clean forever, so the
> omission is invisible until Phase 9's alerts fail to arrive.

Two of the three have no deadline. Tag activation does: a key only becomes
activatable once AWS has seen it on a real resource, so it cannot be done
earlier, and it is not retroactive, so every day of delay is spend that stays
permanently unattributed.

> **Amended in execution (2026-08-31).** Tag activation also cannot be done
> *immediately*, which no document said. Billing discovers user-defined keys on
> its own schedule — up to ~24 hours after it first bills a tagged resource — so
> right after the foundation apply there is nothing in the list to activate. It
> is still one of the three manual steps and still the one with a deadline; it
> simply belongs to the session **after** the one that creates the resources.
> The Phase 3 runbook's step 6 carries the poll command and the API form that
> cannot select the wrong capitalisation.
