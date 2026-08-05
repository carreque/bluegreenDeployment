# scripts

The logic behind the `makefile`. Make is the discoverable front door; anything
longer than three lines, or needing a conditional or a loop, lives here.

| Script | Phase |
|---|---|
| `lib/common.sh` | 0 — shared helpers: logging, `require_cmd`, version comparison |
| `verify-tools.sh` | 0 — toolchain versions and repository version pins |
| `verify-aws.sh` | 0 — AWS session, account and region |

The split exists because of Phase 10. `make teardown` destroys `prod` → `staging`
→ `network` in order, with confirmation prompts, error handling for a layer that
fails mid-destroy, and waits on ECS draining. That is real shell, and macOS's GNU
Make 3.81 has no `.ONESHELL`, so every recipe line would otherwise run in its own
subshell.

Scripts are sourced with `set -euo pipefail`. Note that a failing command
substitution aborts the script under `set -e`, so probes that report through a
non-zero exit — `pyenv version`, a `grep` that finds nothing — must use the `try`
helper in `lib/common.sh`.
