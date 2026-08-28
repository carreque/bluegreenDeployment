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
| Teardown and rebuild — what survives, what does not, how long it takes | 10 |
| Repairing a broken pipeline definition by local apply | 7 |
| The three rollback demonstrations | 11 |

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
