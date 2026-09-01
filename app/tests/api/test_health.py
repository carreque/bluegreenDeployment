import pytest
from fastapi.testclient import TestClient

from bgd.api.main import create_app
from bgd.config import Settings
from bgd.domain.errors import RepositoryUnavailableError
from bgd.repository.memory import InMemoryLedgerRepository


@pytest.fixture
def client() -> TestClient:
    settings = Settings(
        _env_file=None,
        app_version="1.2.345",
        git_sha="deadbee",
        image_digest="sha256:abc123",
        built_at="2026-08-05T10:00:00Z",
        release_color="green",
    )
    return TestClient(create_app(repository=InMemoryLedgerRepository(), settings=settings))


def test_health_is_liveness_only(client) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_health_never_touches_the_repository() -> None:
    """The ALB target-group health check calls this. If it consulted DynamoDB,
    a dependency hiccup would deregister healthy tasks and take the service
    down — so a repository that raises on every call must not affect it."""

    class ExplodingRepository(InMemoryLedgerRepository):
        def ping(self) -> None:
            raise AssertionError("/health must never call ping()")

    client = TestClient(create_app(repository=ExplodingRepository()))
    assert client.get("/health").status_code == 200


def test_ready_reports_the_dependency_as_ok(client) -> None:
    response = client.get("/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ready", "checks": {"dynamodb": "ok"}}


def test_ready_returns_503_when_the_store_is_unreachable() -> None:
    class UnreachableRepository(InMemoryLedgerRepository):
        def ping(self) -> None:
            raise RepositoryUnavailableError("nope")

    client = TestClient(create_app(repository=UnreachableRepository()))
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.json()["checks"]["dynamodb"] == "unavailable"


def test_version_reports_the_injected_build_metadata(client) -> None:
    """Phase 6 curls this against :443 and :8443 during a blue/green shift.
    Two different git_sha values is the direct proof of which colour serves
    whom, so these fields are a contract with Phase 6, not decoration.

    Phase 12 adds release_color and polls this endpoint from the browser every
    two seconds; the field is the page's entire input.
    """
    body = client.get("/version").json()
    assert body == {
        "version": "1.2.345",
        "git_sha": "deadbee",
        "image_digest": "sha256:abc123",
        "built_at": "2026-08-05T10:00:00Z",
        "release_color": "green",
    }


def test_version_is_never_cached(client) -> None:
    """The whole demonstration is 'which build answered this request'.

    A cached /version defeats it silently: the page keeps showing the previous
    build's colour after a shift and looks like it is working. Phase 12, D8.
    """
    assert client.get("/version").headers["cache-control"] == "no-store"


def test_every_response_carries_a_request_id_header(client) -> None:
    assert len(client.get("/health").headers["x-request-id"]) == 32


def test_a_supplied_request_id_is_echoed(client) -> None:
    response = client.get("/health", headers={"X-Request-ID": "req-abc"})
    assert response.headers["x-request-id"] == "req-abc"
