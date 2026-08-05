# pipelines — Phases 7 and 8

CodeBuild **buildspecs**. The CodeBuild projects that reference them are defined in
Terraform under `infra/foundation/`.

| Buildspec | Pipeline | Phase |
|---|---|---|
| infra validate / plan / apply | infra | 7 |
| app build, test, image, SBOM | app | 8 |

**Not to be confused with `.github/`.** A buildspec is CodeBuild's manifest format,
executed by CodeBuild inside the AWS account. `.github/workflows/` is GitHub
Actions' format, executed by GitHub's runners. Different engines, different
schemas. GitHub's only role in this design is source: CodeConnections grants
CodePipeline read access, and a push to `main` filtered by path triggers a run.
GitHub never deploys anything.
