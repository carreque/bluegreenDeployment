"""ECS blue/green lifecycle hook.

One handler, three deployments of it. Each instance probes one listener at one
stage of the deployment; which listener and which stage come from the
environment, so the code that decides whether a release proceeds exists once.

See docs/phases/phase6/2026-08-28-phase-06-implementation-plan.md D2 and D3.

The return contract is deliberately asymmetric. On success this returns
{"hookStatus": "SUCCEEDED"}. On failure it *raises* rather than returning a
"FAILED" payload, because the exact contract ECS expects could not be confirmed
without an AWS session (plan F2) and the two possible mistakes are not equally
bad: a raised exception is an unambiguous invocation error under any contract,
whereas a returned FAILED that ECS does not parse promotes a bad build to
production. Do not "tidy" this into a symmetric return.

Plan F2 is now half retired, by real evidence from 2026-08-31. The success key
is confirmed correct: ECS documents {"hookStatus": "SUCCEEDED" | "FAILED" |
"IN_PROGRESS"}, lower-case, and a callBackDelay alongside IN_PROGRESS. The raise
path is confirmed to fail CLOSED — an exception aborted the deployment and ECS
reported "HookStatus must not be null", which is that parse failure being
surfaced rather than a rejection being understood. So the asymmetry works but
produces a misleading operator-facing message, and whether to replace the raise
with a returned FAILED is a decision for Phase 11, which deliberately rejects a
build and can therefore observe both forms. It is not changed here: this was
found mid-incident, and a second change to the rejection path would have been
made with no evidence for it.

Standard library only. No boto3, no HTTP client dependency — which is what makes
the deployment package one file and lets terraform test build it offline.
"""

import json
import logging
import os
import urllib.error
import urllib.request

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

# Probed in this order, and the order matters. /health is the cheapest and
# rules out "the process never started" first; /ready is the expensive one that
# actually reaches DynamoDB; /version is last because its answer is only
# interesting once the first two have passed.
PROBE_PATHS = ("/health", "/ready", "/version")

DEFAULT_TIMEOUT_SECONDS = 10

# /ready gets its own floor. Phase 5's F5 measured /ready taking 25.6 seconds to
# fail when DynamoDB is unreachable, because botocore retries with backoff. A
# 10-second probe would report a timeout and hide the 503 that names the real
# cause — on exactly the failure the dark canary exists to catch. The Lambda's
# own timeout is derived from this: 10 + 30 + 10 = 50s worst case, so the
# function is given 60. See infra/environments/prod/variables.tf.
READY_MINIMUM_TIMEOUT_SECONDS = 30


class HookRejected(Exception):  # noqa: N818 — see below
    """The deployment must not proceed past this stage.

    Raised rather than returned. See the module docstring and plan D3.

    N818 wants an ``Error`` suffix. Deliberately not taken: this is not an
    error in the handler, it is the handler's *verdict* on the deployment,
    and every document in this phase — the plan's D3, the runbook, the
    module README — names it HookRejected. A name that reads as a decision
    is worth more here than a naming convention, and renaming it would make
    four documents wrong.
    """


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        # Before any probe. The alternative is requesting "None/health" and
        # reporting a DNS failure, which names the wrong cause entirely.
        raise HookRejected(f"{name} is not set; the hook cannot know what to probe")
    return value


def _timeout_for(path: str, base: int) -> int:
    return max(base, READY_MINIMUM_TIMEOUT_SECONDS) if path == "/ready" else base


def _probe(base_url: str, path: str, timeout: int) -> bytes:
    """Fetch one path, or raise HookRejected naming it.

    Every failure message contains the path and what happened, because a hook
    rejection's only trace is this string in CloudWatch — and "green never
    became healthy" and "green was healthy but served the wrong image" have
    entirely different next steps.
    """
    target = f"{base_url}{path}"

    try:
        # The S310 suppression below is deliberate: the URL is this project's
        # own ALB, built from a hostname foundation owns and a path from the
        # constant tuple above. There is no caller-supplied scheme to audit.
        with urllib.request.urlopen(target, timeout=timeout) as response:  # noqa: S310
            status = response.status
            body = response.read()
    except urllib.error.HTTPError as error:
        # urlopen raises rather than returns on a non-2xx, so this is the branch
        # a real 503 from /ready arrives through.
        raise HookRejected(f"{path} returned {error.code}, expected 200") from error
    except OSError as error:
        # URLError is an OSError subclass, as is the bare TimeoutError that a
        # socket read timeout can raise past it. One clause covers both.
        raise HookRejected(f"{path} was unreachable after {timeout}s: {error}") from error

    if status != 200:
        # Defensive: a custom opener or proxy can hand back a non-2xx without
        # raising. Asserted by a test so the branch is not dead code.
        raise HookRejected(f"{path} returned {status}, expected 200")

    return body


