#!/usr/bin/env bash
#
# Run the built image against DynamoDB Local.
#
# The counterpart to `make run-local`, which runs the same application from the
# host virtualenv. Running both at once is fine — this publishes 8081, so the
# two do not collide and can be curled side by side.
#
# BGD_IMAGE_DIGEST is passed here because this is the local stand-in for what
# Terraform does in Phases 5 and 6: the deployer knows the digest, the image
# cannot know its own.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker

ROOT="$(repo_root)"
DIST="$ROOT/app/dist"
PORT="${PORT:-8081}"

[[ -f "$DIST/image-ref.txt" ]] || die "no image — run 'make build' first"

IMAGE_REF="$(cat "$DIST/image-ref.txt")"
DIGEST="$(cat "$DIST/image-digest.txt" 2>/dev/null || echo unknown)"

info "running $IMAGE_REF on http://localhost:$PORT"
dim "  /version will report image digest $DIGEST"

# -it only when stdin really is a terminal. `docker run --tty` fails outright
# with "the input device is not a TTY" when this is piped, backgrounded or run
# from CI, which would otherwise turn a scripted smoke test into a hard error.
#
# The ${arr[@]+"${arr[@]}"} spelling is not decoration. macOS ships bash 3.2,
# where expanding an *empty* array as "${arr[@]}" under `set -u` is itself an
# unbound-variable error — the same 3.x-vintage constraint the makefile carries
# for GNU Make 3.81. This form expands to nothing when the array is empty.
TTY_FLAGS=()
[[ -t 0 ]] && TTY_FLAGS=(--interactive --tty)

exec docker run --rm ${TTY_FLAGS[@]+"${TTY_FLAGS[@]}"} \
  --publish "$PORT:8080" \
  --add-host "host.docker.internal:host-gateway" \
  --env "BGD_ENVIRONMENT=local" \
  --env "BGD_DYNAMODB_ENDPOINT_URL=http://host.docker.internal:8000" \
  --env "BGD_ACCOUNTS_TABLE=bgd-us-east-1-local-accounts" \
  --env "BGD_TRANSACTIONS_TABLE=bgd-us-east-1-local-transactions" \
  --env "BGD_IMAGE_DIGEST=$DIGEST" \
  "$IMAGE_REF"
