#!/usr/bin/env bash
#
# The application pipeline's Build stage: test, build, SBOM, push, publish.
#
#   scripts/pipeline-app-build.sh
#
# Called only from CodeBuild, by pipelines/app-build.yml. Every step it runs is
# a script a laptop already runs — build-image.sh, generate-sbom.sh,
# push-image.sh — so what this file contributes is the ordering, the test
# environment, and the two variables the later stages interpolate.
#
# It runs under every APP_SCOPE. Build is the one stage with no scope
# condition: deploying an image that was never built is the failure the stage
# ordering exists to prevent, so there is nothing for a gate here to skip.
#
# ---------------------------------------------------------------------------
# Why the tests run in a container rather than through `make test`
# ---------------------------------------------------------------------------
#
# CodeBuild's aws/codebuild/amazonlinux-aarch64-standard:3.0 provides Python
# 3.11 and 3.12 as managed runtimes. .python-version pins 3.14.6, and
# scripts/create-venv.sh accepts a PATH interpreter ONLY when it matches that
# pin exactly — deliberately, per Phase 1 §F1. So `make deps`, and therefore
# `make test`, cannot run in this container. The two ways to make them run —
# building CPython 3.14.6 from source, or installing a third-party version
# manager — are both several minutes and a new dependency for a problem this
# project has already solved four times. Plan §F3 and §D10.
#
# So pytest runs inside python:3.14.6-slim, the same digest app/Dockerfile
# pins, networked to amazon/dynamodb-local, the same digest
# app/docker-compose.yml and .github/workflows/pr-validate.yml both pin. Same
# interpreter, same --require-hashes locks, same three suites, same coverage
# gate.
#
# Stated plainly because the alternative is to overclaim: this is NOT literally
# the `make test` command. It is the same test run, reached differently, and
# the difference is the venv.
#
# ---------------------------------------------------------------------------
# The two image digests are READ from the files that already pin them
# ---------------------------------------------------------------------------
#
# A departure from the plan's literal text, and in the direction the plan's own
# reasoning points: it says a third pin that can drift from the other two is
# worse than no pin, then asks for a third pin with a comment saying where it
# came from. Reading them removes the drift rather than documenting it. If
# either file's shape changes, this fails loudly here with a message naming the
# file, which is the good failure — the bad one is a stale copy silently
# testing against a different interpreter than the image ships.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker
require_cmd aws
require_cmd git

ROOT="$(repo_root)"
APP="$ROOT/app"
DIST="$APP/dist"
VARS_FILE="$ROOT/build-vars.env"

# The patterns below anchor on the ARG name and the service name rather than on
# a registry, because both images moved off Docker Hub on 2026-08-31 and a
# pattern that hard-codes `python:` or `amazon/` silently extracts NOTHING after
# such a move — which the `die` below turns into a loud failure, but only after
# a build has already been spent finding out.
PYTHON_IMAGE="$(sed -n 's/^ARG BASE_IMAGE=\([^[:space:]]*@sha256:[0-9a-f]\{64\}\)$/\1/p' "$APP/Dockerfile" | head -1)"
[[ -n "$PYTHON_IMAGE" ]] ||
  die "cannot read the base image pin from app/Dockerfile — the tests must run on the interpreter the image ships"

DYNAMODB_LOCAL="$(sed -n 's|^[[:space:]]*image:[[:space:]]*\([^[:space:]]*dynamodb-local@sha256:[0-9a-f]\{64\}\)[[:space:]]*$|\1|p' "$APP/docker-compose.yml" | head -1)"
[[ -n "$DYNAMODB_LOCAL" ]] ||
  die "cannot read the DynamoDB Local pin from app/docker-compose.yml"

[[ -n "${BGD_ARTIFACT_BUCKET:-}" ]] ||
  die "BGD_ARTIFACT_BUCKET is unset — the pipeline action must pass it as an EnvironmentVariables override"

[[ -n "${BGD_ECR_REPOSITORY_URL:-}" ]] ||
  die "BGD_ECR_REPOSITORY_URL is unset — the pipeline action must pass it as an EnvironmentVariables override, so this build needs no Terraform state"

export BGD_ECR_REPOSITORY_URL

# ---------------------------------------------------------------------------
# 1. The test suite, on the interpreter the image ships
# ---------------------------------------------------------------------------

NETWORK="bgd-build-$$"
DYNAMODB="bgd-dynamodb-$$"

