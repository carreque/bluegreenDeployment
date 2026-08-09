"""Request context and access logging.

Written as raw ASGI rather than a BaseHTTPMiddleware subclass. BaseHTTPMiddleware
runs the downstream application in a separate anyio task, which makes
ContextVar propagation subtle in exactly the direction this needs. Raw ASGI
shares the context directly, and is about the same amount of code.
"""

import logging
import time
import uuid
from collections.abc import Callable

from starlette.datastructures import Headers

from bgd.logging import request_id_var

logger = logging.getLogger("bgd.access")


class RequestContextMiddleware:
    def __init__(self, app: Callable) -> None:
        self.app = app

    async def __call__(self, scope: dict, receive: Callable, send: Callable) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        request_id = Headers(scope=scope).get("x-request-id") or uuid.uuid4().hex
        token = request_id_var.set(request_id)
        started = time.perf_counter()
        status = 500

        async def send_wrapper(message: dict) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
                message["headers"] = [
                    *message["headers"],
                    (b"x-request-id", request_id.encode()),
                ]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            logger.info(
                "request",
                extra={
                    "method": scope["method"],
                    "path": scope["path"],
                    "status": status,
                    "duration_ms": round((time.perf_counter() - started) * 1000, 2),
                },
            )
            request_id_var.reset(token)
