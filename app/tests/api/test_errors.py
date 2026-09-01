"""The error envelope, tested independently of the business endpoints.

The app under test registers its own throwaway probe routes rather than calling
/api/accounts. Error representation is a property of the API shell, and tying
these assertions to business routes would make them fail for reasons that have
nothing to do with the envelope — and would make this task depend on the next
one.
"""

import pytest
from fastapi.testclient import TestClient
from pydantic import BaseModel, Field

from bgd.api.errors import STATUS_BY_CODE
from bgd.api.main import create_app
from bgd.domain.errors import AccountNotFoundError, DomainError, RepositoryUnavailableError
from bgd.repository.memory import InMemoryLedgerRepository


class Payload(BaseModel):
    amount_minor: int = Field(gt=0)


@pytest.fixture
def client() -> TestClient:
    app = create_app(repository=InMemoryLedgerRepository())

    @app.get("/probe/domain-error")
    def _domain_error() -> None:
        raise AccountNotFoundError("no such account", account_id="acc_missing")

    @app.get("/probe/unavailable")
    def _unavailable() -> None:
        raise RepositoryUnavailableError("the data store is unavailable")

    @app.post("/probe/validated")
    def _validated(payload: Payload) -> dict:
        return {"amount_minor": payload.amount_minor}

    @app.get("/probe/boom")
    def _boom() -> None:
        raise RuntimeError("secret internal detail")

    return TestClient(app, raise_server_exceptions=False)


def test_a_domain_error_becomes_an_rfc_9457_problem(client) -> None:
    response = client.get("/probe/domain-error")
    assert response.status_code == 404
    assert response.headers["content-type"].startswith("application/problem+json")

    body = response.json()
    assert body["code"] == "ACCOUNT_NOT_FOUND"
    assert body["status"] == 404
    assert body["title"] == "Not Found"
    assert body["type"].endswith("/account-not-found")
    assert body["instance"] == "/probe/domain-error"
    assert body["request_id"]


def test_domain_error_details_are_merged_into_the_problem(client) -> None:
    assert client.get("/probe/domain-error").json()["account_id"] == "acc_missing"


def test_an_unavailable_repository_becomes_503(client) -> None:
    response = client.get("/probe/unavailable")
    assert response.status_code == 503
    assert response.json()["code"] == "REPOSITORY_UNAVAILABLE"


def test_a_validation_failure_becomes_a_422_problem_with_field_errors(client) -> None:
    response = client.post("/probe/validated", json={"amount_minor": -1})
    assert response.status_code == 422
    assert response.headers["content-type"].startswith("application/problem+json")

    body = response.json()
    assert body["code"] == "VALIDATION_FAILED"
    assert body["errors"][0]["field"] == "amount_minor"


def test_an_unknown_route_becomes_a_problem_document(client) -> None:
    response = client.get("/nope")
    assert response.status_code == 404
    assert response.headers["content-type"].startswith("application/problem+json")
    assert response.json()["code"] == "NOT_FOUND"


def test_an_unhandled_exception_becomes_a_500_that_leaks_nothing(client) -> None:
    """A stack trace or an internal message in the response body is an
    information-disclosure bug. request_id is the link to the log line that
    does carry the detail."""
    response = client.get("/probe/boom")
    assert response.status_code == 500
    assert response.json()["code"] == "INTERNAL_ERROR"
    assert "secret internal detail" not in response.text
    # "-" is the ContextVar default and is truthy, so assert against it by
    # name: a body carrying the sentinel is a body carrying no link at all.
    assert response.json()["request_id"] != "-"


def test_an_unhandled_exception_still_reports_the_caller_s_request_id(client) -> None:
    """The 500 body is the caller's only copy of the id — there is no
    x-request-id header on this path, because ServerErrorMiddleware emits the
    response outside RequestContextMiddleware's send wrapper. That same
    ordering resets the ContextVar before the handler runs, so the id has to
    reach it by another route.
    """
    response = client.get("/probe/boom", headers={"x-request-id": "known-id-123"})
    assert response.status_code == 500
    assert response.json()["request_id"] == "known-id-123"


def test_an_unhandled_exception_carries_no_security_headers(client) -> None:
    """A deliberate gap, asserted so that closing it wrongly is a red test.

    @app.exception_handler(Exception) is wired to ServerErrorMiddleware
    (Starlette's stack is ServerErrorMiddleware -> user middleware ->
    ExceptionMiddleware -> router), one layer outside both
    RequestContextMiddleware and SecurityHeadersMiddleware. The response this
    handler builds is sent straight through the raw `send`, the same reason
    it carries no x-request-id header (see the test above). It carries none
    of SECURITY_HEADERS either — no CSP, no nosniff, no X-Frame-Options, no
    Referrer-Policy. Left alone rather than closed: the body on this path is
    a fixed application/problem+json document with no request-derived
    content, so there is nothing here for those headers to protect.
    """
    response = client.get("/probe/boom")
    assert response.status_code == 500
    assert "content-security-policy" not in response.headers
    assert "x-content-type-options" not in response.headers
    assert "x-frame-options" not in response.headers
    assert "referrer-policy" not in response.headers
    assert "x-request-id" not in response.headers


def test_every_domain_error_code_has_a_status(client) -> None:
    """A new DomainError subclass with no entry in STATUS_BY_CODE would
    silently become a 500. Walking the subclasses is what keeps the map
    honest as the domain grows."""

    def subclasses(cls: type) -> set[type]:
        direct = set(cls.__subclasses__())
        return direct.union(*(subclasses(child) for child in direct)) if direct else direct

    missing = {cls.code for cls in subclasses(DomainError)} - set(STATUS_BY_CODE)
    assert not missing, f"DomainError subclasses with no status mapping: {sorted(missing)}"
