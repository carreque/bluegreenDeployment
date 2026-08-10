"""Test-wide fixtures.

The AWS neutralisation below is load-bearing, not hygiene. This machine
exports AWS_PROFILE, live session keys and AWS_CREDENTIAL_EXPIRATION. While
AWS_CREDENTIAL_EXPIRATION is set, botocore treats the environment credentials
as refreshable, sees an expiry in the past and attempts an SSO refresh — which
fails before a single assertion runs. Botocore resolves credentials eagerly
during endpoint construction, so this happens on the first API call, not on
first use of a credential.

Pointing AWS_CONFIG_FILE at /dev/null is what makes the suite independent of
whatever profiles happen to be in ~/.aws/config.
"""

import os
from collections.abc import Iterator

import pytest

_FAKE_AWS_ENVIRONMENT = {
    "AWS_ACCESS_KEY_ID": "testing",
    "AWS_SECRET_ACCESS_KEY": "testing",
    "AWS_SESSION_TOKEN": "testing",
    "AWS_SECURITY_TOKEN": "testing",
    "AWS_DEFAULT_REGION": "us-east-1",
    "AWS_REGION": "us-east-1",
    "AWS_CONFIG_FILE": os.devnull,
    "AWS_SHARED_CREDENTIALS_FILE": os.devnull,
    "AWS_EC2_METADATA_DISABLED": "true",
}

_BANNED_AWS_ENVIRONMENT = (
    "AWS_PROFILE",
    "AWS_DEFAULT_PROFILE",
    "AWS_CREDENTIAL_EXPIRATION",
)


@pytest.fixture(scope="session", autouse=True)
def _neutralise_aws_environment() -> None:
    for name in _BANNED_AWS_ENVIRONMENT:
        os.environ.pop(name, None)
    os.environ.update(_FAKE_AWS_ENVIRONMENT)


@pytest.fixture(autouse=True)
def _clear_settings_cache() -> Iterator[None]:
    """get_settings is lru_cached; a test that sets BGD_* must not leak."""
    from bgd.config import get_settings

    get_settings.cache_clear()
    yield
    get_settings.cache_clear()
