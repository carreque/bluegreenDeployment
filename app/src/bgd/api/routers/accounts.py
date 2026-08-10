from fastapi import APIRouter, Query, Response, status

from bgd.api.dependencies import ServiceDep
from bgd.api.schemas import AccountCreateRequest, AccountListResponse, AccountResponse
from bgd.domain.models import Account

router = APIRouter(prefix="/api/accounts", tags=["accounts"])


def to_response(account: Account) -> AccountResponse:
    return AccountResponse(
        account_id=account.account_id,
        owner_name=account.owner_name,
        currency=account.balance.currency,
        balance_minor=account.balance.amount_minor,
        created_at=account.created_at,
    )


@router.post("", response_model=AccountResponse, status_code=status.HTTP_201_CREATED)
def create_account(
    payload: AccountCreateRequest, service: ServiceDep, response: Response
) -> AccountResponse:
    account = service.open_account(
        owner_name=payload.owner_name,
        currency=payload.currency,
        initial_balance_minor=payload.initial_balance_minor,
    )
    response.headers["Location"] = f"/api/accounts/{account.account_id}"
    return to_response(account)


@router.get("", response_model=AccountListResponse)
def list_accounts(
    service: ServiceDep, limit: int = Query(default=50, ge=1, le=100)
) -> AccountListResponse:
    return AccountListResponse(items=[to_response(a) for a in service.list_accounts(limit=limit)])


@router.get("/{account_id}", response_model=AccountResponse)
def get_account(account_id: str, service: ServiceDep) -> AccountResponse:
    return to_response(service.get_account(account_id))
