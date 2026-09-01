import pytest
from pydantic import ValidationError

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


def test_release_color_defaults_to_neither_demo_colour() -> None:
    """A container started without build arguments must not look deployed.

    compose, a bare uvicorn and every test run land here. If this defaulted to
    blue, a local window would be indistinguishable from a production one in a
    screenshot. Phase 12 plan, D6.
    """
    assert Settings(_env_file=None).release_color == "slate"


def test_release_color_is_read_from_the_environment(monkeypatch) -> None:
    monkeypatch.setenv("BGD_RELEASE_COLOR", "green")
    assert Settings(_env_file=None).release_color == "green"


def test_an_unknown_release_color_is_rejected(monkeypatch) -> None:
    """A typo in app/RELEASE_COLOR is a container that refuses to start.

    The alternative is an untinted button discovered in front of an audience,
    which is the same defect found several hours later.
    """
    monkeypatch.setenv("BGD_RELEASE_COLOR", "purple")
    with pytest.raises(ValidationError):
        Settings(_env_file=None)
