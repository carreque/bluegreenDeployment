"""The DynamoDB LedgerRepository.

Uses the low-level client rather than the resource interface so the wire types
and the error payloads are explicit — CancellationReasons decoding below
depends on both.
"""

import base64
import json
import logging

from boto3.dynamodb.types import TypeDeserializer, TypeSerializer
from botocore.exceptions import BotoCoreError, ClientError

from bgd.domain.errors import (
    AccountAlreadyExistsError,
    AccountNotFoundError,
    DuplicateTransactionError,
    InsufficientFundsError,
    RepositoryUnavailableError,
)
from bgd.domain.models import (
    Account,
    Money,
    Transaction,
    TransactionType,
    from_iso,
    to_iso,
)
from bgd.repository.base import Page
from bgd.repository.schema import TRANSACTIONS_BY_CREATED_AT_INDEX

logger = logging.getLogger(__name__)

_serializer = TypeSerializer()
_deserializer = TypeDeserializer()


def _to_item(values: dict) -> dict:
    return {key: _serializer.serialize(value) for key, value in values.items()}


def _from_item(item: dict) -> dict:
    return {key: _deserializer.deserialize(value) for key, value in item.items()}


def _encode_cursor(key: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(key).encode()).decode()


def _decode_cursor(cursor: str) -> dict:
    return json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())


def build_client(settings):
    """Build a DynamoDB client for these settings.

    When an endpoint URL is set we are talking to DynamoDB Local, which accepts
    any credentials but rejects none. Supplying explicit dummy credentials
    keeps `docker compose up` working without an AWS profile or an SSO session.
    """
    import boto3

    kwargs: dict = {"region_name": settings.aws_region}
    if settings.dynamodb_endpoint_url:
        kwargs["endpoint_url"] = settings.dynamodb_endpoint_url
        kwargs["aws_access_key_id"] = "local"
        # S105 is right in general and wrong here: this literal only ever
        # reaches DynamoDB Local, which accepts any credentials and rejects
        # none. The branch is guarded by dynamodb_endpoint_url being set, so it
        # cannot run against real AWS.
        kwargs["aws_secret_access_key"] = "local"  # noqa: S105
    return boto3.client("dynamodb", **kwargs)


def _account_from_item(item: dict) -> Account:
    values = _from_item(item)
    return Account(
        account_id=values["account_id"],
        owner_name=values["owner_name"],
        balance=Money(int(values["balance_minor"]), values["currency"]),
        created_at=from_iso(values["created_at"]),
    )


def _transaction_from_item(item: dict) -> Transaction:
    values = _from_item(item)
    return Transaction(
        transaction_id=values["transaction_id"],
        account_id=values["account_id"],
        type=TransactionType(values["type"]),
        amount=Money(int(values["amount_minor"]), values["currency"]),
        idempotency_key=values["idempotency_key"],
        description=values.get("description"),
        created_at=from_iso(values["created_at"]),
    )