def _decode_version(body: bytes) -> dict[str, object]:
    try:
        return json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        # An ALB error page rather than the application's JSON. A rejection
        # naming /version, not a traceback.
        raise HookRejected(f"/version did not return JSON: {error}") from error


def handler(event: object, context: object) -> dict[str, str]:
    """Probe one listener and report whether the deployment may proceed.

    `event` and `context` are accepted and deliberately not parsed. Reading the
    deployment identifiers out of the event would be more informative, but the
    event's shape is unverifiable offline (plan F2) and a handler that raised on
    an unexpected shape would fail every deployment. The event is logged raw
    instead, which is how the runbook discovers what it really contains.
    """
    probe_url = _required("BGD_PROBE_URL").rstrip("/")
    stage = _required("BGD_STAGE")
    timeout = int(os.environ.get("BGD_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS))

    LOGGER.info(
        "hook invoked stage=%s probe_url=%s event=%s",
        stage,
        probe_url,
        json.dumps(event, default=str),
    )

    try:
        bodies = {
            path: _probe(probe_url, path, _timeout_for(path, timeout)) for path in PROBE_PATHS
        }
    except HookRejected as rejection:
        # BGD_ALLOW_UNSERVED exists for exactly one situation: a stage that runs
        # BEFORE this environment serves anything, on a deployment that is
        # CREATING the service rather than replacing a running one.
        #
        # PRE_SCALE_UP is that stage. It fires before green is scaled up, so on
        # the first deployment into an empty account there are no tasks, no
        # healthy targets, and nothing behind the production listener — the probe
        # cannot succeed, the hook rejects, and the service can never be created.
        # The gate that protects deployments makes the first one impossible.
        #
        # This is not a first-day problem that goes away. `make teardown` destroys
        # prod and `make rebuild` applies it again from nothing, so PRE_SCALE_UP
        # meets an unserved listener on EVERY rebuild cycle. Without this the
        # platform's central promise — destroy when idle, rebuild on demand — is
        # broken for production, permanently. Found 2026-08-31 on the first real
        # prod deployment; see
        # docs/phases/phase6/2026-08-31-pre-scale-hook-cold-start.md.
        #
        # Deliberately NOT set on the other two stages, and the asymmetry is the
        # whole design. POST_TEST_TRAFFIC_SHIFT is the dark canary: it probes
        # green on :8443 after green exists, so an unreachable endpoint there
        # means the new revision is broken and is precisely what must block the
        # release. POST_PRODUCTION_TRAFFIC_SHIFT probes :443 after traffic has
        # moved, where unreachable means the shift broke production. Allowing
        # either to pass on a failed probe would turn the two hooks that carry
        # this project's entire safety argument into logging.
        if os.environ.get("BGD_ALLOW_UNSERVED", "").strip().lower() != "true":
            raise

        LOGGER.info(
            "stage=%s proceeding: %s is not serving yet (%s). "
            "BGD_ALLOW_UNSERVED is set, so this is a create or a rebuild rather "
            "than a rejection.",
            stage,
            probe_url,
            rejection,
        )
        return {"hookStatus": "SUCCEEDED"}

    version = _decode_version(bodies["/version"])
    served_digest = version.get("image_digest", "unknown")

    # The phase's evidence surface when a deployment is read after the fact:
    # which colour this stage saw, and what it was running.
    LOGGER.info(
        "stage=%s probed=%s git_sha=%s image_digest=%s",
        stage,
        probe_url,
        version.get("git_sha", "unknown"),
        served_digest,
    )

    # Optional and opt-in. Terraform never sets it, so the committed
    # infrastructure carries no failure toggle to forget about; the runbook sets
    # it by hand for exit criterion 3, and Phase 8's pipeline can set it per
    # deployment to assert "the thing I built is the thing serving". Plan D12.
    expected_digest = os.environ.get("BGD_EXPECT_DIGEST")
    if expected_digest and expected_digest != served_digest:
        raise HookRejected(
            f"/version reports image_digest {served_digest}, "
            f"but BGD_EXPECT_DIGEST is {expected_digest}"
        )

    return {"hookStatus": "SUCCEEDED"}
