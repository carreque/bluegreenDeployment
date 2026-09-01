"""The lifecycle hook handler's contract, asserted offline.

http.client.HTTPSConnection is patched throughout, so this suite makes no
network call, needs no AWS session and runs on the app virtualenv's pytest with
nothing added.

The most important test in the file is
test_unhealthy_raises_rather_than_returning_failed. It is the executable form of
plan D3: the exact payload ECS expects back from a lifecycle hook could not be
confirmed without an AWS session (plan F2), and the two possible mistakes are
not symmetric. A raised exception is an unambiguous invocation error under any
contract; a returned {"hookStatus": "FAILED"} that ECS does not parse promotes a
bad build to production. If someone later "tidies" the handler into a symmetric
return, that test is what stops them.

The second most important group is the one below the "transport is not the
application" banner. On 2026-08-31 a single TLS handshake hung for ten seconds
and reversed a production deployment that was fine, because the handler could
not tell "the network was slow" from "green is broken". Those tests pin the
distinction in both directions: a 503 is never retried, a handshake failure is.
Loosening either one re-opens a defect — the first turns the gate into a slower
gate, the second makes it flaky again.
"""

import http.client
import json
import time
from unittest.mock import patch

import pytest

from lifecycle_hook.handler import HookRejected, handler

PROBE_URL = "https://api.carloscloudengineer.com"
TEST_LISTENER_URL = "https://api.carloscloudengineer.com:8443"
HOST = "api.carloscloudengineer.com"
SERVED_DIGEST = "sha256:1111111111111111111111111111111111111111111111111111111111111111"

VERSION_BODY = json.dumps(
    {
        "version": "0.1.0",
        "git_sha": "84d4eb0",
        "image_digest": SERVED_DIGEST,
        "built_at": "2026-08-28T00:00:00Z",
    }
).encode()

# The real thing, from the 2026-08-31 CloudWatch line.
HANDSHAKE_TIMEOUT = TimeoutError("_ssl.c:1064: The handshake operation timed out")


class _Response:
    """The slice of an http.client.HTTPResponse the handler actually touches."""

    def __init__(self, status: int = 200, body: bytes = b"{}") -> None:
        self.status = status
        self._body = body

    def read(self) -> bytes:
        return self._body


class _Socket:
    """Only settimeout is called on it, and only that is recorded."""

    def __init__(self) -> None:
        self.timeout: float | None = None

    def settimeout(self, timeout: float) -> None:
        self.timeout = timeout


class _Connection:
    def __init__(self, endpoint: _Endpoint, host: str, port: int, timeout: float | None) -> None:
        self._endpoint = endpoint
        self._host = host
        self._port = port
        self._timeout = timeout
        self._path: str | None = None
        self.sock: _Socket | None = None

    def connect(self) -> None:
        self._endpoint.connections.append((self._host, self._port, self._timeout))

        error = self._endpoint.next_connect_error()
        if error is not None:
            raise error

        self.sock = _Socket()

    def request(self, method: str, path: str) -> None:
        self._path = path
        self._endpoint.requests.append((path, self.sock.timeout))

    def getresponse(self) -> _Response:
        return self._endpoint.answer(self._path)

    def close(self) -> None:
        return None


class _Endpoint:
    """Records every connection and request, and answers by path.

    Values in `by_path` are either a _Response to return or an exception to
    raise, which is what lets one fake cover both the "server answered badly"
    and "server did not answer" branches. `transient` answers are consumed on
    first use, which is how a connection reaped between probes is expressed.
    `connect_errors` are consumed one per connect() attempt, which is how a
    handshake that fails and then succeeds is expressed.
    """

    def __init__(
        self,
        by_path: dict[str, object] | None = None,
        connect_errors: list[BaseException | None] | None = None,
        transient: dict[str, BaseException] | None = None,
    ) -> None:
        self.by_path = by_path or {}
        self.connect_errors = list(connect_errors or [])
        self.transient = dict(transient or {})
        self.connections: list[tuple[str, int, float | None]] = []
        self.requests: list[tuple[str, float | None]] = []

    def factory(
        self, host: str, port: int, timeout: float | None = None, context: object = None
    ) -> _Connection:
        return _Connection(self, host, port, timeout)

    def next_connect_error(self) -> BaseException | None:
        return self.connect_errors.pop(0) if self.connect_errors else None

    def answer(self, path: str) -> _Response:
        if path in self.transient:
            raise self.transient.pop(path)

        answer = self.by_path.get(path, _Response(200, b"{}"))
        if isinstance(answer, BaseException):
            raise answer
        return answer

    @property
    def paths(self) -> list[str]:
        return [path for path, _ in self.requests]

    @property
    def timeouts(self) -> dict[str, float | None]:
        return dict(self.requests)


