"""Runtime configuration.

Environment variables only, prefix BGD_. No file is read at runtime: the
container gets its configuration from the ECS task definition, and reading a
file would create a second, invisible source of truth.

The build-metadata fields keep local-development defaults. Phase 2 injects the
real values as Docker build arguments and Phase 6 reads them back off /version
during a blue/green shift, which is how a running task announces which colour
it is.
"""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="BGD_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    environment: str = "local"
    log_level: str = "INFO"

    # Build metadata, surfaced by /version. Overwritten at image build time.
    app_version: str = "0.0.0-dev"
    git_sha: str = "unknown"
    image_digest: str = "unknown"
    built_at: str = "unknown"

    aws_region: str = "us-east-1"
    # Set to http://localhost:8000 for DynamoDB Local. None means real AWS.
    dynamodb_endpoint_url: str | None = None

    accounts_table: str = "bgd-us-east-1-local-accounts"
    transactions_table: str = "bgd-us-east-1-local-transactions"


@lru_cache
def get_settings() -> Settings:
    return Settings()
