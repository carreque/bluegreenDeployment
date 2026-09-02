# Controlled Deployment Platform with Blue/Green Strategy

A deployment platform for a business-critical fintech API: build, version, deploy
and validate a new release with materially lower risk, where operational stability
matters as much as delivery speed.

Built on AWS with Terraform. The centrepiece is **ECS-native blue/green
deployment** — no CodeDeploy — with Lambda lifecycle hooks and a separate ALB test
listener, so a new revision is validated against production-shaped traffic at
**zero user impact** before any real traffic shifts.

> **Status: all thirteen phases (0–12) delivered, executed against a real AWS
> account, and demonstrated.** The blue/green mechanism has been observed
> separating the colours across live deployments in both directions; the platform
> has been torn down and rebuilt from nothing; the demonstration page has been
> watched re-tinting itself mid-shift.
>
> **The account is currently torn down.** `prod`, `staging` and `network` do not
> exist; what survives is the state bucket, the hosted zone and the artifact
> bucket. `make rebuild` brings it back.

---

## How a release actually works

A merge to `main` is the release control. What happens next depends on the path.

```
app/**   merged → Build → DeployStaging → [approval] → Prod
infra/** merged → Validate → Foundation → Network → Staging → Prod   (four approvals)
```

Production deployments run through ECS's own `BLUE_GREEN` strategy. The shape
that makes it safe:

| Stage | What runs | What it rules out |
|---|---|---|
| `PRE_SCALE_UP` | Lambda checks `:443` is serving before anything scales | Starting a deployment into an environment already broken |
| **Test listener `:8443`** | The new revision is reachable, and only there | Real users meeting an unvalidated build |
| `POST_TEST_TRAFFIC_SHIFT` | The **dark canary** — Lambda drives the incoming revision through the test listener and fails the deployment on a bad answer | A broken build ever receiving production traffic |
| **Bake, 5 minutes** | Three CloudWatch alarms watch 5xx rate, p95 latency and unhealthy hosts | A build that passes a probe but degrades under real load |
| `POST_PRODUCTION_TRAFFIC_SHIFT` | Records the outcome for the release metrics | — |

**Which colour is serving is ECS's to decide, not Terraform's.** Both listener
rules carry `ignore_changes = [action]`, and `scripts/lint-infra.sh` fails the
build if anyone takes that back. This is not a stylistic choice — see
[the isolation defect](docs/phases/phase6/2026-08-31-blue-green-does-not-isolate.md),
which is what happens when Terraform re-asserts the assignment.

## Start here

| Document | What it covers |
|---|---|
| [Design and research](docs/2026-08-04-blue-green-deployment-platform-design-research.md) | Architecture, the decisions and why, cost, risks |
| [Phase roadmap](docs/2026-08-04-implementation-phase-roadmap.md) | Thirteen phases, dependencies, working agreement, and every amendment execution forced |
| [Runbooks](docs/runbooks/README.md) | Operational procedures, written to be followed under pressure by someone who did not write them |
| [Phase records](docs/phases/README.md) | One directory per phase: the implementation plan and the verification record |
| [Naming and tagging](docs/naming-and-tagging-convention.md) | Resource naming, the four required tags, cost allocation |
| [Architecture decisions](docs/adr/README.md) · [Evidence](docs/evidence/README.md) | The deviations worth defending, and the captured proof |

### Runbooks

| Runbook | Covers |
|---|---|
| [Bootstrap and foundation](docs/runbooks/phase-03-bootstrap-and-foundation.md) | The first apply, including all three irreducibly manual steps |
| [Network](docs/runbooks/phase-04-network.md) | Apply, NAT-egress proof, teardown |
| [Staging](docs/runbooks/phase-05-staging.md) | Apply, verification, teardown |
| [Production blue/green](docs/runbooks/phase-06-prod-blue-green.md) | The apply and the blue/green demonstration |
| [Infra pipeline](docs/runbooks/phase-07-infra-pipeline.md) | Both exit criteria, and repairing a broken pipeline by local apply |
| [App pipeline](docs/runbooks/phase-08-app-pipeline.md) | The apply, the exit criterion, both narrow-scope runs |
| [Observability](docs/runbooks/phase-09-observability.md) | The plane, a deliberate pipeline failure, the dashboard's first real data |
| [Teardown and rebuild](docs/runbooks/phase-10-teardown-and-rebuild.md) | What survives, what does not, how long it takes |
| [Frontend demo](docs/runbooks/phase-12-frontend-demo.md) | The local two-colour preview, the live shift, and reading it honestly |

