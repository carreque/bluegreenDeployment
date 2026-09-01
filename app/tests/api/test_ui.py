"""The demonstration page, its headers, and the two structural XSS rules.

The page renders owner_name, which is user-supplied, stored, and validated
only for length. The mitigations are structural rather than promised — a CSP
with no unsafe-inline (D5), a server that interpolates nothing (D9), and a
client that never assembles markup from strings — and each one is asserted
here so it cannot be quietly undone.
"""

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import bgd.api
from bgd.api.main import create_app
from bgd.repository.memory import InMemoryLedgerRepository


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_app(repository=InMemoryLedgerRepository()))


def test_every_response_carries_the_security_headers(client) -> None:
    """On the JSON API too, not only on the page.

    One policy for the whole application costs nothing and means a header
    cannot be lost by a route being registered somewhere unexpected.
    """
    headers = client.get("/health").headers
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["referrer-policy"] == "no-referrer"
    assert headers["x-frame-options"] == "DENY"
    assert "content-security-policy" in headers


def test_the_csp_has_no_inline_escape_hatch(client) -> None:
    """The entire reason the page is three files rather than one (D5).

    A single self-contained HTML file forces script-src 'unsafe-inline', which
    is the one directive that makes a CSP close to worthless.
    """
    policy = client.get("/health").headers["content-security-policy"]
    assert "unsafe-inline" not in policy
    assert "unsafe-eval" not in policy
    assert "default-src 'none'" in policy
    assert "script-src 'self'" in policy
    assert "connect-src 'self'" in policy


def test_the_request_id_header_survives_the_new_middleware(client) -> None:
    """Two middlewares now append to http.response.start. Both must land."""
    response = client.get("/health")
    assert len(response.headers["x-request-id"]) == 32
    assert response.headers["x-frame-options"] == "DENY"


STATIC = Path(bgd.api.__file__).resolve().parent / "static"


def test_the_page_is_served_at_the_root(client) -> None:
    response = client.get("/")
    assert response.status_code == 200
    assert response.headers["content-type"] == "text/html; charset=utf-8"


def test_the_stylesheet_and_script_are_served(client) -> None:
    """Typed exactly, because nosniff makes the content type load-bearing.

    With X-Content-Type-Options: nosniff a stylesheet served as text/plain is
    not applied and a script served as text/plain is not executed — the page
    would render unstyled and untinted with no error anywhere but the console.
    """
    css = client.get("/app.css")
    assert css.status_code == 200
    assert css.headers["content-type"] == "text/css; charset=utf-8"

    js = client.get("/app.js")
    assert js.status_code == 200
    assert js.headers["content-type"] == "text/javascript; charset=utf-8"


@pytest.mark.parametrize("path", ["/", "/app.css", "/app.js"])
def test_the_page_and_its_assets_are_never_cached(client, path: str) -> None:
    """D8. A cached page shows the previous build's colour after a shift."""
    assert client.get(path).headers["cache-control"] == "no-store"


@pytest.mark.parametrize(
    ("path", "filename"),
    [("/", "index.html"), ("/app.css", "app.css"), ("/app.js", "app.js")],
)
def test_each_response_is_the_file_on_disk_byte_for_byte(client, path: str, filename: str) -> None:
    """D9's first structural rule: the server interpolates nothing.

    Not "the server escapes correctly" — the server has nothing to escape,
    because request-derived and database-derived data never enter these three
    responses at all. This is the assertion that keeps it that way.
    """
    assert client.get(path).content == (STATIC / filename).read_bytes()


def test_the_script_never_assembles_markup_from_strings(client) -> None:
    """D9's second structural rule, as a test rather than a promise.

    owner_name is user-supplied, stored, and rendered back. Every row is built
    with createElement plus textContent; one innerHTML assignment anywhere in
    this file would turn a stored name into stored script.
    """
    source = client.get("/app.js").text
    assert "innerHTML" not in source
    assert "outerHTML" not in source
    assert "insertAdjacentHTML" not in source
    assert "document.write" not in source


@pytest.mark.parametrize("path", ["/health", "/ready", "/version"])
def test_the_operational_routes_still_answer(client, path: str) -> None:
    """The UI router is prefix-free and registered last.

    A mistake in registration order is exactly the kind of thing that silently
    changes what the ALB target-group health check hits, and it would present
    as a deployment that never goes healthy rather than as a broken page.
    """
    assert client.get(path).status_code == 200


def test_the_page_is_not_in_the_openapi_schema(client) -> None:
    """Three HTML routes in the API schema would be noise in /openapi.json."""
    paths = client.get("/openapi.json").json()["paths"]
    assert "/" not in paths
    assert "/app.js" not in paths
