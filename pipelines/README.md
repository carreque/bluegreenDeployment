# pipelines — Phases 7 and 8

CodeBuild **buildspecs**. The CodeBuild projects that reference them are defined in
Terraform under `infra/foundation/`.

| Buildspec | Pipeline | Phase | Status |
|---|---|---|---|
| [`infra-validate.yml`](./infra-validate.yml) — `make tf-fmt-check tf-validate tf-test tf-lint` | infra | 7 | built |
| [`infra-plan.yml`](./infra-plan.yml) — plan one layer, export the summary | infra | 7 | built |
| [`infra-apply.yml`](./infra-apply.yml) — apply the saved plan | infra | 7 | built |
| app build, test, image, SBOM | app | 8 | planned |

**Not to be confused with `.github/`.** A buildspec is CodeBuild's manifest format,
executed by CodeBuild inside the AWS account. `.github/workflows/` is GitHub
Actions' format, executed by GitHub's runners. Different engines, different
schemas. GitHub's only role in this design is source: CodeConnections grants
CodePipeline read access, and a push to `main` filtered by path triggers a run.
GitHub never deploys anything.

**Buildspecs here stay three lines.** The makefile states the convention for
this repository — make is the front door, scripts hold the logic — and it
applies here for a stronger reason: a buildspec cannot be run locally, so logic
that lives in one is logic nobody can test before merging it. The infra
buildspecs call `make` or `scripts/pipeline-terraform.sh`; neither branches.
