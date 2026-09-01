# The application image: two stages, one digest-pinned base, non-root at runtime.
#
# Reproducibility is a stated requirement (design §4.1), so this file is written
# to be a pure function of its inputs. Two clean builds of the same commit
# produce the same manifest digest — see docs/phases/phase2 §F1 and §F2 for the
# measurements, and note that this only holds through scripts/build-image.sh:
# the default buildx driver silently ignores rewrite-timestamp.
#
# Base pinned by index digest. Recorded 2026-08-12 — re-record with:
#   docker buildx imagetools inspect public.ecr.aws/docker/library/python:3.14.6-slim --format '{{.Manifest.Digest}}'
# 3.14.6 exactly, not 3.14-slim: it matches .python-version, so the container,
# the local virtualenv and CI all run the same interpreter (design §1.6).
#
# public.ecr.aws/docker/library, not Docker Hub, and THE DIGEST IS UNCHANGED —
# AWS's mirror of the Docker official images serves the identical index digest,
# so this is the same base image reached over a different registry and design
# §4.1's reproducibility claim is untouched.
#
# Moved 2026-08-31 because Docker Hub rate-limits unauthenticated pulls per
# source IP and CodeBuild shares a NAT address with every other AWS customer
# behind it. The application pipeline's Build stage pulls this image twice — once
# for the test suite, once as the build's FROM — plus DynamoDB Local, and it
# failed with `toomanyrequests` on a deployment. Same failure as the tflint
# ruleset and checkov before it; see
# docs/phases/phase7/2026-08-31-tflint-ruleset-install.md §8.
#
# The trade is small and worth naming: ECR Public also rate-limits ANONYMOUS
# pulls, but generously, and a build inside AWS authenticates with its role.
# A laptop that ever hits it can raise the limit with
#   aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws
ARG BASE_IMAGE=public.ecr.aws/docker/library/python:3.14.6-slim@sha256:7bec7ddcddeff7975d6ba9b4be7dd6f6b2f55e7491539145e2978f7f97ce9144

# ---------------------------------------------------------------------------
# builder — resolve the virtualenv, and only the virtualenv
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build
COPY requirements.txt ./

# --require-hashes is the second half of design §4.1's reproducibility pair:
# pip-compile --generate-hashes wrote the locks, and this refuses to install
# anything whose hash does not match.
#
# The three bytecode steps exist because a default .pyc header embeds the
# source file's mtime, and pip's own bytecode is therefore different on every
# build. --no-compile suppresses it during install, the find removes what pip
# wrote while running, and compileall regenerates it with PEP 552 hash-based
# invalidation — same source, same bytes, whenever it is built. Precompiling
# rather than shipping none of it keeps cold start fast.
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --require-hashes --no-compile -r requirements.txt \
 && find /opt/venv -name '__pycache__' -type d -prune -exec rm -rf {} + \
 && /opt/venv/bin/python -m compileall -q --invalidation-mode unchecked-hash /opt/venv/lib

# Normalise the application sources' timestamps here, in a stage that is never
# shipped, so the runtime stage's COPY --from lands already-normalised files.
#
# This is load-bearing, and it is not what rewrite-timestamp does. Measured
# (Phase 2 §F6): rewrite-timestamp applies min(mtime, SOURCE_DATE_EPOCH), so it
# normalises files *newer* than the commit and silently preserves ones *older*
# than it. A fresh clone stamps everything with the clone time and is therefore
# deterministic; a working copy checked out before the commit being built is
# not, and would produce a different digest for identical source. Forcing the
# timestamps here removes the dependency on checkout history entirely.
ARG SOURCE_DATE_EPOCH=0
COPY src/ /build/src/
RUN find /build/src -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +

# ---------------------------------------------------------------------------
# runtime — the shipped image
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime

# Build identity, surfaced by /version. BGD_IMAGE_DIGEST is deliberately absent:
# an image cannot carry its own digest, because the digest is its hash. Phases 5
# and 6 set it in the ECS task definition, which is the only place that knows
# which digest is actually deployed.
#
# RELEASE_COLOR is the opposite case, and Phase 12 added it for that reason: a
# value that *can* be a function of the source, and therefore is. It comes from
# app/RELEASE_COLOR in the repository rather than from the operator's shell, so
# the digest stays reproducible across machines (plan D3). The default matches
# the settings default, so a plain `docker build` — compose, or anything
# bypassing scripts/build-image.sh — produces a container that reports "slate"
# rather than one that fails validation at startup.
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG BUILT_AT=unknown
ARG RELEASE_COLOR=slate

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/app/src \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    BGD_APP_VERSION=${APP_VERSION} \
    BGD_GIT_SHA=${GIT_SHA} \
    BGD_BUILT_AT=${BUILT_AT} \
    BGD_RELEASE_COLOR=${RELEASE_COLOR}

# Standard OCI provenance, and the handle the build script's cleanup uses:
# every build loads a new image under the same tag and orphans the previous
# one's layers, and this label is what lets those be pruned without touching
# anything else on the machine. All three values come from build arguments, so
# they stay a function of the source.
LABEL org.opencontainers.image.title="bgd-api" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}"

COPY --from=builder /opt/venv /opt/venv
# From the builder, not from the context: the builder normalised the timestamps
# on these files, and copying the context directly would reintroduce whatever
# mtimes this particular checkout happens to have.
COPY --from=builder /build/src /app/src

# A numeric UID, with no useradd. useradd writes an /etc/shadow entry recording
# the day it ran, which would make two otherwise identical builds differ across
# a midnight boundary. See §3.1 of the Phase 2 plan.
USER 10001:10001

# Documentation plus the port `docker run --publish-all` picks up. The ALB
# target group and the ECS task definition declare it for real, in Terraform.
EXPOSE 8080

# No HEALTHCHECK: Fargate does not act on one. Container health belongs to the
# task definition and endpoint health to the ALB target group — see §3.2.
CMD ["python", "-m", "uvicorn", "bgd.api.main:create_app", \
     "--factory", "--host", "0.0.0.0", "--port", "8080"]
