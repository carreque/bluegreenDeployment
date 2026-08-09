import pytest
from fastapi.testclient import TestClient

from bgd.api.main import create_app
from bgd.repository.memory import InMemoryLedgerRepository


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_app(repository=InMemoryLedgerRepository()))


def open_account(client: TestClient, **overrides) -> dict:
    payload = {"owner_name": "Ada Lovelace", "currency": "EUR", "initial_balance_minor": 10_000}
    payload.update(overrides)
    return client.post("/api/accounts", json=payload).json()


def test_creating_an_account_returns_201_and_the_resource(client) -> None:
    response = client.post(
        "/api/accounts",
        json={"owner_name": "Ada Lovelace", "currency": "EUR", "initial_balance_minor": 10_000},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["account_id"].startswith("acc_")
    assert body["owner_name"] == "Ada Lovelace"
    assert body["currency"] == "EUR"
    assert body["balance_minor"] == 10_000
    assert response.headers["location"] == f"/api/accounts/{body['account_id']}"


def test_the_opening_balance_defaults_to_zero(client) -> None:
    response = client.post("/api/accounts", json={"owner_name": "Ada", "currency": "EUR"})
    assert response.json()["balance_minor"] == 0


def test_an_account_can_be_fetched_by_id(client) -> None:
    created = open_account(client)
    response = client.get(f"/api/accounts/{created['account_id']}")
    assert response.status_code == 200
    assert response.json() == created


def test_fetching_an_unknown_account_is_404(client) -> None:
    assert client.get("/api/accounts/acc_missing").status_code == 404


def test_accounts_can_be_listed(client) -> None:
    open_account(client, owner_name="Ada")
    open_account(client, owner_name="Grace")
    body = client.get("/api/accounts").json()
    assert {item["owner_name"] for item in body["items"]} == {"Ada", "Grace"}


def test_the_list_limit_is_validated(client) -> None:
    assert client.get("/api/accounts?limit=0").status_code == 422
    assert client.get("/api/accounts?limit=1000").status_code == 422


@pytest.mark.parametrize(
    "payload",
    [
        {"owner_name": "", "currency": "EUR"},
        {"owner_name": "Ada", "currency": "eur"},
        {"owner_name": "Ada", "currency": "EURO"},
        {"owner_name": "Ada", "currency": "EUR", "initial_balance_minor": -1},
        {"currency": "EUR"},
        {"owner_name": "Ada", "currency": "EUR", "unexpected": "field"},
    ],
)
def test_invalid_payloads_are_rejected_with_422(client, payload) -> None:
    assert client.post("/api/accounts", json=payload).status_code == 422
