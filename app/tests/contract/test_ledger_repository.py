"""The LedgerRepository contract.

Every implementation must satisfy all of this. The fake exists so the API tests
never touch boto3; this suite is what makes the fake trustworthy.
"""

from datetime import UTC, datetime, timedelta

import pytest

from bgd.domain.errors import (
    AccountAlreadyExistsError,
    AccountNotFoundError,
    DuplicateTransactionError,
    InsufficientFundsError,
)
from bgd.domain.models import (
    Account,
    Money,
    Transaction,
    TransactionType,
    to_iso,
    transaction_id_for,
    utcnow,
)

BASE_TIME = datetime(2026, 8, 5, 10, 0, 0, tzinfo=UTC)


def at(seconds: int) -> datetime:
    """Explicit, well-separated timestamps for the ordering tests.

    utcnow() would be correct but flaky here: these calls are direct dict
    operations, so two can land in the same microsecond, and the sort tiebreak
    is a uuid5 hash rather than anything chronological.
    """
    return BASE_TIME + timedelta(seconds=seconds)


def make_account(account_id: str = "acc_1", balance_minor: int = 10_000) -> Account:
    return Account(
        account_id=account_id,
        owner_name="Ada Lovelace",
        balance=Money(balance_minor, "EUR"),
        created_at=utcnow(),
    )


def make_transaction(
    account_id: str = "acc_1",
    kind: TransactionType = TransactionType.DEBIT,
    amount_minor: int = 2_500,
    key: str = "key-1",
    created_at: datetime | None = None,
) -> Transaction:
    return Transaction(
        transaction_id=transaction_id_for(account_id, key),
        account_id=account_id,
        type=kind,
        amount=Money(amount_minor, "EUR"),
        idempotency_key=key,
        description="rent",
        created_at=created_at if created_at is not None else utcnow(),
    )


# --- accounts ---------------------------------------------------------------


def test_an_account_round_trips(repository) -> None:
    account = make_account()
    repository.create_account(account)
    fetched = repository.get_account("acc_1")
    assert fetched is not None
    assert fetched.account_id == "acc_1"
    assert fetched.owner_name == "Ada Lovelace"
    assert fetched.balance == Money(10_000, "EUR")


def test_an_unknown_account_is_none(repository) -> None:
    assert repository.get_account("acc_missing") is None


def test_creating_the_same_account_twice_is_rejected(repository) -> None:
    repository.create_account(make_account())
    with pytest.raises(AccountAlreadyExistsError):
        repository.create_account(make_account())


def test_accounts_can_be_listed(repository) -> None:
    repository.create_account(make_account("acc_1"))
    repository.create_account(make_account("acc_2"))
    assert {a.account_id for a in repository.list_accounts()} == {"acc_1", "acc_2"}


def test_listing_accounts_honours_the_limit(repository) -> None:
    for index in range(5):
        repository.create_account(make_account(f"acc_{index}"))
    assert len(repository.list_accounts(limit=3)) == 3


# --- posting transactions ---------------------------------------------------


def test_a_credit_increases_the_balance(repository) -> None:
    repository.create_account(make_account(balance_minor=10_000))
    account = repository.post_transaction(
        make_transaction(kind=TransactionType.CREDIT, amount_minor=1_500)
    )
    assert account.balance.amount_minor == 11_500


def test_a_debit_decreases_the_balance(repository) -> None:
    repository.create_account(make_account(balance_minor=10_000))
    account = repository.post_transaction(
        make_transaction(kind=TransactionType.DEBIT, amount_minor=2_500)
    )
    assert account.balance.amount_minor == 7_500


def test_a_debit_may_bring_the_balance_exactly_to_zero(repository) -> None:
    repository.create_account(make_account(balance_minor=2_500))
    account = repository.post_transaction(
        make_transaction(kind=TransactionType.DEBIT, amount_minor=2_500)
    )
    assert account.balance.amount_minor == 0


def test_a_debit_beyond_the_balance_is_rejected(repository) -> None:
    repository.create_account(make_account(balance_minor=1_000))
    with pytest.raises(InsufficientFundsError):
        repository.post_transaction(
            make_transaction(kind=TransactionType.DEBIT, amount_minor=2_500)
        )


