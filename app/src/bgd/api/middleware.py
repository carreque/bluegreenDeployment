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
        # Also on the scope, not only in the ContextVar. The `finally` below
        # resets the var as an exception propagates *out* of this middleware,
        # and ServerErrorMiddleware — which builds the 500 — runs one layer
        # further out, after that reset. The scope outlives both.
        scope.setdefault("state", {})["request_id"] = request_id
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


# One policy for the whole application, not just for the page. The JSON API
# gets it too, which costs nothing and means a header cannot be lost by a route
# being registered somewhere unexpected.
#
# No 'unsafe-inline' anywhere, which is the whole reason the page is three
# files rather than one (Phase 12 plan, D5). connect-src 'self' is what the
# banner's poll and the form's POST need, and nothing else is permitted to
# leave the page.
#
# form-action 'none' is correct and not an oversight: the form is submitted by
# fetch after preventDefault(), never by a native POST, so nothing legitimate
# needs a form action.
#
# One casualty, accepted: /docs. FastAPI's Swagger UI loads its script and
# stylesheet from a CDN, and default-src 'none' blocks both, so the page
# renders empty. /docs is a development affordance, /openapi.json is
# unaffected, and the alternative is a permanent hole in the policy on every
# production response.
SECURITY_HEADERS = (
    (
        b"content-security-policy",
        b"default-src 'none'; script-src 'self'; style-src 'self'; "
        b"connect-src 'self'; img-src 'none'; base-uri 'none'; "
        b"form-action 'none'; frame-ancestors 'none'",
    ),
    (b"x-content-type-options", b"nosniff"),
    (b"referrer-policy", b"no-referrer"),
    (b"x-frame-options", b"DENY"),
)


class SecurityHeadersMiddleware:
    """Append SECURITY_HEADERS to every HTTP response this middleware sees.

    Raw ASGI rather than BaseHTTPMiddleware, matching RequestContextMiddleware
    above: the two now both wrap send, and mixing the two styles would put an
    anyio task boundary between them for no gain.

    One response this middleware never sees: the 500 built by the
    @app.exception_handler(Exception) handler in errors.py. Starlette's stack
    is ServerErrorMiddleware -> user middleware -> ExceptionMiddleware ->
    router, and that handler is wired to ServerErrorMiddleware, one layer
    outside both custom middlewares here. A response on that path goes
    straight to the raw `send` and carries none of SECURITY_HEADERS — no CSP,
    no nosniff, no X-Frame-Options, no Referrer-Policy. This mirrors the
    x-request-id gap RequestContextMiddleware already documents above, and the
    same reasoning is why it is left alone rather than closed: the body on
    that path is a fixed application/problem+json document with no
    request-derived content, so the missing headers cost nothing a real
    response would need them for. Recorded rather than fixed, and asserted by
    test_errors.py::test_an_unhandled_exception_carries_no_security_headers.
    """

    def __init__(self, app: Callable) -> None:
        self.app = app

    async def __call__(self, scope: dict, receive: Callable, send: Callable) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_wrapper(message: dict) -> None:
            if message["type"] == "http.response.start":
                message["headers"] = [*message["headers"], *SECURITY_HEADERS]
            await send(message)

        await self.app(scope, receive, send_wrapper)
