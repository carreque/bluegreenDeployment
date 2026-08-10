"""Use cases.

The clock and the id factory are injected so tests get deterministic output
without patching module globals.
"""

from collections.abc import Callable
from datetime import datetime

from bgd.domain.errors import (
    AccountNotFoundError,
    CurrencyMismatchError,
    DuplicateTransactionError,
    InvariantViolationError,
)
from bgd.domain.models import (
    Account,
    Money,
    Transaction,
    TransactionType,
    new_account_id,
    transaction_id_for,
    utcnow,
)
from bgd.repository.base import LedgerRepository, Page


class LedgerService:
    def __init__(
        self,
        repository: LedgerRepository,
        *,
        clock: Callable[[], datetime] = utcnow,
        id_factory: Callable[[], str] = new_account_id,
    ) -> None:
        self._repository = repository
        self._clock = clock
        self._id_factory = id_factory

    # --- accounts ---

    def open_account(
        self, owner_name: str, currency: str, initial_balance_minor: int = 0
    ) -> Account:
        if initial_balance_minor < 0:
            raise InvariantViolationError(
                "an account cannot be opened overdrawn",
                initial_balance_minor=initial_balance_minor,
            )

        account = Account(
            account_id=self._id_factory(),
            owner_name=owner_name,
            balance=Money(initial_balance_minor, currency),
            created_at=self._clock(),
        )
        self._repository.create_account(account)
        return account

    def get_account(self, account_id: str) -> Account:
        account = self._repository.get_account(account_id)
        if account is None:
            raise AccountNotFoundError("no such account", account_id=account_id)
        return account

    def list_accounts(self, limit: int = 50) -> list[Account]:
        return self._repository.list_accounts(limit=limit)

    # --- transactions ---

    def post_transaction(
        self,
        *,
        account_id: str,
        transaction_type: TransactionType,
        amount_minor: int,
        currency: str,
        idempotency_key: str,
        description: str | None = None,
    ) -> tuple[Transaction, Account, bool]:
        """Apply a transaction. Returns (transaction, account, created).

        `created` is False when the idempotency key was already used with the
        same account — the stored transaction is returned instead of an error,
        which is what makes a client retry safe.
        """
        # Read first, so a currency mismatch and a missing account are reported
        # precisely rather than as a generic condition failure. The account
        # currency is immutable, so there is no meaningful race here.
        account = self.get_account(account_id)
        if account.currency != currency:
            raise CurrencyMismatchError(
                "the transaction currency does not match the account",
                account_currency=account.currency,
                transaction_currency=currency,
            )

        transaction = Transaction(
            transaction_id=transaction_id_for(account_id, idempotency_key),
            account_id=account_id,
            type=transaction_type,
            amount=Money(amount_minor, currency),
            idempotency_key=idempotency_key,
            description=description,
            created_at=self._clock(),
        )

        try:
            updated = self._repository.post_transaction(transaction)
        except DuplicateTransactionError:
            existing = self._repository.get_transaction(account_id, transaction.transaction_id)
            if existing is None:
                # Written and removed between the two calls. Nothing sensible
                # to return, so let the original error stand.
                raise
            return existing, self.get_account(account_id), False

        return transaction, updated, True

    def list_transactions(
        self, account_id: str, limit: int = 50, cursor: str | None = None
    ) -> Page[Transaction]:
        self.get_account(account_id)  # 404 rather than an empty list
        return self._repository.list_transactions(account_id, limit=limit, cursor=cursor)
