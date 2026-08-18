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

Scripts are sourced with `set -euo pipefail`. Note that a failing command
substitution aborts the script under `set -e`, so probes that report through a
non-zero exit — `pyenv version`, a `grep` that finds nothing — must use the `try`
helper in `lib/common.sh`.

macOS ships **bash 3.2**, so `set -u` and arrays interact badly: expanding an
empty array as `"${arr[@]}"` is itself an unbound-variable error there. Use
`${arr[@]+"${arr[@]}"}`, as `run-image.sh` does for its optional `-it` flags.
This is the same 3.x-vintage constraint the makefile carries for GNU Make 3.81.
