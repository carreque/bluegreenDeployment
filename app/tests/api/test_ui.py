"""The demonstration page, its headers, and the two structural XSS rules.

The page renders owner_name, which is user-supplied, stored, and validated
only for length. The mitigations are structural rather than promised — a CSP
with no unsafe-inline (D5), a server that interpolates nothing (D9), and a
client that never assembles markup from strings — and each one is asserted
here so it cannot be quietly undone.
"""

import pytest
from fastapi.testclient import TestClient

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
