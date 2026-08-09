import pytest
from fastapi.testclient import TestClient

from bgd.api.main import create_app
from bgd.repository.memory import InMemoryLedgerRepository


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_app(repository=InMemoryLedgerRepository()))


@pytest.fixture
def account_id(client: TestClient) -> str:
    response = client.post(
        "/api/accounts",
        json={"owner_name": "Ada", "currency": "EUR", "initial_balance_minor": 10_000},
    )
    return response.json()["account_id"]


def post_transaction(client: TestClient, account_id: str, **overrides):
    payload = {
        "account_id": account_id,
        "type": "DEBIT",
        "amount_minor": 2_500,
        "currency": "EUR",
        "idempotency_key": "key-1",
        "description": "rent",
    }
    payload.update(overrides)
    return client.post("/api/transactions", json=payload)


def balance(client: TestClient, account_id: str) -> int:
    return client.get(f"/api/accounts/{account_id}").json()["balance_minor"]


def test_a_debit_returns_201_and_moves_the_balance(client, account_id) -> None:
    response = post_transaction(client, account_id)
    assert response.status_code == 201
    body = response.json()
    assert body["transaction_id"].startswith("txn_")
    assert body["type"] == "DEBIT"
    assert body["amount_minor"] == 2_500
    assert balance(client, account_id) == 7_500


def test_a_credit_moves_the_balance_the_other_way(client, account_id) -> None:
    post_transaction(client, account_id, type="CREDIT", amount_minor=1_500)
    assert balance(client, account_id) == 11_500


def test_replaying_the_idempotency_key_returns_200_not_201(client, account_id) -> None:
    """A retry must be safe. 201 says 'created', 200 says 'you already did
    this' — and the balance must have moved exactly once either way."""
    first = post_transaction(client, account_id)
    second = post_transaction(client, account_id)

    assert first.status_code == 201
    assert second.status_code == 200
    assert second.json()["transaction_id"] == first.json()["transaction_id"]
    assert balance(client, account_id) == 7_500


def test_an_overdraft_is_409_with_the_balance_in_the_problem(client, account_id) -> None:
    response = post_transaction(client, account_id, amount_minor=50_000)
    assert response.status_code == 409
    body = response.json()
    assert body["code"] == "INSUFFICIENT_FUNDS"
    assert body["balance_minor"] == 10_000
    assert body["requested_minor"] == 50_000
    assert balance(client, account_id) == 10_000


def test_a_currency_mismatch_is_422(client, account_id) -> None:
    response = post_transaction(client, account_id, currency="USD")
    assert response.status_code == 422
    assert response.json()["code"] == "CURRENCY_MISMATCH"


def test_posting_to_an_unknown_account_is_404(client) -> None:
    response = post_transaction(client, "acc_missing")
    assert response.status_code == 404
    assert response.json()["code"] == "ACCOUNT_NOT_FOUND"


@pytest.mark.parametrize(
    "overrides",
    [
        {"amount_minor": 0},
        {"amount_minor": -100},
        {"type": "TRANSFER"},
        {"currency": "eur"},
        {"idempotency_key": ""},
    ],
)
def test_invalid_transaction_payloads_are_422(client, account_id, overrides) -> None:
    assert post_transaction(client, account_id, **overrides).status_code == 422


def test_transactions_are_listed_newest_first(client, account_id) -> None:
    for index in range(3):
        post_transaction(client, account_id, amount_minor=100 + index, idempotency_key=f"k{index}")

    items = client.get(f"/api/transactions?account_id={account_id}").json()["items"]
    assert [item["amount_minor"] for item in items] == [102, 101, 100]


def test_listing_transactions_paginates(client, account_id) -> None:
    for index in range(5):
        post_transaction(client, account_id, amount_minor=100 + index, idempotency_key=f"k{index}")

    first = client.get(f"/api/transactions?account_id={account_id}&limit=2").json()
    assert len(first["items"]) == 2
    assert first["next_cursor"]

    second = client.get(
        f"/api/transactions?account_id={account_id}&limit=2&cursor={first['next_cursor']}"
    ).json()
    assert [item["amount_minor"] for item in second["items"]] == [102, 101]


def test_listing_transactions_for_an_unknown_account_is_404(client) -> None:
    assert client.get("/api/transactions?account_id=acc_missing").status_code == 404


def test_account_id_is_required_when_listing(client) -> None:
    assert client.get("/api/transactions").status_code == 422