def test_a_rejected_debit_writes_nothing_at_all(repository) -> None:
    """The atomicity guarantee. If the balance condition fails, the transaction
    record must not survive — otherwise the history shows a payment that never
    happened."""
    repository.create_account(make_account(balance_minor=1_000))
    transaction = make_transaction(kind=TransactionType.DEBIT, amount_minor=2_500)
    with pytest.raises(InsufficientFundsError):
        repository.post_transaction(transaction)

    assert repository.get_account("acc_1").balance.amount_minor == 1_000
    assert repository.get_transaction("acc_1", transaction.transaction_id) is None
    assert repository.list_transactions("acc_1").items == []


def test_posting_to_an_unknown_account_is_rejected(repository) -> None:
    with pytest.raises(AccountNotFoundError):
        repository.post_transaction(make_transaction(account_id="acc_missing"))


def test_the_same_transaction_id_is_rejected_and_applied_once(repository) -> None:
    repository.create_account(make_account(balance_minor=10_000))
    transaction = make_transaction(amount_minor=2_500)
    repository.post_transaction(transaction)

    with pytest.raises(DuplicateTransactionError):
        repository.post_transaction(transaction)

    assert repository.get_account("acc_1").balance.amount_minor == 7_500


# --- reading transactions ---------------------------------------------------


def test_a_transaction_round_trips(repository) -> None:
    repository.create_account(make_account())
    transaction = make_transaction()
    repository.post_transaction(transaction)

    fetched = repository.get_transaction("acc_1", transaction.transaction_id)
    assert fetched is not None
    assert fetched.amount == Money(2_500, "EUR")
    assert fetched.type is TransactionType.DEBIT
    assert fetched.idempotency_key == "key-1"
    assert fetched.description == "rent"


def test_an_unknown_transaction_is_none(repository) -> None:
    assert repository.get_transaction("acc_1", "txn_missing") is None


def test_transactions_are_listed_newest_first(repository) -> None:
    repository.create_account(make_account(balance_minor=100_000))
    for index in range(3):
        repository.post_transaction(
            make_transaction(amount_minor=100 + index, key=f"k{index}", created_at=at(index))
        )

    listed = repository.list_transactions("acc_1").items
    assert [t.amount.amount_minor for t in listed] == [102, 101, 100]


def test_listing_transactions_paginates_with_an_opaque_cursor(repository) -> None:
    repository.create_account(make_account(balance_minor=100_000))
    for index in range(5):
        repository.post_transaction(
            make_transaction(amount_minor=100 + index, key=f"k{index}", created_at=at(index))
        )

    first = repository.list_transactions("acc_1", limit=2)
    assert len(first.items) == 2
    assert isinstance(first.next_cursor, str)

    second = repository.list_transactions("acc_1", limit=2, cursor=first.next_cursor)
    assert len(second.items) == 2

    seen = [t.amount.amount_minor for t in first.items + second.items]
    assert seen == [104, 103, 102, 101]
    assert len(set(seen)) == 4


def test_the_last_page_reports_no_cursor(repository) -> None:
    repository.create_account(make_account(balance_minor=100_000))
    repository.post_transaction(make_transaction(key="k0"))
    assert repository.list_transactions("acc_1", limit=10).next_cursor is None


def test_listing_transactions_for_an_unknown_account_is_empty(repository) -> None:
    page = repository.list_transactions("acc_missing")
    assert page.items == []
    assert page.next_cursor is None


def test_transactions_of_other_accounts_are_not_returned(repository) -> None:
    repository.create_account(make_account("acc_1"))
    repository.create_account(make_account("acc_2"))
    repository.post_transaction(make_transaction(account_id="acc_1", key="k1"))
    repository.post_transaction(make_transaction(account_id="acc_2", key="k2"))

    assert len(repository.list_transactions("acc_1").items) == 1


# --- health -----------------------------------------------------------------


def test_ping_succeeds_when_the_store_is_reachable(repository) -> None:
    repository.ping()


def test_created_at_is_stored_as_a_fixed_width_string(repository) -> None:
    """Guards the LSI sort key format across both backends."""
    repository.create_account(make_account())
    transaction = make_transaction()
    repository.post_transaction(transaction)
    fetched = repository.get_transaction("acc_1", transaction.transaction_id)
    assert len(to_iso(fetched.created_at)) == 27
