from fastapi import APIRouter, Query, Response, status

from bgd.api.dependencies import ServiceDep
from bgd.api.schemas import (
    TransactionCreateRequest,
    TransactionListResponse,
    TransactionResponse,
)
from bgd.domain.models import Transaction, TransactionType

router = APIRouter(prefix="/api/transactions", tags=["transactions"])


def to_response(transaction: Transaction) -> TransactionResponse:
    return TransactionResponse(
        transaction_id=transaction.transaction_id,
        account_id=transaction.account_id,
        type=str(transaction.type),
        amount_minor=transaction.amount.amount_minor,
        currency=transaction.amount.currency,
        idempotency_key=transaction.idempotency_key,
        description=transaction.description,
        created_at=transaction.created_at,
    )


@router.post("", response_model=TransactionResponse, status_code=status.HTTP_201_CREATED)
def post_transaction(
    payload: TransactionCreateRequest, service: ServiceDep, response: Response
) -> TransactionResponse:
    transaction, _account, created = service.post_transaction(
        account_id=payload.account_id,
        transaction_type=TransactionType(payload.type),
        amount_minor=payload.amount_minor,
        currency=payload.currency,
        idempotency_key=payload.idempotency_key,
        description=payload.description,
    )
    if not created:
        # An idempotent replay. 200 rather than 201, because nothing was
        # created this time — the client's retry was safe and is being told so.
        response.status_code = status.HTTP_200_OK
    else:
        response.headers["Location"] = f"/api/transactions/{transaction.transaction_id}"
    return to_response(transaction)


@router.get("", response_model=TransactionListResponse)
def list_transactions(
    service: ServiceDep,
    account_id: str = Query(...),
    limit: int = Query(default=50, ge=1, le=100),
    cursor: str | None = Query(default=None),
) -> TransactionListResponse:
    page = service.list_transactions(account_id, limit=limit, cursor=cursor)
    return TransactionListResponse(
        items=[to_response(t) for t in page.items], next_cursor=page.next_cursor
    )