# Every exit path, including the failing one. A leaked container is invisible
# in CodeBuild — the build host is discarded — and a real annoyance in a local
# debugging run, where the next attempt collides on the name.
cleanup() {
  docker rm --force "$DYNAMODB" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$DIST"

info "starting DynamoDB Local"
dim "  $DYNAMODB_LOCAL"
docker network create "$NETWORK" >/dev/null
docker run --detach --name "$DYNAMODB" --network "$NETWORK" \
  "$DYNAMODB_LOCAL" -jar DynamoDBLocal.jar -sharedDb -inMemory >/dev/null

info "running the test suite"
dim "  $PYTHON_IMAGE"

# One container run, three steps, because each `docker run` would otherwise
# reinstall the locks into a fresh filesystem.
#
# TWO endpoint variables, and which one is set where is load-bearing. Getting
# it wrong costs 28 failures that all look like an unreachable database, and it
# is the same split .github/workflows/pr-validate.yml already makes. Plan §F15.
#
#   BGD_TEST_DYNAMODB_ENDPOINT  read by app/tests/contract/conftest.py, which
#                               defaults to localhost:8000 and calls
#                               pytest.fail — not skip — when nothing answers.
#                               Container-wide, because the contract suite is
#                               the reason DynamoDB Local is running at all.
#
#   BGD_DYNAMODB_ENDPOINT_URL   read by Settings, and set ONLY for
#                               create_tables, which refuses to run without it
#                               so that a stray AWS_PROFILE cannot point it at
#                               a real account. Exporting it container-wide
#                               fails tests/unit/test_config.py, which asserts
#                               the *default* is None and constructs Settings
#                               with _env_file=None to say so.
#
# The four fake AWS variables are what conftest.py sets for pytest and what
# create_tables needs before pytest starts: botocore signs a request to
# DynamoDB Local exactly as it signs one to AWS, so it needs credentials of
# some shape, and the ones it must not find are this account's.
#
# PYTHONDONTWRITEBYTECODE, because /src is a bind mount: without it the run
# leaves root-owned __pycache__ directories in the working tree.
docker run --rm --network "$NETWORK" \
  --volume "$ROOT:/src" \
  --workdir /src/app \
  --env PYTHONPATH=src \
  --env PYTHONDONTWRITEBYTECODE=1 \
  --env "BGD_TEST_DYNAMODB_ENDPOINT=http://$DYNAMODB:8000" \
  --env "DYNAMODB_URL=http://$DYNAMODB:8000" \
  --env AWS_ACCESS_KEY_ID=testing \
  --env AWS_SECRET_ACCESS_KEY=testing \
  --env AWS_DEFAULT_REGION=us-east-1 \
  --env AWS_REGION=us-east-1 \
  "$PYTHON_IMAGE" sh -c '
    set -e
    pip install --quiet --require-hashes -r requirements-dev.txt
    BGD_DYNAMODB_ENDPOINT_URL="$DYNAMODB_URL" python -m bgd.cli.create_tables
    python -m pytest --cov-report=xml:dist/coverage.xml --junitxml=dist/junit.xml'

ok "tests passed"

# The containers are finished with. Removing them now rather than at the trap
# frees the build host's memory before the buildx build, which is the step that
# wants it.
cleanup
trap - EXIT

# ---------------------------------------------------------------------------
# 2. The image, its SBOM, and the push
#
# Three scripts, each already the command the laptop runs, in the order a
# digest has to be produced before anything can describe or push it. This
# script's own contribution is the environment: BGD_ECR_REPOSITORY_URL comes
# from an action-level variable, so no Terraform state is read.
# ---------------------------------------------------------------------------

"$ROOT/scripts/build-image.sh"
"$ROOT/scripts/generate-sbom.sh"
"$ROOT/scripts/push-image.sh"

[[ -f "$DIST/pushed.env" ]] ||
  die "push-image.sh did not write $DIST/pushed.env — there is no tag to hand to the later stages"

# shellcheck source=/dev/null
. "$DIST/pushed.env"

# ---------------------------------------------------------------------------
# 3. Publish the SBOM, the two reports and the metadata
#
# Under app-builds/<tag>/, which no lifecycle rule expires — design §4.2 wants
# an SBOM for the image running in production three deployments ago, and plan
# §D16 keeps the prefix out of the pipeline-artifact expiry rule deliberately.
# ---------------------------------------------------------------------------

DEST="s3://$BGD_ARTIFACT_BUCKET/${BGD_ARTIFACT_PREFIX:-app-builds}/$IMAGE_TAG"

# The four things you want when asking, months later, what produced the image
# production is running. Written as JSON rather than a text file because
# Phase 9 reads this prefix for deployment metrics.
cat >"$DIST/build-metadata.json" <<JSON
{
  "image_tag": "$IMAGE_TAG",
  "image_digest": "$IMAGE_DIGEST",
  "git_sha": "$(git -C "$ROOT" rev-parse HEAD)",
  "build_number": "${CODEBUILD_BUILD_NUMBER:-0}",
  "build_url": "$(build_url)"
}
JSON

info "publishing build outputs"
for artifact in sbom.spdx.json coverage.xml junit.xml build-metadata.json; do
  if [[ -f "$DIST/$artifact" ]]; then
    aws s3 cp --only-show-errors "$DIST/$artifact" "$DEST/$artifact"
    dim "  $DEST/$artifact"
  else
    # Loud, and not fatal. A missing report means a step above changed its
    # output path; the image it describes is already in the registry and
    # failing the build here would leave a pushed image no stage can deploy.
    warn "expected $artifact in app/dist, and it is not there"
  fi
done

# ---------------------------------------------------------------------------
# 4. The two variables every later stage interpolates
#
# #{Build.IMAGE_TAG} reaches both deploy actions and the production plan;
# #{Build.IMAGE_DIGEST} reaches the smoke action, which asserts /version
# reports it. The names are declared once in infra/foundation/locals.tf and a
# test asserts pipelines/app-build.yml still exports them — a rename fails
# nothing at apply, it makes the deploy receive the literal placeholder as a
# tag.
#
# %q, and the same shape write_vars uses, so the buildspec's
# `set -a && . ./build-vars.env` is safe.
# ---------------------------------------------------------------------------

{
  printf 'IMAGE_TAG=%q\n' "$IMAGE_TAG"
  printf 'IMAGE_DIGEST=%q\n' "$IMAGE_DIGEST"
} >"$VARS_FILE"

ok "build complete"
dim "  tag     $IMAGE_TAG"
dim "  digest  $IMAGE_DIGEST"
