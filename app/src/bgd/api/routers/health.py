"""Operational endpoints.

/health and /ready are deliberately different. /health is what the ALB target
group polls: it must report only whether this process is alive, because a
dependency check there would let a DynamoDB hiccup deregister every healthy
task at once. /ready is for humans and for deployment gates, and does check.
"""

from fastapi import APIRouter, Response

from bgd.api.dependencies import RepositoryDep, SettingsDep
from bgd.api.schemas import HealthResponse, ReadyResponse, VersionResponse
from bgd.domain.errors import DomainError

router = APIRouter(tags=["operations"])


@router.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse()


@router.get("/ready", response_model=ReadyResponse)
def ready(repository: RepositoryDep, response: Response) -> ReadyResponse:
    try:
        repository.ping()
    except DomainError:
        response.status_code = 503
        return ReadyResponse(status="not_ready", checks={"dynamodb": "unavailable"})
    return ReadyResponse(status="ready", checks={"dynamodb": "ok"})


@router.get("/version", response_model=VersionResponse)
def version(settings: SettingsDep, response: Response) -> VersionResponse:
    """Build identity of the running task.

    Phase 6 curls this against the :443 production listener and the :8443 test
    listener during a blue/green shift; two different git_sha values are the
    direct proof of which colour is serving whom.

    Phase 12 polls it from the browser every two seconds and tints the page
    from release_color, so the same two-listener comparison becomes two
    colours on two screens rather than two JSON bodies in two terminals.

    no-store because a cached body would keep showing the previous build after
    a shift — a demonstration that appears to work and is wrong (D8).
    """
    response.headers["cache-control"] = "no-store"
    return VersionResponse(
        version=settings.app_version,
        git_sha=settings.git_sha,
        image_digest=settings.image_digest,
        built_at=settings.built_at,
        release_color=settings.release_color,
    )
