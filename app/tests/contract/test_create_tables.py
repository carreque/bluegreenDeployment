"""The local table bootstrap, against DynamoDB Local.

Two properties matter here and neither is cosmetic. The refusal guard is the
only thing standing between a stray AWS_PROFILE and real tables created in a
real account, and idempotency is what makes `make run-local` safe to run
repeatedly — it is a dependency of run-local, so it executes on every start.
"""

import uuid

import pytest

from bgd.cli.create_tables import main


@pytest.fixture
def local_tables(monkeypatch, dynamodb_endpoint: str) -> tuple[str, str]:
    """Point the CLI's settings at DynamoDB Local with private table names."""
    suffix = uuid.uuid4().hex[:12]
    accounts = f"bgd-us-east-1-cli-{suffix}-accounts"
    transactions = f"bgd-us-east-1-cli-{suffix}-transactions"

    monkeypatch.setenv("BGD_DYNAMODB_ENDPOINT_URL", dynamodb_endpoint)
    monkeypatch.setenv("BGD_ACCOUNTS_TABLE", accounts)
    monkeypatch.setenv("BGD_TRANSACTIONS_TABLE", transactions)
    return accounts, transactions


def test_it_refuses_to_run_without_an_endpoint(monkeypatch) -> None:
    """Without this guard the CLI would follow whatever AWS_PROFILE happens to
    be exported and create tables in a real account."""
    monkeypatch.delenv("BGD_DYNAMODB_ENDPOINT_URL", raising=False)
    # get_settings reads app/.env when it exists, which sets the endpoint. The
    # CLI is being tested, not the developer's dotfile.
    monkeypatch.chdir("/")

    with pytest.raises(SystemExit) as caught:
        main()
    assert "Refusing to create tables" in str(caught.value)


def test_it_creates_both_tables_and_is_idempotent(local_tables, dynamodb_client, capsys) -> None:
    accounts, transactions = local_tables

    main()
    first = capsys.readouterr().out
    assert f"created  {accounts}" in first
    assert f"created  {transactions}" in first

    # Second run: the tables exist, and the CLI says so rather than failing.
    main()
    second = capsys.readouterr().out
    assert f"exists   {accounts}" in second
    assert f"exists   {transactions}" in second

    client = dynamodb_client
    try:
        described = client.describe_table(TableName=transactions)["Table"]
        indexes = [i["IndexName"] for i in described.get("LocalSecondaryIndexes", [])]
        # The LSI cannot be added after the fact, so its absence here would be
        # unrecoverable on a real table. Phases 5 and 6 declare the same shape.
        assert indexes == ["created_at-index"]
    finally:
        for name in (accounts, transactions):
            client.delete_table(TableName=name)
