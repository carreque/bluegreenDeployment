"""Dependency wiring.

The repository lives on app.state, put there by create_app. That is what lets
every API test pass in the in-memory fake and never import boto3.
"""

from typing import Annotated

from fastapi import Depends, Request

from bgd.config import Settings
from bgd.domain.services import LedgerService
from bgd.repository.base import LedgerRepository


def get_repository(request: Request) -> LedgerRepository:
    return request.app.state.repository


def get_settings_dep(request: Request) -> Settings:
    return request.app.state.settings


def get_service(
    repository: Annotated[LedgerRepository, Depends(get_repository)],
) -> LedgerService:
    return LedgerService(repository)


RepositoryDep = Annotated[LedgerRepository, Depends(get_repository)]
SettingsDep = Annotated[Settings, Depends(get_settings_dep)]
ServiceDep = Annotated[LedgerService, Depends(get_service)]