def _healthy(transient: dict[str, BaseException] | None = None, **overrides: object) -> _Endpoint:
    by_path: dict[str, object] = {
        "/health": _Response(200, b'{"status":"ok"}'),
        "/ready": _Response(200, b'{"status":"ready"}'),
        "/version": _Response(200, VERSION_BODY),
    }
    by_path.update(overrides)
    return _Endpoint(by_path, transient=transient)


class _Context:
    """A Lambda context that reports a fixed remaining time."""

    def __init__(self, remaining_seconds: float) -> None:
        self._remaining = remaining_seconds

    def get_remaining_time_in_millis(self) -> int:
        return int(self._remaining * 1000)


@pytest.fixture(autouse=True)
def _clean_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """Every optional variable unset, both required ones set.

    Autouse because a variable leaking between tests would make the
    BGD_EXPECT_DIGEST cases pass or fail depending on ordering — and that pair
    is exactly the mechanism exit criterion 3 depends on.
    """
    monkeypatch.setenv("BGD_PROBE_URL", PROBE_URL)
    monkeypatch.setenv("BGD_STAGE", "POST_TEST_TRAFFIC_SHIFT")
    monkeypatch.delenv("BGD_TIMEOUT_SECONDS", raising=False)
    monkeypatch.delenv("BGD_EXPECT_DIGEST", raising=False)
    monkeypatch.delenv("BGD_ALLOW_UNSERVED", raising=False)


@pytest.fixture(autouse=True)
def _slept(monkeypatch: pytest.MonkeyPatch) -> list[float]:
    """Retry backoff, recorded rather than waited out.

    Without this the retry tests would spend four real seconds each proving
    something about control flow.
    """
    recorded: list[float] = []
    monkeypatch.setattr(time, "sleep", recorded.append)
    return recorded


def _run(endpoint: _Endpoint, context: object = None) -> dict[str, str]:
    with patch.object(http.client, "HTTPSConnection", endpoint.factory):
        return handler({"executionDetails": {}}, context)


def test_all_probes_pass_returns_succeeded() -> None:
    assert _run(_healthy()) == {"hookStatus": "SUCCEEDED"}


def test_probes_are_the_expected_three_paths() -> None:
    """/ready is in the set deliberately — it is what carries the dark canary.

    /health reports only that the process is alive. A green task that starts but
    cannot reach its DynamoDB table passes /health and fails /ready, and that is
    precisely the failure the POST_TEST_TRAFFIC_SHIFT hook exists to catch
    before promotion. Plan D2.
    """
    endpoint = _healthy()
    _run(endpoint)

    assert endpoint.paths == ["/health", "/ready", "/version"]
    assert [(host, port) for host, port, _ in endpoint.connections] == [(HOST, 443)]


def test_unhealthy_raises_rather_than_returning_failed() -> None:
    """Plan D3, and the most important assertion in this file.

    Returning {"hookStatus": "FAILED"} would be correct under one plausible
    contract and catastrophic under the other. Raising is correct under both.
    """
    endpoint = _healthy(**{"/health": _Response(500, b"")})

    with pytest.raises(HookRejected):
        _run(endpoint)


def test_ready_failure_raises() -> None:
    """A 503 from /ready specifically, delivered the way http.client delivers it.

    Unlike urlopen, http.client returns a non-2xx rather than raising, so the
    status check in _request is the only thing standing between a broken green
    task and promotion. It is not defensive code.
    """
    endpoint = _healthy(**{"/ready": _Response(503, b"")})

    with pytest.raises(HookRejected):
        _run(endpoint)


