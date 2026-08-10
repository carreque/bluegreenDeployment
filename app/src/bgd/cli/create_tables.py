"""Create the local DynamoDB tables.

Idempotent — an existing table is left alone — and it reads its definitions
from bgd.repository.schema, the same module the tests use, so local
development and CI cannot drift apart.

Refuses to run without BGD_DYNAMODB_ENDPOINT_URL. Without that guard a stray
AWS_PROFILE would point this at a real account and silently create tables there.
"""

import time

from botocore.exceptions import EndpointConnectionError

from bgd.config import get_settings
from bgd.repository.dynamodb import build_client
from bgd.repository.schema import table_definitions


def _wait_for_endpoint(client, attempts: int = 30, delay: float = 1.0) -> None:
    for attempt in range(1, attempts + 1):
        try:
            client.list_tables()
            return
        except EndpointConnectionError:
            if attempt == attempts:
                raise
            print(f"waiting for DynamoDB Local ({attempt}/{attempts})")
            time.sleep(delay)


def main() -> None:
    settings = get_settings()
    if not settings.dynamodb_endpoint_url:
        raise SystemExit(
            "BGD_DYNAMODB_ENDPOINT_URL is not set. Refusing to create tables "
            "against real AWS — copy app/.env.example to app/.env first."
        )

    client = build_client(settings)
    _wait_for_endpoint(client)

    for definition in table_definitions(settings.accounts_table, settings.transactions_table):
        name = definition["TableName"]
        try:
            client.create_table(**definition)
            print(f"created  {name}")
        except client.exceptions.ResourceInUseException:
            print(f"exists   {name}")

    for name in (settings.accounts_table, settings.transactions_table):
        client.get_waiter("table_exists").wait(TableName=name)

    print("tables ready")


if __name__ == "__main__":
    main()
