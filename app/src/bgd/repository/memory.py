"""In-memory LedgerRepository, for tests and local experimentation.

Held to the same contract suite as the DynamoDB implementation, including the
atomicity guarantee: a rejected debit must leave no trace. Here that is free
because the checks happen before any mutation — but it is asserted rather than
assumed, because that is the property the API layer's tests rely on.

Not thread-safe and not intended to be. Tests are single-threaded, and
production uses DynamoDB.
"""

import base64
import json

from bgd.domain.errors import (
    AccountAlreadyExistsError,
    AccountNotFoundError,
    DuplicateTransactionError,
    InsufficientFundsError,
)
from bgd.domain.models import Account, Money, Transaction
from bgd.repository.base import Page


def _encode_cursor(transaction_id: str) -> str:
    return base64.urlsafe_b64encode(json.dumps({"t": transaction_id}).encode()).decode()


def _decode_cursor(cursor: str) -> str:
    return json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())["t"]


class InMemoryLedgerRepository:
    def __init__(self) -> None:
        self._accounts: dict[str, Account] = {}
        # account_id -> transaction_id -> Transaction
        self._transactions: dict[str, dict[str, Transaction]] = {}

    # --- accounts ---

    def create_account(self, account: Account) -> None:
        if account.account_id in self._accounts:
            raise AccountAlreadyExistsError(
                "an account with that id already exists", account_id=account.account_id
            )
        self._accounts[account.account_id] = account

    def get_account(self, account_id: str) -> Account | None:
        return self._accounts.get(account_id)

    def list_accounts(self, limit: int = 50) -> list[Account]:
        return list(self._accounts.values())[:limit]

    # --- transactions ---

    def post_transaction(self, transaction: Transaction) -> Account:
        stored = self._transactions.setdefault(transaction.account_id, {})
        if transaction.transaction_id in stored:
            raise DuplicateTransactionError(
                "that idempotency key was already used on this account",
                account_id=transaction.account_id,
                idempotency_key=transaction.idempotency_key,
            )

        account = self._accounts.get(transaction.account_id)
        if account is None:
            raise AccountNotFoundError("no such account", account_id=transaction.account_id)

        if account.balance.amount_minor < transaction.minimum_balance_minor:
            raise InsufficientFundsError(
                "the account balance is too low for this debit",
                account_id=transaction.account_id,
                balance_minor=account.balance.amount_minor,
                requested_minor=transaction.amount.amount_minor,
            )

        # Both checks passed — only now does anything change.
        updated = Account(
            account_id=account.account_id,
            owner_name=account.owner_name,
            balance=Money(
                account.balance.amount_minor + transaction.signed_amount_minor,
                account.balance.currency,
            ),
            created_at=account.created_at,
        )
        self._accounts[account.account_id] = updated
        stored[transaction.transaction_id] = transaction
        return updated

    def get_transaction(self, account_id: str, transaction_id: str) -> Transaction | None:
        return self._transactions.get(account_id, {}).get(transaction_id)

    def list_transactions(
        self, account_id: str, limit: int = 50, cursor: str | None = None
    ) -> Page[Transaction]:
        # Newest first, matching the DynamoDB LSI queried with
        # ScanIndexForward=False. transaction_id breaks ties so the order is
        # total, and therefore so is the cursor.
        ordered = sorted(
            self._transactions.get(account_id, {}).values(),
            key=lambda t: (t.created_at, t.transaction_id),
            reverse=True,
        )

        start = 0
        if cursor is not None:
            after = _decode_cursor(cursor)
            start = next(
                (i + 1 for i, t in enumerate(ordered) if t.transaction_id == after),
                len(ordered),
            )

        window = ordered[start : start + limit]
        has_more = start + limit < len(ordered)
        return Page(
            items=window,
            next_cursor=_encode_cursor(window[-1].transaction_id) if has_more and window else None,
        )

    def ping(self) -> None:
        return None
