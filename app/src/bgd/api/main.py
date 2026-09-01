"""The application factory.

create_app takes its repository as an argument so tests inject the in-memory
fake and never construct a boto3 client. Production passes nothing and gets the
DynamoDB implementation built from settings.
"""

from fastapi import FastAPI

from bgd.api.errors import install_exception_handlers
from bgd.api.middleware import RequestContextMiddleware, SecurityHeadersMiddleware
from bgd.api.routers import accounts, health, transactions
from bgd.config import Settings, get_settings
from bgd.logging import configure_logging
from bgd.repository.base import LedgerRepository


def create_app(
    repository: LedgerRepository | None = None,
    settings: Settings | None = None,
) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.log_level)

    if repository is None:
        from bgd.repository.dynamodb import DynamoDbLedgerRepository, build_client

        repository = DynamoDbLedgerRepository(
            build_client(settings),
            settings.accounts_table,
            settings.transactions_table,
        )

    app = FastAPI(
        title="Blue/Green Deployment Platform API",
        version=settings.app_version,
        # The default handler would return a plain JSON body; ours returns
        # application/problem+json for every error including unhandled ones.
        docs_url="/docs",
    )
    app.state.settings = settings
    app.state.repository = repository

    app.add_middleware(RequestContextMiddleware)
    # After RequestContextMiddleware, which in Starlette means *outermost*:
    # add_middleware prepends, and the first entry wraps the rest. So this one
    # sees the response last and appends its headers on top of the request-id
    # header the inner middleware has already added. Both land; the ordering
    # only matters if one ever wants to read what the other wrote.
    app.add_middleware(SecurityHeadersMiddleware)
    install_exception_handlers(app)

    app.include_router(health.router)
    app.include_router(accounts.router)
    app.include_router(transactions.router)
    return app
