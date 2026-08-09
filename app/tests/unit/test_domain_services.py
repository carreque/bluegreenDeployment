from datetime import UTC, datetime

import pytest

from bgd.domain.errors import (
    AccountNotFoundError,
    CurrencyMismatchError,
    InsufficientFundsError,
    InvariantViolationError,
)
from bgd.domain.models import TransactionType
from bgd.domain.services import LedgerService
from bgd.repository.memory import InMemoryLedgerRepository

FIXED_TIME = datetime(2026, 8, 5, 10, 0, 0, 123456, tzinfo=UTC)


@pytest.fixture
def service() -> LedgerService:
    counter = iter(f"acc_{index:04d}" for index in range(1000))
    return LedgerService(
        InMemoryLedgerRepository(),
        clock=lambda: FIXED_TIME,
        id_factory=lambda: next(counter),
    )


def test_open_account_assigns_an_id_and_the_opening_balance(service) -> None:
    account = service.open_account("Ada Lovelace", "EUR", initial_balance_minor=5_000)
    assert account.account_id == "acc_0000"
    assert account.balance.amount_minor == 5_000
    assert account.balance.currency == "EUR"
    assert account.created_at == FIXED_TIME


def test_open_account_defaults_to_a_zero_balance(service) -> None:
    assert service.open_account("Ada", "EUR").balance.amount_minor == 0


def test_open_account_rejects_a_negative_opening_balance(service) -> None:
    with pytest.raises(InvariantViolationError):
        service.open_account("Ada", "EUR", initial_balance_minor=-1)


def test_get_account_raises_for_an_unknown_id(service) -> None:
    with pytest.raises(AccountNotFoundError):
        service.get_account("acc_missing")


def test_posting_a_credit_returns_created_true(service) -> None:
    account = service.open_account("Ada", "EUR", 10_000)
    transaction, updated, created = service.post_transaction(
        account_id=account.account_id,
        transaction_type=TransactionType.CREDIT,
        amount_minor=1_500,
        currency="EUR",
        idempotency_key="key-1",
    )
    assert created is True
    assert updated.balance.amount_minor == 11_500
    assert transaction.type is TransactionType.CREDIT


def test_replaying_an_idempotency_key_returns_the_original_and_created_false(service) -> None:
    """The balance must move exactly once, and the caller must get the stored
    transaction back rather than an error."""
    account = service.open_account("Ada", "EUR", 10_000)
    kwargs = {
        "account_id": account.account_id,
        "transaction_type": TransactionType.DEBIT,
        "amount_minor": 2_500,
        "currency": "EUR",
        "idempotency_key": "key-1",
    }

    first, _, created_first = service.post_transaction(**kwargs)
    second, updated, created_second = service.post_transaction(**kwargs)

    assert created_first is True
    assert created_second is False
    assert second.transaction_id == first.transaction_id
    assert updated.balance.amount_minor == 7_500


def test_a_currency_that_differs_from_the_account_is_rejected(service) -> None:
    account = service.open_account("Ada", "EUR", 10_000)
    with pytest.raises(CurrencyMismatchError):
        service.post_transaction(
            account_id=account.account_id,
            transaction_type=TransactionType.DEBIT,
            amount_minor=100,
            currency="USD",
            idempotency_key="key-1",
        )


def test_posting_to_an_unknown_account_raises(service) -> None:
    with pytest.raises(AccountNotFoundError):
        service.post_transaction(
            account_id="acc_missing",
            transaction_type=TransactionType.CREDIT,
            amount_minor=100,
            currency="EUR",
            idempotency_key="key-1",
        )


def test_an_overdraft_is_rejected(service) -> None:
    account = service.open_account("Ada", "EUR", 1_000)
    with pytest.raises(InsufficientFundsError):
        service.post_transaction(
            account_id=account.account_id,
            transaction_type=TransactionType.DEBIT,
            amount_minor=2_500,
            currency="EUR",
            idempotency_key="key-1",
        )


def test_a_non_positive_amount_is_rejected(service) -> None:
    account = service.open_account("Ada", "EUR", 10_000)
    with pytest.raises(InvariantViolationError):
        service.post_transaction(
            account_id=account.account_id,
            transaction_type=TransactionType.DEBIT,
            amount_minor=0,
            currency="EUR",
            idempotency_key="key-1",
        )


def test_the_same_key_on_two_accounts_is_two_transactions(service) -> None:
    first = service.open_account("Ada", "EUR", 10_000)
    second = service.open_account("Grace", "EUR", 10_000)
    for account in (first, second):
        service.post_transaction(
            account_id=account.account_id,
            transaction_type=TransactionType.DEBIT,
            amount_minor=100,
            currency="EUR",
            idempotency_key="shared-key",
        )
    assert service.get_account(first.account_id).balance.amount_minor == 9_900
    assert service.get_account(second.account_id).balance.amount_minor == 9_900


def test_listing_transactions_for_an_unknown_account_raises(service) -> None:
    with pytest.raises(AccountNotFoundError):
        service.list_transactions("acc_missing")
