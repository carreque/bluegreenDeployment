# docs/runbooks — Phase 3 onward

Operational procedures, each written to be followed under pressure by someone who
did not write it: exact commands, expected output, and what to do when the output
differs.

Planned, in the order they are needed:

| Runbook | Phase |
|---|---|
| Bootstrap and foundation apply, including both manual steps | 3 |
| Teardown and rebuild — what survives, what does not, how long it takes | 10 |
| Repairing a broken pipeline definition by local apply | 7 |
| The three rollback demonstrations | 11 |

The project has exactly **two** irreducibly manual steps, both in Phase 3 — the
CodeConnections authorisation and activating the cost allocation tag keys in
Billing. The runbook states both plainly rather than burying them in a list, and
flags that tag activation is not retroactive.
