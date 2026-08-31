"""The lifecycle hook handler's contract, asserted offline.

urlopen is patched throughout, so this suite makes no network call, needs no
AWS session and runs on the app virtualenv's pytest with nothing added.

The most important test in the file is
test_unhealthy_raises_rather_than_returning_failed. It is the executable form of
plan D3: the exact payload ECS expects back from a lifecycle hook could not be
confirmed without an AWS session (plan F2), and the two possible mistakes are
not symmetric. A raised exception is an unambiguous invocation error under any
contract; a returned {"hookStatus": "FAILED"} that ECS does not parse promotes a
bad build to production. If someone later "tidies" the handler into a symmetric
return, that test is what stops them.
"""

import json
import urllib.error
import urllib.request
from unittest.mock import patch

import pytest

from lifecycle_hook.handler import HookRejected, handler

PROBE_URL = "https://api.carloscloudengineer.com"
TEST_LISTENER_URL = "https://api.carloscloudengineer.com:8443"
SERVED_DIGEST = "sha256:1111111111111111111111111111111111111111111111111111111111111111"

VERSION_BODY = json.dumps(
    {
        "version": "0.1.0",
        "git_sha": "84d4eb0",
        "image_digest": SERVED_DIGEST,
        "built_at": "2026-08-28T00:00:00Z",
    }
).encode()


class _Response:
    """The slice of an http.client.HTTPResponse the handler actually touches."""

    def __init__(self, status: int = 200, body: bytes = b"{}") -> None:
        self.status = status
        self._body = body

    def __enter__(self) -> _Response:
        return self

    def __exit__(self, *_exc: object) -> bool:
        return False

    def read(self) -> bytes:
        return self._body


class _FakeUrlopen:
    """Records every call, and answers by path.

    Values in `by_path` are either a _Response to return or an exception to
    raise, which is what lets one fake cover both the "server answered badly"
    and "server did not answer" branches.
    """

    def __init__(self, by_path: dict[str, object] | None = None) -> None:
        self.by_path = by_path or {}
        self.calls: list[tuple[str, float | None]] = []

    def __call__(self, url: str, timeout: float | None = None) -> _Response:
        self.calls.append((url, timeout))
        path = url.removeprefix(PROBE_URL).removeprefix(":8443") or "/"
        answer = self.by_path.get(path, _Response(200, b"{}"))
        if isinstance(answer, Exception):
            raise answer
        if path == "/version" and answer is None:
            answer = _Response(200, VERSION_BODY)
        return answer

    @property
    def paths(self) -> list[str]:
        return [url.removeprefix(PROBE_URL).removeprefix(":8443") for url, _ in self.calls]


def _healthy(**overrides: object) -> _FakeUrlopen:
    by_path: dict[str, object] = {
        "/health": _Response(200, b'{"status":"ok"}'),
        "/ready": _Response(200, b'{"status":"ready"}'),
        "/version": _Response(200, VERSION_BODY),
    }
    by_path.update(overrides)
    return _FakeUrlopen(by_path)


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


def _run(fake: _FakeUrlopen) -> dict[str, str]:
    with patch.object(urllib.request, "urlopen", fake):
        return handler({"executionDetails": {}}, None)


def test_all_probes_pass_returns_succeeded() -> None:
    assert _run(_healthy()) == {"hookStatus": "SUCCEEDED"}


def test_probes_are_the_expected_three_paths() -> None:
    """/ready is in the set deliberately — it is what carries the dark canary.

    /health reports only that the process is alive. A green task that starts but
    cannot reach its DynamoDB table passes /health and fails /ready, and that is
    precisely the failure the POST_TEST_TRAFFIC_SHIFT hook exists to catch
    before promotion. Plan D2.
    """
    fake = _healthy()
    _run(fake)

    assert fake.paths == ["/health", "/ready", "/version"]
    assert all(url.startswith(PROBE_URL) for url, _ in fake.calls)


def test_unhealthy_raises_rather_than_returning_failed() -> None:
    """Plan D3, and the most important assertion in this file.

    Returning {"hookStatus": "FAILED"} would be correct under one plausible
    contract and catastrophic under the other. Raising is correct under both.
    """
    fake = _healthy(**{"/health": _Response(500, b"")})

    with pytest.raises(HookRejected):
        _run(fake)


def test_ready_failure_raises() -> None:
    """A 503 from /ready specifically, delivered the way urlopen really delivers it.

    urlopen raises HTTPError on a non-2xx rather than returning it, so this is
    the branch that runs against a real green task whose table is unreachable.
    """
    error = urllib.error.HTTPError(
        url=f"{PROBE_URL}/ready", code=503, msg="Service Unavailable", hdrs=None, fp=None
    )
    fake = _healthy(**{"/ready": error})

    with pytest.raises(HookRejected):
        _run(fake)


def test_timeout_raises() -> None:
    """A URLError must not escape as an unhandled type.

    An unhandled exception would still fail the invocation, and D3 would still
    make ECS reject the build — but the CloudWatch line would name a Python
    traceback rather than the probe that failed, and that line is the hook's
    only trace.
    """
    fake = _healthy(**{"/ready": urllib.error.URLError(TimeoutError("timed out"))})

    with pytest.raises(HookRejected):
        _run(fake)