class DynamoDbLedgerRepository:
    def __init__(self, client, accounts_table: str, transactions_table: str) -> None:
        self._client = client
        self._accounts = accounts_table
        self._transactions = transactions_table

    # --- accounts ---

    def create_account(self, account: Account) -> None:
        try:
            self._client.put_item(
                TableName=self._accounts,
                Item=_to_item(
                    {
                        "account_id": account.account_id,
                        "owner_name": account.owner_name,
                        "currency": account.balance.currency,
                        "balance_minor": account.balance.amount_minor,
                        "created_at": to_iso(account.created_at),
                    }
                ),
                ConditionExpression="attribute_not_exists(account_id)",
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise AccountAlreadyExistsError(
                    "an account with that id already exists", account_id=account.account_id
                ) from error
            raise self._unavailable(error) from error

    def get_account(self, account_id: str) -> Account | None:
        try:
            response = self._client.get_item(
                TableName=self._accounts, Key=_to_item({"account_id": account_id})
            )
        except (ClientError, BotoCoreError) as error:
            raise self._unavailable(error) from error
        item = response.get("Item")
        return _account_from_item(item) if item else None

    def list_accounts(self, limit: int = 50) -> list[Account]:
        # A Scan, deliberately. The accounts table is small by design and there
        # is no access pattern that would justify an index here.
        try:
            response = self._client.scan(TableName=self._accounts, Limit=limit)
        except (ClientError, BotoCoreError) as error:
            raise self._unavailable(error) from error
        return [_account_from_item(item) for item in response.get("Items", [])]

    # --- transactions ---

    def post_transaction(self, transaction: Transaction) -> Account:
        item = {
            "account_id": transaction.account_id,
            "transaction_id": transaction.transaction_id,
            "type": str(transaction.type),
            "amount_minor": transaction.amount.amount_minor,
            "currency": transaction.amount.currency,
            "idempotency_key": transaction.idempotency_key,
            "created_at": to_iso(transaction.created_at),
        }
        if transaction.description is not None:
            item["description"] = transaction.description

        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Put": {
                            "TableName": self._transactions,
                            "Item": _to_item(item),
                            "ConditionExpression": "attribute_not_exists(transaction_id)",
                        }
                    },
                    {
                        "Update": {
                            "TableName": self._accounts,
                            "Key": _to_item({"account_id": transaction.account_id}),
                            "UpdateExpression": "SET balance_minor = balance_minor + :delta",
                            "ConditionExpression": (
                                "attribute_exists(account_id) AND balance_minor >= :minimum"
                            ),
                            "ExpressionAttributeValues": _to_item(
                                {
                                    ":delta": transaction.signed_amount_minor,
                                    ":minimum": transaction.minimum_balance_minor,
                                }
                            ),
                            # Returns the account as the condition saw it when
                            # the condition fails. That payload is what tells a
                            # missing account apart from an insufficient
                            # balance without a second read (§F3).
                            "ReturnValuesOnConditionCheckFailure": "ALL_OLD",
                        }
                    },
                ]
            )
        except ClientError as error:
            raise self._translate_cancellation(error, transaction) from error
        except BotoCoreError as error:
            raise self._unavailable(error) from error

        account = self.get_account(transaction.account_id)
        if account is None:  # pragma: no cover - the write just succeeded
            raise AccountNotFoundError("account vanished after a successful write")
        return account

    def _translate_cancellation(self, error: ClientError, transaction: Transaction) -> Exception:
        """Decode a TransactionCanceledException into a domain error.

        CancellationReasons is positional: index 0 is the Put, index 1 is the
        balance Update. Index 1 is ambiguous on its own — one
        ConditionExpression yields one reason code, and ours checks both that
        the account exists and that the balance is sufficient.

        ReturnValuesOnConditionCheckFailure resolves it without a second read.
        The old item comes back only if there was one, so `Item` present means
        the account exists and the balance was too low, and `Item` absent means
        the account is gone. Verified against DynamoDB Local; see §F3.
        """
        if error.response.get("Error", {}).get("Code") != "TransactionCanceledException":
            return self._unavailable(error)

        reasons = error.response.get("CancellationReasons", [])
        codes = [reason.get("Code") for reason in reasons]

        # Index 0 is tested first so that a replayed key against a deleted
        # account reports the duplicate. The in-memory fake also checks for a
        # duplicate before it looks at the account, so the two agree.
        if len(codes) > 0 and codes[0] == "ConditionalCheckFailed":
            return DuplicateTransactionError(
                "that idempotency key was already used on this account",
                account_id=transaction.account_id,
                idempotency_key=transaction.idempotency_key,
            )

        if len(codes) > 1 and codes[1] == "ConditionalCheckFailed":
            item = reasons[1].get("Item")
            if item is None:
                return AccountNotFoundError("no such account", account_id=transaction.account_id)
            # The balance the condition actually rejected — not whatever a
            # follow-up read would have found after a concurrent write.
            return InsufficientFundsError(
                "the account balance is too low for this debit",
                account_id=transaction.account_id,
                balance_minor=int(_from_item(item)["balance_minor"]),
                requested_minor=transaction.amount.amount_minor,
            )

        return self._unavailable(error)

    def get_transaction(self, account_id: str, transaction_id: str) -> Transaction | None:
        try:
            response = self._client.get_item(
                TableName=self._transactions,
                Key=_to_item({"account_id": account_id, "transaction_id": transaction_id}),
            )
        except (ClientError, BotoCoreError) as error:
            raise self._unavailable(error) from error
        item = response.get("Item")
        return _transaction_from_item(item) if item else None

    def list_transactions(
        self, account_id: str, limit: int = 50, cursor: str | None = None
    ) -> Page[Transaction]:
        query = {
            "TableName": self._transactions,
            "IndexName": TRANSACTIONS_BY_CREATED_AT_INDEX,
            "KeyConditionExpression": "account_id = :account_id",
            "ExpressionAttributeValues": _to_item({":account_id": account_id}),
            "ScanIndexForward": False,  # newest first
            "Limit": limit,
        }
        if cursor is not None:
            query["ExclusiveStartKey"] = _decode_cursor(cursor)

        try:
            response = self._client.query(**query)
        except (ClientError, BotoCoreError) as error:
            raise self._unavailable(error) from error

        last_key = response.get("LastEvaluatedKey")
        return Page(
            items=[_transaction_from_item(item) for item in response.get("Items", [])],
            next_cursor=_encode_cursor(last_key) if last_key else None,
        )

    # --- health ---

    def ping(self) -> None:
        """A data-plane read against a key that does not exist.

        Cheaper and far less throttle-prone than DescribeTable, which is a
        control-plane call — and /ready is polled.
        """
        try:
            self._client.get_item(
                TableName=self._accounts, Key=_to_item({"account_id": "__ping__"})
            )
        except (ClientError, BotoCoreError) as error:
            raise self._unavailable(error) from error

    @staticmethod
    def _unavailable(error: Exception) -> RepositoryUnavailableError:
        logger.warning("dynamodb call failed", extra={"error": str(error)})
        return RepositoryUnavailableError("the data store is unavailable")
