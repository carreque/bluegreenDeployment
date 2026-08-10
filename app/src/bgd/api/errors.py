"""HTTP error representation — RFC 9457 problem details.

This module is the only place that knows how a domain error maps to a status
code. The domain stays transport-agnostic, and adding an error there without
adding it here is caught by test_every_domain_error_code_has_a_status.
"""

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from bgd.domain.errors import DomainError
from bgd.logging import request_id_var

logger = logging.getLogger(__name__)

PROBLEM_TYPE_BASE = "https://carloscloudengineer.com/problems/"

STATUS_BY_CODE: dict[str, int] = {
    "ACCOUNT_NOT_FOUND": 404,
    "ACCOUNT_ALREADY_EXISTS": 409,
    "DUPLICATE_TRANSACTION": 409,
    "INSUFFICIENT_FUNDS": 409,
    "CURRENCY_MISMATCH": 422,
    "INVARIANT_VIOLATION": 422,
    "REPOSITORY_UNAVAILABLE": 503,
    "DOMAIN_ERROR": 500,
}

_TITLES = {
    400: "Bad Request",
    404: "Not Found",
    409: "Conflict",
    422: "Unprocessable Content",
    500: "Internal Server Error",
    503: "Service Unavailable",
}


def problem_response(
    status: int, code: str, detail: str, instance: str, **extra: object
) -> JSONResponse:
    body: dict[str, object] = {
        "type": PROBLEM_TYPE_BASE + code.lower().replace("_", "-"),
        "title": _TITLES.get(status, "Error"),
        "status": status,
        "detail": detail,
        "instance": instance,
        "code": code,
        "request_id": request_id_var.get(),
    }
    body.update(extra)
    return JSONResponse(status_code=status, content=body, media_type="application/problem+json")


def install_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(DomainError)
    async def _domain(request: Request, exc: DomainError) -> JSONResponse:
        status = STATUS_BY_CODE.get(exc.code, 500)
        if status >= 500:
            logger.error("domain error", extra={"code": exc.code, "detail": exc.message})
        return problem_response(status, exc.code, exc.message, request.url.path, **exc.details)

    @app.exception_handler(RequestValidationError)
    async def _validation(request: Request, exc: RequestValidationError) -> JSONResponse:
        return problem_response(
            422,
            "VALIDATION_FAILED",
            "the request body or parameters failed validation",
            request.url.path,
            errors=[
                {
                    # loc[0] is the source ("body", "query"); the rest is the path.
                    "field": ".".join(str(part) for part in error["loc"][1:]),
                    "message": error["msg"],
                }
                for error in exc.errors()
            ],
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = "NOT_FOUND" if exc.status_code == 404 else "HTTP_ERROR"
        return problem_response(exc.status_code, code, str(exc.detail), request.url.path)

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
        # The detail goes to the log, never to the client. request_id is the
        # link between the two — taken from the scope rather than the
        # ContextVar, which RequestContextMiddleware has already reset by the
        # time this handler runs (it sits outside that middleware). Without
        # this the body and the traceback both carry "-" and cannot be joined.
        request_id = getattr(request.state, "request_id", request_id_var.get())
        logger.exception(
            "unhandled exception",
            extra={"path": request.url.path, "request_id": request_id},
        )
        return problem_response(
            500,
            "INTERNAL_ERROR",
            "an unexpected error occurred",
            request.url.path,
            request_id=request_id,
        )