def test_ready_is_allowed_a_longer_read_budget_than_the_others() -> None:
    """Phase 5's F5 measured /ready taking 25.6s to fail when DynamoDB is
    unreachable, because botocore retries with backoff. A 5-second probe would
    report a timeout and hide the 503 that names the real cause — on exactly the
    failure this hook exists to catch.

    These are READ budgets now. The connection has its own, which is what stops
    the first probe in the set paying for the handshake out of the smallest
    allowance in it.
    """
    endpoint = _healthy()
    _run(endpoint)

    assert endpoint.timeouts["/ready"] >= 30
    assert endpoint.timeouts["/health"] == 5
    assert endpoint.timeouts["/version"] == 5


def test_the_connection_carries_its_own_budget() -> None:
    endpoint = _healthy()
    _run(endpoint)

    _, _, connect_timeout = endpoint.connections[0]
    assert connect_timeout == 10


def test_timeout_seconds_is_honoured_when_set() -> None:
    endpoint = _healthy()

    with patch.dict("os.environ", {"BGD_TIMEOUT_SECONDS": "45"}):
        _run(endpoint)

    assert endpoint.timeouts["/health"] == 45
    # Already above the floor, so the floor must not lower it.
    assert endpoint.timeouts["/ready"] == 45


# ---------------------------------------------------------------------------
# transport is not the application
#
# One TLS handshake hung for ten seconds on 2026-08-31 and reversed a good
# production deployment, because "no conversation happened" and "the service
# answered badly" shared one exception type and one budget. See
# docs/phases/phase6/2026-08-31-dark-canary-transport-timeout.md.
#
# The line is structural: anything raised by connect() is transport and is
# retried; anything raised once the request is on the wire is the service's
# verdict and is never retried. These tests hold both halves.
# ---------------------------------------------------------------------------


def test_one_connection_serves_all_three_probes() -> None:
    """urllib opened a fresh connection per call and sent Connection: close, so
    every probe paid its own DNS, TCP and TLS. Fixing only the first probe's
    budget would have left /version equally exposed.
    """
    endpoint = _healthy()
    _run(endpoint)

    assert len(endpoint.connections) == 1
    assert len(endpoint.requests) == 3


def test_a_handshake_failure_is_retried_then_succeeds(_slept: list[float]) -> None:
    """The 2026-08-31 incident, and what should have happened instead."""
    endpoint = _healthy()
    endpoint.connect_errors = [HANDSHAKE_TIMEOUT]

    assert _run(endpoint) == {"hookStatus": "SUCCEEDED"}
    assert len(endpoint.connections) == 2
    assert _slept == [1.0]


def test_retries_are_bounded_and_then_reject(_slept: list[float]) -> None:
    """Retrying must not become "never rejects". The hook still fails closed."""
    endpoint = _healthy()
    endpoint.connect_errors = [HANDSHAKE_TIMEOUT] * 10

    with pytest.raises(HookRejected) as rejection:
        _run(endpoint)

    assert len(endpoint.connections) == 3
    assert _slept == [1.0, 3.0]
    assert HOST in str(rejection.value)


def test_a_503_is_never_retried() -> None:
    """The finding the hook exists to produce. One request, one verdict."""
    endpoint = _healthy(**{"/health": _Response(503, b"")})

    with pytest.raises(HookRejected):
        _run(endpoint)

    assert len(endpoint.connections) == 1
    assert endpoint.paths == ["/health"]


def test_a_read_timeout_is_never_retried() -> None:
    """/ready hanging is DynamoDB being unreachable — a finding, not a hiccup.

    It arrives as an OSError exactly like a handshake timeout does, which is why
    the two are separated by WHERE they are raised rather than by type.
    """
    endpoint = _healthy(**{"/ready": TimeoutError("timed out")})

    with pytest.raises(HookRejected) as rejection:
        _run(endpoint)

    assert len(endpoint.connections) == 1
    assert "/ready" in str(rejection.value)


def test_a_body_that_is_not_json_is_never_retried() -> None:
    endpoint = _healthy(**{"/version": _Response(200, b"<html>502 Bad Gateway</html>")})

    with pytest.raises(HookRejected):
        _run(endpoint)

    assert len(endpoint.connections) == 1


