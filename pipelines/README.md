# pipelines — Phases 7 and 8

CodeBuild **buildspecs**. The CodeBuild projects that reference them are defined in
Terraform under `infra/foundation/`.

| Buildspec | Pipeline | Phase | Status |
|---|---|---|---|
| [`infra-validate.yml`](./infra-validate.yml) — `make tf-fmt-check tf-validate tf-test tf-lint` | infra | 7 | built |
| [`infra-plan.yml`](./infra-plan.yml) — plan one layer, export the summary | infra | 7 | built |
| [`infra-apply.yml`](./infra-apply.yml) — apply the saved plan | infra | 7 | built |
| [`app-build.yml`](./app-build.yml) — test, build, SBOM, push, publish | app | 8 | built |
| [`app-deploy.yml`](./app-deploy.yml) — apply one environment, record the tag | app | 8 | built |
| [`app-smoke.yml`](./app-smoke.yml) — `scripts/smoke.sh staging` against a URL passed in | app | 8 | built |
| [`app-plan.yml`](./app-plan.yml) — plan production, export the summary | app | 8 | built |
| [`app-apply.yml`](./app-apply.yml) — apply the saved production plan | app | 8 | built |

**Not to be confused with `.github/`.** A buildspec is CodeBuild's manifest format,
executed by CodeBuild inside the AWS account. `.github/workflows/` is GitHub
Actions' format, executed by GitHub's runners. Different engines, different
schemas. GitHub's only role in this design is source: CodeConnections grants
CodePipeline read access, and a push to `main` filtered by path triggers a run.
GitHub never deploys anything.

**The names are load-bearing.** Each pipeline's trigger watches its own
buildspecs — `pipelines/infra-*.yml` and `pipelines/app-*.yml` — so that editing
an application buildspec does not fire a four-approval infrastructure
deployment. A file added here under either prefix joins that pipeline's trigger
automatically; one named anything else joins neither, silently. Phase 8 §F4.

**Buildspecs here stay three lines.** The makefile states the convention for
this repository — make is the front door, scripts hold the logic — and it
applies here for a stronger reason: a buildspec cannot be run locally, so logic
that lives in one is logic nobody can test before merging it. The infra
buildspecs call `make` or `scripts/pipeline-terraform.sh`; the application
buildspecs call `scripts/pipeline-app-build.sh`, `scripts/pipeline-deploy.sh` or
`scripts/smoke.sh`. None of the eight branches.

Three of them end with `set -a && . ./<name>-vars.env && set +a`. That is not
decoration: the script is a child process, so its exports never reach the shell
CodeBuild reads `exported-variables` from. The scripts write the values to a
file and the buildspec sources them — and every script writes that file on
**every** path, the skip included, because a missing file would fail the build
and turn a correct skip into a red stage.
