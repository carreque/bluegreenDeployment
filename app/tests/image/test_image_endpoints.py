"""Every endpoint, against the real image, over real HTTP.

tests/api/ already covers these against an in-process app and an in-memory
fake. This suite answers a different question: does the packaged artifact —
this interpreter, this virtualenv, this PYTHONPATH, this unprivileged UID —
actually serve them.
"""

import uuid

import httpx2
import pytest

pytestmark = pytest.mark.image


def test_health_is_alive(client: httpx2.Client) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_ready_reports_dynamodb_reachable(client: httpx2.Client) -> None:
    """Proves the container's egress to DynamoDB Local, not just its liveness."""
    response = client.get("/ready")
    assert response.status_code == 200, response.text
    assert response.json()["checks"]["dynamodb"] == "ok"


def test_an_account_can_be_created_and_read_back(client: httpx2.Client) -> None:
    created = client.post(
        "/api/accounts",
        json={"owner_name": "Container Smoke", "currency": "EUR"},
    )
    assert created.status_code == 201, created.text
    account_id = created.json()["account_id"]

    fetched = client.get(f"/api/accounts/{account_id}")
    assert fetched.status_code == 200
    assert fetched.json()["owner_name"] == "Container Smoke"


def test_a_transaction_moves_the_balance(client: httpx2.Client) -> None:
    account_id = client.post(
        "/api/accounts", json={"owner_name": "Ledger Smoke", "currency": "EUR"}
    ).json()["account_id"]

    posted = client.post(
        "/api/transactions",
        json={
            "account_id": account_id,
            "type": "CREDIT",
            "amount_minor": 5000,
            "currency": "EUR",
            "idempotency_key": uuid.uuid4().hex,
        },
    )
    assert posted.status_code == 201, posted.text

    balance = client.get(f"/api/accounts/{account_id}").json()["balance_minor"]
    assert balance == 5000


def test_a_missing_account_is_a_problem_document(client: httpx2.Client) -> None:
    """The RFC 9457 envelope survives packaging, headers included."""
    response = client.get("/api/accounts/acc_does_not_exist")
    assert response.status_code == 404
    assert response.headers["content-type"].startswith("application/problem+json")
    assert response.json()["code"] == "ACCOUNT_NOT_FOUND"


def test_the_demonstration_page_ships_in_the_image(client: httpx2.Client) -> None:
    """F4 reasons that static/ is covered by `COPY src/`. This checks it.

    The failure mode if it is not: `make test` stays green, because the tests
    read the files from the working copy, and the deployed container answers
    500 on `/` — found in a browser rather than in CI.
    """
    page = client.get("/")
    assert page.status_code == 200, page.text
    assert page.headers["content-type"] == "text/html; charset=utf-8"

    for path, media_type in (("/app.css", "text/css"), ("/app.js", "text/javascript")):
        asset = client.get(path)
        assert asset.status_code == 200, path
        assert asset.headers["content-type"] == f"{media_type}; charset=utf-8"
        assert asset.headers["cache-control"] == "no-store"
