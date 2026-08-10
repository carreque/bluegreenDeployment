"""DynamoDB table definitions — the single source of truth.

Read by the local bootstrap (bgd.cli.create_tables) and by the tests, so local
development and CI cannot drift apart. Phases 5 and 6 declare the same shape in
Terraform; this module is the reference they are written against, and the LSI
in particular is easy to omit there and impossible to add later without
recreating the table.

Key design:

  accounts       PK account_id
  transactions   PK account_id, SK transaction_id
                 LSI created_at-index: PK account_id, SK created_at

transaction_id is derived from the idempotency key (see
domain.models.transaction_id_for), so the table's sort key *is* the idempotency
guard — attribute_not_exists on the write is the whole mechanism. No separate
guard item and no GSI.

The LSI exists because listing needs newest-first order with real pagination.
An LSI must be created with the table; it cannot be added afterwards.
"""

TRANSACTIONS_BY_CREATED_AT_INDEX = "created_at-index"


def table_definitions(accounts_table: str, transactions_table: str) -> list[dict]:
    return [
        {
            "TableName": accounts_table,
            "KeySchema": [{"AttributeName": "account_id", "KeyType": "HASH"}],
            "AttributeDefinitions": [{"AttributeName": "account_id", "AttributeType": "S"}],
            "BillingMode": "PAY_PER_REQUEST",
        },
        {
            "TableName": transactions_table,
            "KeySchema": [
                {"AttributeName": "account_id", "KeyType": "HASH"},
                {"AttributeName": "transaction_id", "KeyType": "RANGE"},
            ],
            "AttributeDefinitions": [
                {"AttributeName": "account_id", "AttributeType": "S"},
                {"AttributeName": "transaction_id", "AttributeType": "S"},
                {"AttributeName": "created_at", "AttributeType": "S"},
            ],
            "LocalSecondaryIndexes": [
                {
                    "IndexName": TRANSACTIONS_BY_CREATED_AT_INDEX,
                    "KeySchema": [
                        {"AttributeName": "account_id", "KeyType": "HASH"},
                        {"AttributeName": "created_at", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                }
            ],
            "BillingMode": "PAY_PER_REQUEST",
        },
    ]
