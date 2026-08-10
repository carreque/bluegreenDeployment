"""One repository fixture, parametrised over every implementation.

Both backends run the identical suite in test_ledger_repository.py. That is
what keeps the fake honest: a behaviour the fake gets wrong is a red test, not
a production surprise.

The DynamoDB backend runs against DynamoDB Local — AWS's own implementation —
rather than a Python reimplementation of it. See §0 of the Phase 1 plan.
"""

import os
import uuid

import boto3
import pytest
from botocore.exceptions import EndpointConnectionError

from bgd.repository.dynamodb import DynamoDbLedgerRepository
from bgd.repository.memory import InMemoryLedgerRepository
from bgd.repository.schema import table_definitions

DEFAULT_ENDPOINT = "http://localhost:8000"


def _client(endpoint: str):
    # Explicit dummy credentials: DynamoDB Local accepts any credentials but
    # rejects none, and passing them here keeps the suite independent of
    # whatever profile the developer happens to have exported.
    return boto3.client(
        "dynamodb",
        region_name="us-east-1",
        endpoint_url=endpoint,
        aws_access_key_id="local",
        aws_secret_access_key="local",
    )


@pytest.fixture(scope="session")
def dynamodb_endpoint() -> str:
    endpoint = os.environ.get("BGD_TEST_DYNAMODB_ENDPOINT", DEFAULT_ENDPOINT)
    try:
        _client(endpoint).list_tables()
    except EndpointConnectionError:
        # fail, not skip. A silently skipped backend test would defeat the
        # entire reason for choosing the higher-fidelity tool — the suite
        # would go green having tested one implementation, not two.
        pytest.fail(
            f"DynamoDB Local is not reachable at {endpoint}. Run `make local-up`.",
            pytrace=False,
        )
    return endpoint


@pytest.fixture
def dynamodb_client(dynamodb_endpoint: str):
    """A raw client, for tests asserting on table shape rather than behaviour.

    A fixture rather than an import of `_client` from this module: importing
    across test modules needs the rootdir on sys.path, which `python -m pytest`
    adds implicitly and the `pytest` console script does not. CI runs the
    console script, so such an import passes locally and fails there.
    """
    return _client(dynamodb_endpoint)


@pytest.fixture
def dynamodb_tables(dynamodb_endpoint: str):
    """A private pair of tables per test.

    Unique names rather than one shared pair that gets emptied between tests:
    no test can observe another's writes, there is no teardown ordering to get
    wrong, and the suite stays correct if it is ever parallelised with xdist.
    """
    client = _client(dynamodb_endpoint)
    suffix = uuid.uuid4().hex[:12]
    accounts = f"bgd-us-east-1-test-{suffix}-accounts"
    transactions = f"bgd-us-east-1-test-{suffix}-transactions"

    for definition in table_definitions(accounts, transactions):
        client.create_table(**definition)

    yield client, accounts, transactions

    for name in (accounts, transactions):
        client.delete_table(TableName=name)


@pytest.fixture(params=["memory", "dynamodb"])
def repository(request: pytest.FixtureRequest):
    if request.param == "memory":
        return InMemoryLedgerRepository()
    # Requested lazily so the memory parametrisation does not pay for table
    # creation it never uses.
    client, accounts, transactions = request.getfixturevalue("dynamodb_tables")
    return DynamoDbLedgerRepository(client, accounts, transactions)