## Local commands

`make` is the entry point; `scripts/` holds the logic.

```bash
make help          # every available command
make verify        # toolchain, version pins, and the AWS session
make test          # the application suite, with coverage
make tf-check      # the full pre-merge gate for infra/ — no AWS session needed
make build         # the reproducible image, with its digest recorded
make image-verify  # prove two clean builds produce the same digest
```

Requires Terraform ≥ 1.10, Python 3.14 and Docker. Exact versions are pinned in
[`.terraform-version`](.terraform-version) and [`.python-version`](.python-version),
and `make verify` fails if what is on `PATH` disagrees with them.

## Operating it

```bash
make rebuild         # apply network → staging → prod, then smoke both
make smoke-prod      # verify an environment over TLS
make teardown        # destroy prod → staging → network, in that order
make verify-idle     # prove nothing billable survived — reads AWS, never state
```

`teardown` and `verify-idle` are deliberately separate commands. Folded together,
"the destroy failed" and "the destroy succeeded but something survived" would be
the same red exit — and there would be no way to check an account nobody tore
down today.

Neither reaches `foundation` or `bootstrap`, by design. `/bgd/platform/deployed_scope`
records how deep the platform is applied, and both pipeline drivers clamp their
scope to it, so a merge landing while the platform is down skips the layers that
do not exist rather than recreating them. What tearing down `foundation` would
cost is [written out in full](docs/runbooks/phase-10-teardown-and-rebuild.md#10-what-this-runbook-cannot-do-tear-down-foundation)
rather than left as a flag on a script.

## Repository layout

```
app/          FastAPI service, tests, Dockerfile, demonstration page
infra/        Terraform, five independently-applied layers
lambdas       → infra/modules/lambda: lifecycle hooks, release metrics collector
pipelines/    CodeBuild buildspecs for both pipelines
scripts/      Logic behind the makefile
docs/         Design, roadmap, runbooks, phase records, evidence
```

Each directory carries its own `README.md` explaining what lands there and why.
[`infra/README.md`](infra/README.md) explains why there are five layers rather
than four — the short answer is that it is what makes destroy-when-idle possible:

```
bootstrap/     S3 state backend, native lockfile locking      never destroyed
foundation/    Route 53 zone, ACM, ECR, artifact bucket,      persistent  ~$1/mo
               SNS, CodeConnections, both pipelines,
               the observability plane
network/       VPC, subnets, IGW, NAT, endpoints              ephemeral  ~$34/mo
environments/staging/  ALB, ECS (rolling), DynamoDB           ephemeral  ~$25/mo
environments/prod/     ALB (:443 + :8443), ECS (BLUE_GREEN),  ephemeral  ~$40/mo
                       lifecycle hooks, bake alarms, DynamoDB
```

## Cost

Roughly **$105–135/month** running, falling to about **$1/month** when torn down —
a hosted zone and two near-empty buckets. Teardown and rebuild are first-class
deliverables, not an afterthought, and `make verify-idle` is what turns "we
destroyed it" into a claim with evidence behind it.

## What went wrong, and where it is written down

The platform was written offline and executed against a real account afterwards.
Four defects survived every mocked gate and were only found by running it. Each
has a permanent record, because a green offline gate can be green on a tautology:

- [Blue/green never separated the colours](docs/phases/phase6/2026-08-31-blue-green-does-not-isolate.md) — Terraform reverted ECS's colour assignment at the start of every deployment. The project's central claim was not true for four deployments. Two `lifecycle` blocks fix it.
- [The dark canary rolled back a good deployment on a TLS handshake](docs/phases/phase6/2026-08-31-dark-canary-transport-timeout.md) — a transport timeout read as a failed probe.
- [The `PRE_SCALE_UP` hook made the first deployment impossible](docs/phases/phase6/2026-08-31-pre-scale-hook-cold-start.md) — the check that rules out deploying into a broken environment cannot pass when there is no environment yet.
- [Zone adoption never adopted](docs/phases/phase3/2026-08-31-zone-adoption-defect.md) — a trailing dot. Terraform created a second hosted zone and ACM validation hung for its 75-minute timeout.

All four are closed and verified end to end against a real account.
