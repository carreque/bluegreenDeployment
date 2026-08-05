# Controlled Deployment Platform with Blue/Green Strategy

A deployment platform for a business-critical fintech API: build, version, deploy
and validate a new release with materially lower risk, where operational stability
matters as much as delivery speed.

Built on AWS with Terraform. The centrepiece is **ECS-native blue/green
deployment** — no CodeDeploy — with Lambda lifecycle hooks and a separate ALB test
listener, so a new revision is validated against production-shaped traffic at
**zero user impact** before any real traffic shifts.

> **Status: Phase 0 of 11 complete.** Prerequisites verified and the repository
> scaffolded. No AWS resources exist yet. This README is a stub; the full version
> is a Phase 11 deliverable.

---

## Start here

| Document | What it covers |
|---|---|
| [Design and research](docs/2026-08-04-blue-green-deployment-platform-design-research.md) | Architecture, the decisions and why, cost, risks |
| [Phase roadmap](docs/2026-08-04-implementation-phase-roadmap.md) | Twelve phases, dependencies, working agreement |
| [Naming and tagging](docs/naming-and-tagging-convention.md) | Resource naming, the four required tags, cost allocation |
| [Phase 0 plan](docs/phases/phase0/2026-08-04-phase-00-implementation-plan.md) · [findings](docs/phases/phase0/2026-08-04-phase-00-verification-findings.md) | What was verified before anything was built, and what it changed |

## Local commands

`make` is the entry point; `scripts/` holds the logic.

```bash
make help      # every available command, plus what each later phase adds
make verify    # toolchain, version pins, and the AWS session
```

Requires Terraform ≥ 1.10, Python 3.14 and Docker. Exact versions are pinned in
[`.terraform-version`](.terraform-version) and [`.python-version`](.python-version),
and `make verify` fails if what is on `PATH` disagrees with them.

## Repository layout

```
app/          FastAPI service, tests, Dockerfile          Phases 1-2
infra/        Terraform, five independently-applied layers Phases 3-6
lambdas       → infra/modules/lambda, lifecycle hooks      Phases 6, 9
pipelines/    CodeBuild buildspecs                         Phases 7-8
scripts/      Logic behind the makefile                    Phase 0+
docs/         Design, ADRs, runbooks, evidence
```

Each directory carries its own `README.md` explaining what lands there and when.
`infra/README.md` explains why there are five layers rather than four — the short
answer is that it is what makes destroy-when-idle possible.

## Cost

Roughly **$105–135/month** running, falling to about **$1/month** when torn down.
Teardown and rebuild are first-class deliverables (Phase 10), not an afterthought.
