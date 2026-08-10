"""Pins the DynamoDB semantics this repository decodes.

Verified against DynamoDB Local, digest ff89bd48…, on 2026-08-05. If an image
bump changes the shape, this fails with an obvious name rather than surfacing
as an unexplained 500 out of post_transaction.

Two behaviours are pinned that the repository depends on and that are not
obvious from the API reference:

  1. CancellationReasons is positional — index 0 is the Put, index 1 is the
     balance Update.
  2. An absent account and an insufficient balance produce the *same* reason
     code, because one ConditionExpression yields one code and ours combines
     both checks. ReturnValuesOnConditionCheckFailure is what separates them:
     the old item comes back only when there was one.
"""

import pytest
from botocore.exceptions import ClientError


def reasons(error: ClientError) -> list[str]:
    return [reason.get("Code") for reason in error.response.get("CancellationReasons", [])]


def post(client, accounts, transactions, transaction_id, delta, minimum, account_id="acc_1"):
    return client.transact_write_items(
        TransactItems=[
            {
                "Put": {
                    "TableName": transactions,
                    "Item": {
                        "account_id": {"S": account_id},
                        "transaction_id": {"S": transaction_id},
                        "created_at": {"S": "2026-08-05T10:00:00.000001Z"},
                    },
                    "ConditionExpression": "attribute_not_exists(transaction_id)",
                }
            },
            {
                "Update": {
                    "TableName": accounts,
                    "Key": {"account_id": {"S": account_id}},
                    "UpdateExpression": "SET balance_minor = balance_minor + :delta",
                    "ConditionExpression": (
                        "attribute_exists(account_id) AND balance_minor >= :minimum"
                    ),
                    "ExpressionAttributeValues": {
                        ":delta": {"N": str(delta)},
                        ":minimum": {"N": str(minimum)},
                    },
                    "ReturnValuesOnConditionCheckFailure": "ALL_OLD",
                }
            },
        ]
    )


@pytest.fixture
def ledger(dynamodb_tables):
    client, accounts, transactions = dynamodb_tables
    client.put_item(
        TableName=accounts,
        Item={"account_id": {"S": "acc_1"}, "balance_minor": {"N": "10000"}},
    )
    return client, accounts, transactions


def test_a_duplicate_put_fails_at_index_zero(ledger) -> None:
    client, accounts, transactions = ledger
    post(client, accounts, transactions, "txn_a", -2500, 2500)
    with pytest.raises(ClientError) as caught:
        post(client, accounts, transactions, "txn_a", -2500, 2500)

    assert caught.value.response["Error"]["Code"] == "TransactionCanceledException"
    assert reasons(caught.value) == ["ConditionalCheckFailed", "None"]


def test_an_insufficient_balance_fails_at_index_one_and_returns_the_account(ledger) -> None:
    client, accounts, transactions = ledger
    with pytest.raises(ClientError) as caught:
        post(client, accounts, transactions, "txn_b", -999_999, 999_999)

    assert reasons(caught.value) == ["None", "ConditionalCheckFailed"]
    failed = caught.value.response["CancellationReasons"][1]
    assert failed["Item"]["balance_minor"]["N"] == "10000"


def test_a_missing_account_fails_at_index_one_with_no_item(ledger) -> None:
    """Identical reason code to an insufficient balance. The presence of `Item`
    is the only discriminator, which is why the repository reads it rather than
    issuing a second GetItem."""
    client, accounts, transactions = ledger
    with pytest.raises(ClientError) as caught:
        post(client, accounts, transactions, "txn_c", -1, 1, account_id="acc_gone")

    assert reasons(caught.value) == ["None", "ConditionalCheckFailed"]
    assert "Item" not in caught.value.response["CancellationReasons"][1]


def test_a_failed_transaction_writes_nothing(ledger) -> None:
    client, accounts, transactions = ledger
    with pytest.raises(ClientError):
        post(client, accounts, transactions, "txn_b", -999_999, 999_999)

    stored = client.get_item(
        TableName=transactions,
        Key={"account_id": {"S": "acc_1"}, "transaction_id": {"S": "txn_b"}},
    )
    assert "Item" not in stored
    account = client.get_item(TableName=accounts, Key={"account_id": {"S": "acc_1"}})
    assert account["Item"]["balance_minor"]["N"] == "10000"


def test_the_index_returns_newest_first_and_paginates(dynamodb_tables) -> None:
    client, _accounts, transactions = dynamodb_tables
    for index in range(5):
        client.put_item(
            TableName=transactions,
            Item={
                "account_id": {"S": "acc_2"},
                "transaction_id": {"S": f"txn_{index}"},
                "created_at": {"S": f"2026-08-05T10:00:0{index}.000000Z"},
            },
        )

    query = {
        "TableName": transactions,
        "IndexName": "created_at-index",
        "KeyConditionExpression": "account_id = :a",
        "ExpressionAttributeValues": {":a": {"S": "acc_2"}},
        "ScanIndexForward": False,
        "Limit": 2,
    }
    first = client.query(**query)
    assert [item["transaction_id"]["S"] for item in first["Items"]] == ["txn_4", "txn_3"]

    # The cursor must carry all three keys — the index's two plus the table's
    # sort key — which is why it is encoded whole rather than field by field.
    assert sorted(first["LastEvaluatedKey"]) == ["account_id", "created_at", "transaction_id"]

    second = client.query(**query, ExclusiveStartKey=first["LastEvaluatedKey"])
    assert [item["transaction_id"]["S"] for item in second["Items"]] == ["txn_2", "txn_1"]
