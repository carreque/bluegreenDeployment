from datetime import UTC, datetime

import pytest

from bgd.domain.errors import DomainError, InvariantViolationError
from bgd.domain.models import (
    Account,
    Money,
    Transaction,
    TransactionType,
    from_iso,
    new_account_id,
    to_iso,
    transaction_id_for,
    utcnow,
)

WHEN = datetime(2026, 8, 5, 10, 0, 0, 123456, tzinfo=UTC)


def test_domain_error_carries_a_code_and_details() -> None:
    error = DomainError("nope", account_id="acc_1")
    assert error.code == "DOMAIN_ERROR"
    assert error.message == "nope"
    assert error.details == {"account_id": "acc_1"}


def test_money_rejects_a_lowercase_currency() -> None:
    with pytest.raises(InvariantViolationError):
        Money(amount_minor=100, currency="eur")


def test_money_rejects_a_currency_that_is_not_three_letters() -> None:
    with pytest.raises(InvariantViolationError):
        Money(amount_minor=100, currency="EURO")


def test_money_rejects_a_boolean_amount() -> None:
    """bool is a subclass of int; True would otherwise become 1 minor unit."""
    with pytest.raises(InvariantViolationError):
        Money(amount_minor=True, currency="EUR")


def test_money_allows_a_zero_and_a_negative_balance() -> None:
    """Money models an amount, not a rule. Only transactions must be positive."""
    assert Money(amount_minor=0, currency="EUR").amount_minor == 0
    assert Money(amount_minor=-1, currency="EUR").amount_minor == -1


def test_account_rejects_a_blank_owner_name() -> None:
    with pytest.raises(InvariantViolationError):
        Account(
            account_id="acc_1",
            owner_name="   ",
            balance=Money(0, "EUR"),
            created_at=WHEN,
        )


def test_transaction_rejects_a_non_positive_amount() -> None:
    with pytest.raises(InvariantViolationError):
        Transaction(
            transaction_id="txn_1",
            account_id="acc_1",
            type=TransactionType.DEBIT,
            amount=Money(0, "EUR"),
            idempotency_key="k1",
            description=None,
            created_at=WHEN,
        )


def test_transaction_signed_amount_follows_its_type() -> None:
    def build(kind: TransactionType) -> Transaction:
        return Transaction(
            transaction_id="txn_1",
            account_id="acc_1",
            type=kind,
            amount=Money(2500, "EUR"),
            idempotency_key="k1",
            description=None,
            created_at=WHEN,
        )

    assert build(TransactionType.CREDIT).signed_amount_minor == 2500
    assert build(TransactionType.DEBIT).signed_amount_minor == -2500


def test_transaction_minimum_balance_is_the_amount_only_for_a_debit() -> None:
    """This is the value that becomes the DynamoDB ConditionExpression bound."""

    def build(kind: TransactionType) -> Transaction:
        return Transaction(
            transaction_id="txn_1",
            account_id="acc_1",
            type=kind,
            amount=Money(2500, "EUR"),
            idempotency_key="k1",
            description=None,
            created_at=WHEN,
        )

    assert build(TransactionType.DEBIT).minimum_balance_minor == 2500
    assert build(TransactionType.CREDIT).minimum_balance_minor == 0


def test_transaction_id_is_derived_from_the_account_and_the_idempotency_key() -> None:
    first = transaction_id_for("acc_1", "key-1")
    assert first == transaction_id_for("acc_1", "key-1")
    assert first != transaction_id_for("acc_1", "key-2")
    assert first != transaction_id_for("acc_2", "key-1")
    assert first.startswith("txn_")


def test_account_ids_are_unique_and_prefixed() -> None:
    ids = {new_account_id() for _ in range(100)}
    assert len(ids) == 100
    assert all(value.startswith("acc_") for value in ids)


def test_timestamps_serialise_to_a_fixed_width_sortable_string() -> None:
    """Fixed width is what makes the DynamoDB LSI sort chronologically —
    the index sorts strings, so a variable-length format would misorder."""
    early = to_iso(datetime(2026, 1, 2, 3, 4, 5, 6, tzinfo=UTC))
    late = to_iso(datetime(2026, 1, 2, 3, 4, 5, 7, tzinfo=UTC))
    assert len(early) == len(late) == 27
    assert early.endswith("Z")
    assert early < late


def test_timestamps_round_trip() -> None:
    assert from_iso(to_iso(WHEN)) == WHEN


def test_utcnow_is_timezone_aware() -> None:
    assert utcnow().tzinfo is not None
