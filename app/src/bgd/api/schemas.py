"""The HTTP boundary types.

Pydantic here, frozen dataclasses in the domain. Keeping them separate means
a rename in the wire format cannot silently change a domain invariant, and the
API can present `amount_minor` as a plain int while the domain insists on Money.
"""

from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

Currency = Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]
OwnerName = Annotated[str, StringConstraints(min_length=1, max_length=120, strip_whitespace=True)]
IdempotencyKey = Annotated[str, StringConstraints(min_length=1, max_length=128)]


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"


class ReadyResponse(BaseModel):
    status: Literal["ready", "not_ready"]
    checks: dict[str, str]


class VersionResponse(BaseModel):
    version: str
    git_sha: str
    image_digest: str
    built_at: str
    # A token, never a hex value: the CSS owns what blue looks like (D6).
    # `str` rather than the settings' Literal — Settings is the validation
    # boundary, and re-validating here would only create a second place to
    # edit when a colour is added.
    release_color: str


class AccountCreateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    owner_name: OwnerName
    currency: Currency
    initial_balance_minor: int = Field(default=0, ge=0)


class AccountResponse(BaseModel):
    account_id: str
    owner_name: str
    currency: str
    balance_minor: int
    created_at: datetime


class AccountListResponse(BaseModel):
    items: list[AccountResponse]


class TransactionCreateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    account_id: str
    type: Literal["CREDIT", "DEBIT"]
    amount_minor: int = Field(gt=0)
    currency: Currency
    idempotency_key: IdempotencyKey
    description: str | None = Field(default=None, max_length=280)


class TransactionResponse(BaseModel):
    transaction_id: str
    account_id: str
    type: str
    amount_minor: int
    currency: str
    idempotency_key: str
    description: str | None
    created_at: datetime


class TransactionListResponse(BaseModel):
    items: list[TransactionResponse]
    next_cursor: str | None = None