def test_a_reaped_keepalive_reconnects_once() -> None:
    """An idle connection closed by the ALB between probes is transport.

    RemoteDisconnected subclasses ConnectionResetError, so this is the shape it
    really arrives in. The whole set is re-run on the new connection, which is
    why /health appears twice.
    """
    endpoint = _healthy(transient={"/ready": ConnectionResetError("peer closed")})

    assert _run(endpoint) == {"hookStatus": "SUCCEEDED"}
    assert len(endpoint.connections) == 2
    assert endpoint.paths == ["/health", "/ready", "/health", "/ready", "/version"]


def test_the_retry_budget_never_exceeds_the_remaining_time(_slept: list[float]) -> None:
    """A killed Lambda is an invocation error, and plan D3 makes that a rollback
    — the same outcome the retry exists to prevent, reached by a worse route. So
    the handler refuses an attempt it cannot finish and returns a verdict.
    """
    endpoint = _healthy()
    endpoint.connect_errors = [HANDSHAKE_TIMEOUT] * 10

    with pytest.raises(HookRejected):
        _run(endpoint, context=_Context(12))

    assert len(endpoint.connections) == 1
    assert _slept == []


def test_a_generous_context_still_stops_at_the_attempt_limit(_slept: list[float]) -> None:
    """The two bounds are independent: time left does not buy extra attempts."""
    endpoint = _healthy()
    endpoint.connect_errors = [HANDSHAKE_TIMEOUT] * 10

    with pytest.raises(HookRejected):
        _run(endpoint, context=_Context(900))

    assert len(endpoint.connections) == 3


# ---------------------------------------------------------------------------


