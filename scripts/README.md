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
| `seed-ecr.sh` | 3 — copy the Phase 2 OCI archive into ECR, digest verified |
| `install-terraform.sh` | 7 — the pinned Terraform install, for CodeBuild only |
| `pipeline-terraform.sh` | 7 — the pipeline's plan/apply driver, scope gate and plan summary |

The last two are the only scripts here that no `make` target calls. They are
entry points for CodeBuild, invoked by the buildspecs under `pipelines/`, and
they are in this directory rather than in that one for the reason the makefile
gives for its own three-line rule: a buildspec cannot be run locally, so logic
that lives in one is logic nobody can test before merging it.
`pipeline-terraform.sh` still calls `tf.sh` for the layer-name-to-directory
mapping rather than carrying a fourth copy of it.

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