def test_ready_is_allowed_a_longer_timeout_than_the_others() -> None:
    """Phase 5's F5 measured /ready taking 25.6s to fail when DynamoDB is
    unreachable, because botocore retries with backoff. A 10-second probe would
    report a timeout and hide the 503 that names the real cause — on exactly the
    failure this hook exists to catch.
    """
    fake = _healthy()
    _run(fake)

    by_path = dict(zip(fake.paths, [timeout for _, timeout in fake.calls], strict=True))
    assert by_path["/ready"] >= 30
    assert by_path["/health"] == 10
    assert by_path["/version"] == 10


def test_timeout_seconds_is_honoured_when_set() -> None:
    fake = _healthy()

    with patch.dict("os.environ", {"BGD_TIMEOUT_SECONDS": "45"}):
        _run(fake)

    by_path = dict(zip(fake.paths, [timeout for _, timeout in fake.calls], strict=True))
    assert by_path["/health"] == 45
    # Already above the floor, so the floor must not lower it.
    assert by_path["/ready"] == 45


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
    fake = _healthy(**{"/version": _Response(200, unknown)})

    assert _run(fake) == {"hookStatus": "SUCCEEDED"}


def test_missing_probe_url_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    """Raise before probing rather than probing "None/health"."""
    monkeypatch.delenv("BGD_PROBE_URL")
    fake = _healthy()

    with pytest.raises(HookRejected) as rejection:
        _run(fake)

    assert "BGD_PROBE_URL" in str(rejection.value)
    assert fake.calls == []


def test_missing_stage_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("BGD_STAGE")

    with pytest.raises(HookRejected) as rejection:
        _run(_healthy())

    assert "BGD_STAGE" in str(rejection.value)


def test_failure_message_names_path_and_status() -> None:
    """A hook rejection's only trace is this string in CloudWatch.

    The runbook reads it to tell "green never became healthy" apart from "green
    was healthy and served the wrong image", and those two have entirely
    different next steps.
    """
    fake = _healthy(**{"/ready": _Response(503, b"")})

    with pytest.raises(HookRejected) as rejection:
        _run(fake)

    assert "/ready" in str(rejection.value)
    assert "503" in str(rejection.value)


def test_unreachable_message_names_the_path() -> None:
    fake = _healthy(**{"/health": urllib.error.URLError("connection refused")})

    with pytest.raises(HookRejected) as rejection:
        _run(fake)

    assert "/health" in str(rejection.value)


def test_version_body_that_is_not_json_raises() -> None:
    """An ALB error page instead of the application's JSON is a rejection, not a
    crash — the difference between a message naming /version and a traceback.
    """
    fake = _healthy(**{"/version": _Response(200, b"<html>502 Bad Gateway</html>")})

    with pytest.raises(HookRejected) as rejection:
        _run(fake)

    assert "/version" in str(rejection.value)


def test_the_test_listener_url_is_probed_verbatim() -> None:
    """The dark canary's identity: this instance probes :8443, so it validates
    the colour that is NOT yet serving users. A hook pointed at :443 at
    POST_TEST_TRAFFIC_SHIFT validates the old colour and approves every bad
    build. Plan D2, and the worst failure this layer can have.
    """
    fake = _healthy()

    with patch.dict("os.environ", {"BGD_PROBE_URL": TEST_LISTENER_URL}):
        _run(fake)

    assert fake.paths == ["/health", "/ready", "/version"]
    assert all(url.startswith(TEST_LISTENER_URL) for url, _ in fake.calls)


def test_a_trailing_slash_on_the_probe_url_does_not_double(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BGD_PROBE_URL", f"{PROBE_URL}/")
    fake = _healthy()

    _run(fake)

    assert fake.paths == ["/health", "/ready", "/version"]


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

    fake = _healthy(**{"/health": urllib.error.URLError("Connection refused")})

    assert _run(fake) == {"hookStatus": "SUCCEEDED"}


def test_unreachable_endpoint_still_raises_without_the_flag() -> None:
    """The default, and what the other two stages rely on.

    Identical to the case above except for the flag. If this ever passes, the
    dark canary has been turned into a log line.
    """
    fake = _healthy(**{"/health": urllib.error.URLError("Connection refused")})

    with pytest.raises(HookRejected):
        _run(fake)


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

    fake = _healthy(**{"/health": _Response(500, b"")})

    assert _run(fake) == {"hookStatus": "SUCCEEDED"}


@pytest.mark.parametrize("value", ["false", "False", "1", "yes", "", " "])
def test_only_the_literal_true_enables_it(
    monkeypatch: pytest.MonkeyPatch, value: str
) -> None:
    """Anything other than "true" leaves the gate closed.

    A flag that enables itself on any non-empty string is one typo away from
    disarming the hook it is not supposed to touch.
    """
    monkeypatch.setenv("BGD_ALLOW_UNSERVED", value)

    fake = _healthy(**{"/health": urllib.error.URLError("Connection refused")})

    with pytest.raises(HookRejected):
        _run(fake)


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
