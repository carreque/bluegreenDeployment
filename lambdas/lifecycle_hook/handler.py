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

Plan F2 is now fully retired by real evidence from 2026-08-31 and 2026-09-01.
The success key is confirmed correct: ECS documents {"hookStatus": "SUCCEEDED" |
"FAILED" | "IN_PROGRESS"}, lower-case, and a callBackDelay alongside
IN_PROGRESS. The raise path is confirmed to fail CLOSED — an exception aborted
the deployment and ECS reported "HookStatus must not be null", which is that
parse failure being surfaced rather than a rejection being understood. So the
asymmetry works but produces a misleading operator-facing message, and whether
to replace the raise with a returned FAILED is a decision for Phase 11, which
deliberately rejects a build and can therefore observe both forms.

The event shape is confirmed too, and is no longer a guess:

    {"executionDetails": {"testTrafficWeights": {}, "productionTrafficWeights": {},
                          "serviceArn": "...", "targetServiceRevisionArn": "..."},
     "executionId": "...", "lifecycleStage": "POST_TEST_TRAFFIC_SHIFT",
     "resourceArn": ".../service-deployment/..."}

It is still not parsed. targetServiceRevisionArn names the revision this hook
was invoked to judge, and comparing it against what was actually served would
have detected the isolation defect from inside on the first deployment — but
resolving a revision ARN to an image needs boto3 and IAM, which costs the
standard-library-only property that makes this one file. That trade is Phase
11's to make, not this handler's. Note also that both weight maps arrive empty.

Transport failures are retried; the service answering badly is never retried.
That distinction is the subject of
docs/phases/phase6/2026-08-31-dark-canary-transport-timeout.md and is why this
module uses http.client rather than urllib: urlopen takes ONE timeout covering
connect, handshake and read, so the two verdicts cannot be separated without
guessing at exception text. See _connect and _request below.

