# scripts

The logic behind the `makefile`. Make is the discoverable front door; anything
longer than three lines, or needing a conditional or a loop, lives here.

| Script | Phase |
|---|---|
| `lib/common.sh` | 0 — shared helpers: logging, `require_cmd`, version comparison |
| `verify-tools.sh` | 0 — toolchain versions and repository version pins |
| `verify-aws.sh` | 0 — AWS session, account and region |
| `create-venv.sh` | 1 — the virtualenv, on the interpreter `.python-version` names |
| `compile-deps.sh` | 1 — recompile both hash-pinned requirements locks |
| `build-image.sh` | 2 — the reproducible image build; writes `app/dist/` |
| `generate-sbom.sh` | 2 — SBOM from the OCI archive with a digest-pinned syft |
| `verify-image-repeatability.sh` | 2 — two clean builds, one digest comparison |
| `run-image.sh` | 2 — run the built image against DynamoDB Local |
| `tf.sh` | 3 — per-layer terraform driver; `-backend=false` for fmt, validate and test |
| `lint-infra.sh` | 3 — tflint and checkov from digest-pinned containers |
| `seed-ecr.sh` | 3 — push the image, then record it as the tag both layers deploy |
| `install-terraform.sh` | 7 — the pinned Terraform install, for CodeBuild only |
| `pipeline-terraform.sh` | 7 — the infra pipeline's plan/apply driver, scope gate and plan summary |
| `push-image.sh` | 8 — the skopeo push and the digest assertion, factored out of `seed-ecr.sh` |
| `pipeline-app-build.sh` | 8 — the app pipeline's Build stage: test, image, SBOM, push, publish |
| `pipeline-deploy.sh` | 8 — the app pipeline's deploy driver, scope gate and the SSM record |

`push-image.sh` is `seed-ecr.sh` without the two SSM writes. The split exists
because the application pipeline's build needs the push and must **not** record
the tag — those parameters say what *is* deployed, so they are written after a
successful apply (Phase 8 §D9). Putting a second copy of the skopeo invocation
in a build script would have put two measured arguments — skopeo over `docker
push`, and the ECR token passed by name rather than by value — in two places,
where one can be fixed and the other forgotten. It takes the repository URL
from `$BGD_ECR_REPOSITORY_URL` when set, the same override shape `smoke.sh`
carries, so a build with no state backend can push.

`install-terraform.sh`, `pipeline-terraform.sh`, `pipeline-app-build.sh` and
`pipeline-deploy.sh` are the only scripts here that no `make` target calls. They are
entry points for CodeBuild, invoked by the buildspecs under `pipelines/`, and
they are in this directory rather than in that one for the reason the makefile
gives for its own three-line rule: a buildspec cannot be run locally, so logic
that lives in one is logic nobody can test before merging it.
`pipeline-terraform.sh` and `pipeline-deploy.sh` both call `tf.sh` for the
layer-name-to-directory mapping rather than carrying a fourth and fifth copy of
it, and both take their scope gate, plan summary and console deep link from the
same three helpers in `lib/common.sh`. That sharing is the point: a plan summary
formatted one way in the infra pipeline's approval and another way in the
application pipeline's would be a difference nobody chose.

`pipeline-app-build.sh` runs the test suite inside `python:3.14.6-slim` rather
than through `make test`, because CodeBuild's ARM image ships Python 3.11 and
3.12 and `create-venv.sh` refuses any interpreter that is not exactly the
`.python-version` pin. It is the same suites on the same interpreter against the
same hash-pinned locks — not literally the same command, and the file says so.
Both container digests are **read from `app/Dockerfile` and
`app/docker-compose.yml`** rather than copied, so a third pin cannot drift from
the two that already exist.

`lib/common.sh` also owns `image_build_identity`, which derives the version, git
SHA and both timestamps for a build. It is shared rather than duplicated because
`build-image.sh` and `verify-image-repeatability.sh` must agree exactly: if one
applied the `-dirty` suffix and the other did not, the repeatability check would
be proving a property of an image nobody ships.

The split exists because of Phase 10. `make teardown` destroys `prod` → `staging`
→ `network` in order, with confirmation prompts, error handling for a layer that
fails mid-destroy, and waits on ECS draining. That is real shell, and macOS's GNU
Make 3.81 has no `.ONESHELL`, so every recipe line would otherwise run in its own
subshell.

`lint-infra.sh` and `seed-ecr.sh` follow `generate-sbom.sh` in running their
tools from **digest-pinned containers** rather than host installs. Nothing to
install, no version for `verify-tools.sh` to drift against, and the identical
command works in the Phase 7 and 8 CodeBuild projects.

Scripts are sourced with `set -euo pipefail`. Note that a failing command
substitution aborts the script under `set -e`, so probes that report through a
non-zero exit — `pyenv version`, a `grep` that finds nothing — must use the `try`
helper in `lib/common.sh`.

**Progress goes to stdout; diagnostics go to stderr.** `info`, `ok` and `dim`
write to stdout. `warn`, `fail` and `die` write to stderr. Anything added to
`lib/common.sh` that reports a problem must keep that rule.

This is not a style preference. Until Phase 3, `fail()` and `die()` both wrote to
stdout, which meant a helper that died inside `"$(...)"` had its error message
captured into the variable being assigned — and under `set -e` the script then
exited 1 with **no message on any stream**. `tf.sh` hit it while being written.

`mark_ok`, `mark_fail` and `mark_warn` are the exception and stay on stdout: they
are the last column of a table row already printed there, and splitting a single
row across two streams scrambles it the moment either is redirected. There are
two colour palettes for the same reason — `C_*` keyed on `-t 1`, `E_*` on `-t 2`
— so `script > log` keeps colour on the errors still going to the terminal.

macOS ships **bash 3.2**, so `set -u` and arrays interact badly: expanding an
empty array as `"${arr[@]}"` is itself an unbound-variable error there. Use
`${arr[@]+"${arr[@]}"}`, as `run-image.sh` does for its optional `-it` flags.
This is the same 3.x-vintage constraint the makefile carries for GNU Make 3.81.
