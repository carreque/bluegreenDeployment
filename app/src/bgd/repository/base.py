"""The repository contract.

One Protocol covering both entities, not one per entity. Posting a transaction
writes the transaction record and the account balance in a single atomic
operation; splitting the interface would advertise an independence that does
not exist, and neither half could implement post_transaction alone.
"""

from dataclasses import dataclass
from typing import Protocol

from bgd.domain.models import Account, Transaction


@dataclass(frozen=True, slots=True)
class Page[T]:
    items: list[T]
    next_cursor: str | None = None


class LedgerRepository(Protocol):
    def create_account(self, account: Account) -> None:
        """Raise AccountAlreadyExistsError if the id is taken."""
        ...

    def get_account(self, account_id: str) -> Account | None: ...

    def list_accounts(self, limit: int = 50) -> list[Account]: ...

    def post_transaction(self, transaction: Transaction) -> Account:
        """Apply the transaction atomically and return the account after it.

        Raises DuplicateTransactionError if the id was already used,
        AccountNotFoundError if the account is gone, and InsufficientFundsError if the
        balance would go negative. On any of them nothing is written.
        """
        ...

    def get_transaction(self, account_id: str, transaction_id: str) -> Transaction | None: ...

    def list_transactions(
        self, account_id: str, limit: int = 50, cursor: str | None = None
    ) -> Page[Transaction]:
        """Newest first. `cursor` is opaque and comes from a previous Page."""
        ...

    def ping(self) -> None:
        """Raise RepositoryUnavailableError if the store cannot be reached."""
        ...
