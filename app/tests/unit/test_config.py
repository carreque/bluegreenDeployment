from bgd.config import Settings, get_settings


def test_defaults_are_local_development_values() -> None:
    settings = Settings(_env_file=None)
    assert settings.environment == "local"
    assert settings.app_version == "0.0.0-dev"
    assert settings.git_sha == "unknown"
    assert settings.image_digest == "unknown"
    assert settings.dynamodb_endpoint_url is None
    assert settings.aws_region == "us-east-1"


def test_table_names_follow_the_naming_convention() -> None:
    settings = Settings(_env_file=None)
    assert settings.accounts_table == "bgd-us-east-1-local-accounts"
    assert settings.transactions_table == "bgd-us-east-1-local-transactions"


def test_settings_read_the_bgd_prefixed_environment(monkeypatch) -> None:
    monkeypatch.setenv("BGD_GIT_SHA", "abc1234")
    monkeypatch.setenv("BGD_ENVIRONMENT", "prod")
    monkeypatch.setenv("BGD_DYNAMODB_ENDPOINT_URL", "http://localhost:8000")
    settings = Settings(_env_file=None)
    assert settings.git_sha == "abc1234"
    assert settings.environment == "prod"
    assert settings.dynamodb_endpoint_url == "http://localhost:8000"


def test_unprefixed_environment_is_ignored(monkeypatch) -> None:
    """AWS_REGION must not be mistaken for BGD_AWS_REGION."""
    monkeypatch.setenv("AWS_REGION", "eu-west-1")
    assert Settings(_env_file=None).aws_region == "us-east-1"


def test_get_settings_is_cached() -> None:
    assert get_settings() is get_settings()
