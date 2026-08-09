"""The domain model.

Frozen dataclasses rather than pydantic models, deliberately. Pydantic lives at
the API boundary in bgd.api.schemas, where parsing untrusted input is the job.
Down here the objects are already trusted and the invariants are the point, so
the two are kept as separate types rather than one model doing both.

Money is always integer minor units. No float, no Decimal, anywhere in this
package.
"""

import re
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum

from bgd.domain.errors import InvariantViolationError

_CURRENCY = re.compile(r"^[A-Z]{3}$")

# Fixed namespace so a transaction id is reproducible across processes and
# restarts. Changing it would orphan every existing idempotency key.
_TXN_NAMESPACE = uuid.UUID("6f1d5b0e-0f0a-4a9b-8f2a-6d5f9c3b1a77")

_ISO_FORMAT = "%Y-%m-%dT%H:%M:%S.%f"


class TransactionType(StrEnum):
    CREDIT = "CREDIT"
    DEBIT = "DEBIT"


@dataclass(frozen=True, slots=True)
class Money:
    amount_minor: int
    currency: str

    def __post_init__(self) -> None:
        # bool is a subclass of int, so `isinstance(True, int)` is True and
        # True would silently become one minor unit.
        if isinstance(self.amount_minor, bool) or not isinstance(self.amount_minor, int):
            raise InvariantViolationError(
                "amount_minor must be an integer number of minor units",
                amount_minor=repr(self.amount_minor),
            )
        if not _CURRENCY.match(self.currency):
            raise InvariantViolationError(
                "currency must be a three-letter uppercase ISO 4217 code",
                currency=self.currency,
            )


@dataclass(frozen=True, slots=True)
class Account:
    account_id: str
    owner_name: str
    balance: Money
    created_at: datetime

    def __post_init__(self) -> None:
        if not self.account_id:
            raise InvariantViolationError("account_id must not be empty")
        if not self.owner_name.strip():
            raise InvariantViolationError("owner_name must not be blank")

    @property
    def currency(self) -> str:
        return self.balance.currency


@dataclass(frozen=True, slots=True)
class Transaction:
    transaction_id: str
    account_id: str
    type: TransactionType
    amount: Money
    idempotency_key: str
    description: str | None
    created_at: datetime

    def __post_init__(self) -> None:
        if self.amount.amount_minor <= 0:
            raise InvariantViolationError(
                "a transaction amount must be positive; direction is carried by `type`",
                amount_minor=self.amount.amount_minor,
            )
        if not self.idempotency_key.strip():
            raise InvariantViolationError("idempotency_key must not be blank")

    @property
    def signed_amount_minor(self) -> int:
        """The delta this transaction applies to the account balance."""
        if self.type is TransactionType.DEBIT:
            return -self.amount.amount_minor
        return self.amount.amount_minor

    @property
    def minimum_balance_minor(self) -> int:
        """The balance the account must already hold for this to be allowed.

        Becomes the bound in the repository's ConditionExpression, so the
        overdraft rule is stated once, here, rather than in each backend.
        """
        if self.type is TransactionType.DEBIT:
            return self.amount.amount_minor
        return 0


def new_account_id() -> str:
    return f"acc_{uuid.uuid4().hex}"


def transaction_id_for(account_id: str, idempotency_key: str) -> str:
    """Derive the transaction id from the account and the idempotency key.

    Because the id is deterministic, idempotency needs no separate guard item
    and no secondary index: the transactions table's sort key *is* the
    idempotency check, enforced by attribute_not_exists on the write.
    """
    return f"txn_{uuid.uuid5(_TXN_NAMESPACE, f'{account_id}:{idempotency_key}').hex}"


def utcnow() -> datetime:
    return datetime.now(UTC)


def to_iso(value: datetime) -> str:
    """Fixed-width UTC ISO-8601, always 27 characters ending in Z.

    Fixed width is a correctness requirement, not cosmetics: this string is the
    sort key of the transactions LSI, DynamoDB sorts it as a string, and a
    variable-length rendering would order 10:00:00.5 before 10:00:00.05.
    """
    return value.astimezone(UTC).strftime(_ISO_FORMAT)[:26] + "Z"


def from_iso(value: str) -> datetime:
    return datetime.strptime(value, _ISO_FORMAT + "Z").replace(tzinfo=UTC)
