"""Domain errors.

These carry a stable machine-readable `code` and a `details` mapping, and know
nothing about HTTP. bgd.api.errors is the only place that maps a code to a
status, so the domain can be reused unchanged by a Lambda or a CLI.
"""

from typing import Any


class DomainError(Exception):
    code = "DOMAIN_ERROR"

    def __init__(self, message: str, **details: Any) -> None:
        super().__init__(message)
        self.message = message
        self.details = details


class InvariantViolationError(DomainError):
    """A value that cannot exist in the model was constructed."""

    code = "INVARIANT_VIOLATION"


class AccountNotFoundError(DomainError):
    code = "ACCOUNT_NOT_FOUND"


class AccountAlreadyExistsError(DomainError):
    code = "ACCOUNT_ALREADY_EXISTS"


class InsufficientFundsError(DomainError):
    code = "INSUFFICIENT_FUNDS"


class CurrencyMismatchError(DomainError):
    code = "CURRENCY_MISMATCH"


class DuplicateTransactionError(DomainError):
    """The same idempotency key was already used on this account."""

    code = "DUPLICATE_TRANSACTION"


class RepositoryUnavailableError(DomainError):
    """The store could not be reached, or failed in a way we do not model."""

    code = "REPOSITORY_UNAVAILABLE"