Standard library only. No boto3, no HTTP client dependency — which is what makes
the deployment package one file and lets terraform test build it offline.
"""

import http.client
import json
import logging
import os
import ssl
import time
import urllib.parse

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

# Probed in this order, and the order matters. /health is the cheapest and
# rules out "the process never started" first; /ready is the expensive one that
# actually reaches DynamoDB; /version is last because its answer is only
# interesting once the first two have passed.
#
# All three now travel over ONE connection. urllib opened a fresh one per call
# and sent Connection: close, so each probe paid its own DNS, TCP and TLS —
# which meant the smallest budget in the set was also the one establishing the
# connection.
PROBE_PATHS = ("/health", "/ready", "/version")

# The budget for the service to ANSWER, once a connection exists. Overridable
# by BGD_TIMEOUT_SECONDS, which Terraform does not set.
DEFAULT_READ_TIMEOUT_SECONDS = 5

# /ready gets its own floor. Phase 5's F5 measured /ready taking 25.6 seconds to
# fail when DynamoDB is unreachable, because botocore retries with backoff. A
# 5-second probe would report a timeout and hide the 503 that names the real
# cause — on exactly the failure the dark canary exists to catch.
READY_MINIMUM_TIMEOUT_SECONDS = 30

# The budget for DNS, TCP and the TLS handshake — separately, because this is
# the half that is worth retrying.
CONNECT_TIMEOUT_SECONDS = 10

# Three attempts at establishing a connection, then the verdict stands. On
# 2026-08-31 a single handshake hung for the full ten seconds and reversed a
# production deployment that was fine; the four healthy invocations either side
# of it completed all three requests in 0.4 to 1.0 seconds, so one retry is the
# difference between a flaky gate and a working one, and three is generous.
TRANSPORT_ATTEMPTS = 3
TRANSPORT_BACKOFF_SECONDS = (1.0, 3.0)

# Held back from the Lambda's own remaining time so the handler returns a
# reasoned rejection instead of being killed. A killed function is an invocation
# error, and plan D3 makes that a rollback — the same outcome the retry exists
# to prevent, arrived at by a worse route.
DEADLINE_RESERVE_SECONDS = 5

# Used only when the runtime hands us no context, which is the test harness.
# Real invocations always derive the deadline from the function's own timeout.
FALLBACK_BUDGET_SECONDS = 85


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


class _TransportError(Exception):
    """No conversation happened: DNS, TCP, or the TLS handshake.

    Internal, and it never escapes this module — once the attempts or the
    deadline are spent it becomes a HookRejected, so the hook still fails
    closed. It exists so that "should this be retried?" is a property of where
    the failure occurred rather than a guess about its message.

    Nothing raised after the request is on the wire belongs here. A 503, a
    body that is not JSON, or a read that times out are all the service
    answering — or failing to — and that is the finding this hook exists to
    produce. Retrying those would turn the gate into a slower gate.
    """


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        # Before any probe. The alternative is requesting "None/health" and
        # reporting a DNS failure, which names the wrong cause entirely.
        raise HookRejected(f"{name} is not set; the hook cannot know what to probe")
    return value


def _read_timeout_for(path: str, base: int) -> int:
    return max(base, READY_MINIMUM_TIMEOUT_SECONDS) if path == "/ready" else base


def _split(base_url: str) -> tuple[str, int, str]:
    """Host, port and any path prefix, from BGD_PROBE_URL.

    http.client wants these apart, where urlopen took them joined. The path
    prefix is preserved rather than dropped so a probe URL carrying one behaves
    as it did — the deployed URLs carry none, and a silent change in what gets
    requested is not something to discover during a deployment.
    """
    parts = urllib.parse.urlsplit(base_url)

    if parts.scheme != "https":
        # The dark canary must exercise the same path a user would. A hook that
        # validated green over plaintext would not be testing what production
        # serves, and every listener in this project terminates TLS.
        raise HookRejected(f"BGD_PROBE_URL must be https, not {parts.scheme!r}: {base_url}")

    if not parts.hostname:
        raise HookRejected(f"BGD_PROBE_URL has no host: {base_url}")

    return parts.hostname, parts.port or 443, parts.path.rstrip("/")


def _remaining(deadline: float) -> float:
    return deadline - time.monotonic()


def _connect(host: str, port: int, timeout: float) -> http.client.HTTPSConnection:
    """DNS, TCP and TLS, with a budget of their own.

    Everything this raises is retryable, and that is the whole reason the
    connection is established explicitly instead of implicitly inside the first
    request.
    """
    started = time.monotonic()
    conn = http.client.HTTPSConnection(
        host, port, timeout=timeout, context=ssl.create_default_context()
    )

    try:
        conn.connect()
    except OSError as error:
        # URLError's replacement: socket.timeout, ssl.SSLError and
        # ConnectionRefusedError are all OSError, as is the bare TimeoutError a
        # handshake timeout arrives as. One clause covers them.
        conn.close()
        raise _TransportError(
            f"could not reach {host}:{port} within {timeout:.0f}s: {error}"
        ) from error

    LOGGER.info("connected to %s:%s in %.0f ms", host, port, (time.monotonic() - started) * 1000)
    return conn


def _request(conn: http.client.HTTPSConnection, path: str, timeout: float) -> bytes:
    """Issue one request on an established connection, or name what went wrong.

    Every failure message contains the path and what happened, because a hook
    rejection's only trace is this string in CloudWatch — and "green never
    became healthy" and "green was healthy but served the wrong image" have
    entirely different next steps.
    """
    started = time.monotonic()
    conn.sock.settimeout(timeout)

    try:
        conn.request("GET", path)
        response = conn.getresponse()
        status = response.status
        body = response.read()
    except (ConnectionResetError, http.client.BadStatusLine) as error:
        # The one transport failure that can surface here: an idle keep-alive
        # connection reaped between probes. RemoteDisconnected subclasses
        # ConnectionResetError, so this covers it. Worth exactly one reconnect.
        raise _TransportError(f"{path}: connection closed before a reply: {error}") from error
    except (OSError, http.client.HTTPException) as error:
        # The request is on the wire and the service did not answer inside its
        # budget. That is a finding, not a network hiccup — /ready hanging for
        # thirty seconds is DynamoDB being unreachable, which is precisely what
        # the dark canary is for. Never retried.
        raise HookRejected(f"{path} did not answer within {timeout:.0f}s: {error}") from error

    LOGGER.info("%s answered %s in %.0f ms", path, status, (time.monotonic() - started) * 1000)

    if status != 200:
        raise HookRejected(f"{path} returned {status}, expected 200")

    return body


def _probe_all(base_url: str, read_base: int, deadline: float) -> dict[str, bytes]:
    """One connection, three requests, and a bounded retry on the connection.

    The loop retries the whole set rather than the failed request alone. Every
    probe is a GET, so re-running /health and /ready costs a few hundred
    milliseconds and keeps the "one connection" property that made the retry
    affordable in the first place.
    """
    host, port, prefix = _split(base_url)
    timeouts = {path: _read_timeout_for(path, read_base) for path in PROBE_PATHS}

    # The worst case of a complete attempt. Refusing to start one that cannot
    # finish is what keeps the retries inside the function's own timeout.
    attempt_cost = CONNECT_TIMEOUT_SECONDS + sum(timeouts.values())

    last: _TransportError | None = None

    for attempt in range(1, TRANSPORT_ATTEMPTS + 1):
        if last is not None:
            if _remaining(deadline) < attempt_cost:
                raise HookRejected(
                    f"no connection to {host}:{port} after {attempt - 1} attempt(s), "
                    f"and {_remaining(deadline):.0f}s left is too little to try again: {last}"
                ) from last

            backoff = TRANSPORT_BACKOFF_SECONDS[
                min(attempt - 2, len(TRANSPORT_BACKOFF_SECONDS) - 1)
            ]
            LOGGER.warning(
                "transport failure on attempt %d/%d (%s) — retrying in %.0fs",
                attempt - 1,
                TRANSPORT_ATTEMPTS,
                last,
                backoff,
            )
            time.sleep(backoff)

        try:
            conn = _connect(host, port, min(CONNECT_TIMEOUT_SECONDS, _remaining(deadline)))
        except _TransportError as failure:
            last = failure
            continue

        try:
            return {path: _request(conn, f"{prefix}{path}", timeouts[path]) for path in PROBE_PATHS}
        except _TransportError as failure:
            last = failure
            continue
        finally:
            conn.close()

    raise HookRejected(
        f"no connection to {host}:{port} after {TRANSPORT_ATTEMPTS} attempts: {last}"
    )


def _decode_version(body: bytes) -> dict[str, object]:
    try:
        return json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        # An ALB error page rather than the application's JSON. A rejection
        # naming /version, not a traceback.
        raise HookRejected(f"/version did not return JSON: {error}") from error


def _deadline_from(context: object) -> float:
    """When the handler must have returned a verdict by.

    Derived from the Lambda's own remaining time rather than a constant, so the
    retry budget cannot outlive the function no matter what
    hook_timeout_seconds is set to. A killed function is an invocation error,
    and plan D3 turns that into a rollback of a build that may have been fine —
    which is the failure this whole retry path exists to stop.
    """
    remaining = getattr(context, "get_remaining_time_in_millis", None)

    if callable(remaining):
        try:
            budget = remaining() / 1000.0 - DEADLINE_RESERVE_SECONDS
        except TypeError, ValueError:
            budget = FALLBACK_BUDGET_SECONDS
    else:
        budget = FALLBACK_BUDGET_SECONDS

    return time.monotonic() + max(budget, 1.0)


def handler(event: object, context: object) -> dict[str, str]:
    """Probe one listener and report whether the deployment may proceed.

    `event` is accepted and deliberately not parsed — see the module docstring
    for its now-confirmed shape and why reading it is Phase 11's decision. It is
    logged raw. `context` is read for one thing only: how long is left.
    """
    probe_url = _required("BGD_PROBE_URL").rstrip("/")
    stage = _required("BGD_STAGE")
    read_base = int(os.environ.get("BGD_TIMEOUT_SECONDS", DEFAULT_READ_TIMEOUT_SECONDS))
    deadline = _deadline_from(context)

    LOGGER.info(
        "hook invoked stage=%s probe_url=%s budget=%.0fs event=%s",
        stage,
        probe_url,
        _remaining(deadline),
        json.dumps(event, default=str),
    )

    try:
        bodies = _probe_all(probe_url, read_base, deadline)
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
        # It cannot be narrowed to "is this a create?" from the event: the
        # payload carries targetServiceRevisionArn but no source revision, so a
        # create and a redeploy are indistinguishable to this handler.
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

        # WARNING, not INFO, and the level is the point. This records a probe
        # that FAILED and was allowed through anyway. At INFO it read as routine
        # output, and on 2026-08-31 it concealed three real production 503s —
        # the production listener rule had been reverted to an empty target
        # group seconds earlier, on three ordinary deployments, and the hook's
        # "4 invocations, 0 rejected" was taken as evidence that :443 was
        # healthy. See fixIssues.md. After the alb.tf fix this must not appear
        # on anything but a create or a rebuild.
        LOGGER.warning(
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