def test_digest_match_when_expectation_set(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BGD_EXPECT_DIGEST", SERVED_DIGEST)

    assert _run(_healthy()) == {"hookStatus": "SUCCEEDED"}


def test_digest_mismatch_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    """The mechanism exit criterion 3 uses.

    The runbook sets this variable to a bogus digest with one
    `aws lambda update-function-configuration` call. The check that then fails is
    genuine — only the expectation is deliberately wrong, which is why this is
    not the simulated failure toggle Phase 11's evidence standard forbids.
    Plan D12.
    """
    monkeypatch.setenv("BGD_EXPECT_DIGEST", "sha256:deadbeef")

    with pytest.raises(HookRejected) as rejection:
        _run(_healthy())

    assert SERVED_DIGEST in str(rejection.value)
    assert "sha256:deadbeef" in str(rejection.value)


def test_no_expectation_ignores_digest() -> None:
    """Opt-in, not opt-out. Terraform never sets BGD_EXPECT_DIGEST, so a service
    reporting an unknown digest must still pass liveness — otherwise every
    deployment would depend on a variable no committed infrastructure sets.
    Plan D12.
    """
    unknown = json.dumps({"version": "0.1.0", "git_sha": "abc", "image_digest": "unknown"}).encode()
    endpoint = _healthy(**{"/version": _Response(200, unknown)})

    assert _run(endpoint) == {"hookStatus": "SUCCEEDED"}


def test_missing_probe_url_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    """Raise before probing rather than probing "None/health"."""
    monkeypatch.delenv("BGD_PROBE_URL")
    endpoint = _healthy()

    with pytest.raises(HookRejected) as rejection:
        _run(endpoint)

    assert "BGD_PROBE_URL" in str(rejection.value)
    assert endpoint.connections == []


def test_missing_stage_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("BGD_STAGE")

    with pytest.raises(HookRejected) as rejection:
        _run(_healthy())

    assert "BGD_STAGE" in str(rejection.value)


def test_a_plaintext_probe_url_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    """The dark canary must exercise the same path a user would.

    Every listener in this project terminates TLS, so an http:// probe URL is a
    misconfiguration rather than a supported mode — and one that would quietly
    validate something other than what production serves.
    """
    monkeypatch.setenv("BGD_PROBE_URL", "http://api.carloscloudengineer.com")
    endpoint = _healthy()

    with pytest.raises(HookRejected) as rejection:
        _run(endpoint)

    assert "https" in str(rejection.value)
    assert endpoint.connections == []


def test_a_probe_url_with_no_host_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    """Defensive, and asserted so the branch is not dead code.

    Rejecting here rather than letting http.client be handed an empty host,
    which fails later with a message about DNS instead of about configuration.
    """
    monkeypatch.setenv("BGD_PROBE_URL", "https://")
    endpoint = _healthy()

    with pytest.raises(HookRejected) as rejection:
        _run(endpoint)

    assert "no host" in str(rejection.value)
    assert endpoint.connections == []


def test_a_context_that_cannot_report_its_time_falls_back(_slept: list[float]) -> None:
    """The deadline degrades to the constant rather than crashing the hook.

    A context object that has the method but cannot answer is not a reason to
    fail a deployment, and a TypeError escaping here would be an invocation
    error — which plan D3 turns into a rejection of a build that was fine.
    """

    class _Broken:
        def get_remaining_time_in_millis(self) -> int:
            raise TypeError("no runtime behind this context")

    endpoint = _healthy()
    endpoint.connect_errors = [HANDSHAKE_TIMEOUT] * 10

    with pytest.raises(HookRejected):
        _run(endpoint, context=_Broken())

    # The fallback budget is generous enough to spend every attempt, which is
    # what distinguishes it from the 12-second case above.
    assert len(endpoint.connections) == 3


def test_failure_message_names_path_and_status() -> None:
    """A hook rejection's only trace is this string in CloudWatch.

    The runbook reads it to tell "green never became healthy" apart from "green
    was healthy and served the wrong image", and those two have entirely
    different next steps.
    """
    endpoint = _healthy(**{"/ready": _Response(503, b"")})

    with pytest.raises(HookRejected) as rejection:
        _run(endpoint)

    assert "/ready" in str(rejection.value)
    assert "503" in str(rejection.value)


def test_unreachable_message_names_the_endpoint() -> None:
    """A connection that never opened belongs to no path, so it names the
    host and port instead — which is the useful half when nothing answered.
    """
    endpoint = _healthy()
    endpoint.connect_errors = [ConnectionRefusedError("connection refused")] * 10

    with pytest.raises(HookRejected) as rejection:
        _run(endpoint)

    assert HOST in str(rejection.value)
    assert "connection refused" in str(rejection.value)


def test_version_body_that_is_not_json_raises() -> None:
    """An ALB error page instead of the application's JSON is a rejection, not a
    crash — the difference between a message naming /version and a traceback.
    """
    endpoint = _healthy(**{"/version": _Response(200, b"<html>502 Bad Gateway</html>")})

    with pytest.raises(HookRejected) as rejection:
        _run(endpoint)

    assert "/version" in str(rejection.value)


def test_the_test_listener_url_is_probed_verbatim() -> None:
    """The dark canary's identity: this instance probes :8443, so it validates
    the colour that is NOT yet serving users. A hook pointed at :443 at
    POST_TEST_TRAFFIC_SHIFT validates the old colour and approves every bad
    build. Plan D2, and the worst failure this layer can have.
    """
    endpoint = _healthy()

    with patch.dict("os.environ", {"BGD_PROBE_URL": TEST_LISTENER_URL}):
        _run(endpoint)

    assert endpoint.paths == ["/health", "/ready", "/version"]
    assert [(host, port) for host, port, _ in endpoint.connections] == [(HOST, 8443)]


def test_a_trailing_slash_on_the_probe_url_does_not_double(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BGD_PROBE_URL", f"{PROBE_URL}/")
    endpoint = _healthy()

    _run(endpoint)

    assert endpoint.paths == ["/health", "/ready", "/version"]


# ---------------------------------------------------------------------------
# BGD_ALLOW_UNSERVED — the cold-start escape, and its blast radius
#
# PRE_SCALE_UP runs before green is scaled up. On a deployment that CREATES the
# service there is nothing behind the listener, so the probe cannot succeed and
# the hook would reject the only deployment that could ever populate it. That is
# not a first-day problem: `make rebuild` recreates prod from nothing on every
# teardown cycle. Found 2026-08-31 on the first real prod deployment.
#
# The flag is set on PRE_SCALE_UP alone. These tests fix both halves: that it
# works where it is set, and that it changes nothing where it is not.
# ---------------------------------------------------------------------------


def test_unreachable_endpoint_passes_when_unserved_is_allowed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The cold-start case: nothing is listening yet, and the deployment proceeds."""
    monkeypatch.setenv("BGD_STAGE", "PRE_SCALE_UP")
    monkeypatch.setenv("BGD_ALLOW_UNSERVED", "true")

    endpoint = _healthy()
    endpoint.connect_errors = [ConnectionRefusedError("Connection refused")] * 10

    assert _run(endpoint) == {"hookStatus": "SUCCEEDED"}


def test_the_unserved_escape_is_logged_loudly_enough_to_notice(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    """WARNING, not INFO, and the level is the finding.

    This line records a probe that FAILED and was allowed through anyway. At
    INFO it read as routine output, and on 2026-08-31 it concealed three real
    production 503s across three ordinary deployments — the production listener
    rule had been reverted to an empty target group seconds before each one, and
    the hook's "4 invocations, 0 rejected" was read as evidence that :443 was
    healthy. See fixIssues.md.
    """
    monkeypatch.setenv("BGD_STAGE", "PRE_SCALE_UP")
    monkeypatch.setenv("BGD_ALLOW_UNSERVED", "true")

    endpoint = _healthy(**{"/health": _Response(503, b"")})

    with caplog.at_level("WARNING"):
        assert _run(endpoint) == {"hookStatus": "SUCCEEDED"}

    assert [record.levelname for record in caplog.records] == ["WARNING"]
    assert "is not serving yet" in caplog.text


def test_unreachable_endpoint_still_raises_without_the_flag() -> None:
    """The default, and what the other two stages rely on.

    Identical to the case above except for the flag. If this ever passes, the
    dark canary has been turned into a log line.
    """
    endpoint = _healthy()
    endpoint.connect_errors = [ConnectionRefusedError("Connection refused")] * 10

    with pytest.raises(HookRejected):
        _run(endpoint)


def test_allow_unserved_also_covers_an_endpoint_that_answers_badly(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Deliberate, and worth stating rather than discovering.

    With the flag set, a 500 from the CURRENT production does not block the
    deployment either. That is the intended reading of PRE_SCALE_UP: this stage
    describes what production looked like before the release, and refusing to
    deploy because production is unhealthy is backwards — the release may be the
    fix. The stages that gate on health are the two that run after green exists.
    """
    monkeypatch.setenv("BGD_STAGE", "PRE_SCALE_UP")
    monkeypatch.setenv("BGD_ALLOW_UNSERVED", "true")

    endpoint = _healthy(**{"/health": _Response(500, b"")})

    assert _run(endpoint) == {"hookStatus": "SUCCEEDED"}


@pytest.mark.parametrize("value", ["false", "False", "1", "yes", "", " "])
def test_only_the_literal_true_enables_it(monkeypatch: pytest.MonkeyPatch, value: str) -> None:
    """Anything other than "true" leaves the gate closed.

    A flag that enables itself on any non-empty string is one typo away from
    disarming the hook it is not supposed to touch.
    """
    monkeypatch.setenv("BGD_ALLOW_UNSERVED", value)

    endpoint = _healthy()
    endpoint.connect_errors = [ConnectionRefusedError("Connection refused")] * 10

    with pytest.raises(HookRejected):
        _run(endpoint)


def test_allow_unserved_does_not_suppress_a_digest_mismatch(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The flag covers probe failures only, never the verdict on what is served.

    If the endpoint answers, every assertion past the probe still applies —
    otherwise setting this on PRE_SCALE_UP would quietly disable exit
    criterion 3's mechanism on that stage.
    """
    monkeypatch.setenv("BGD_STAGE", "PRE_SCALE_UP")
    monkeypatch.setenv("BGD_ALLOW_UNSERVED", "true")
    monkeypatch.setenv("BGD_EXPECT_DIGEST", "sha256:deadbeef")

    with pytest.raises(HookRejected) as rejection:
        _run(_healthy())

    assert "deadbeef" in str(rejection.value)
