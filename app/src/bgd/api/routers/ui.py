"""The demonstration page.

Three files, read once at import and served from memory. Not per request: the
production task runs with readonlyRootFilesystem (F6) and, more usefully, bytes
fixed at process start cannot vary by request — which is what makes "the server
interpolates nothing" a property rather than a claim (D9).

The page learns its own colour by fetching /version, so a tab left open on the
production listener re-tints itself when ECS moves the listener rule.
Templating it here would have made the colour a property of when the page was
loaded instead. Phase 12 plan, D4.
"""

from pathlib import Path

from fastapi import APIRouter, Response

# ../static from this module: the files live beside the api package, not beside
# the routers package, so this is parents[1] and not .parent.
STATIC = Path(__file__).resolve().parents[1] / "static"

INDEX_HTML = (STATIC / "index.html").read_text(encoding="utf-8")
APP_CSS = (STATIC / "app.css").read_text(encoding="utf-8")
APP_JS = (STATIC / "app.js").read_text(encoding="utf-8")

# D8. The one thing the page must never do is show a previous build's colour
# after a shift, which is exactly what a cached response would do — and it
# would look like the demonstration working.
NO_STORE = {"cache-control": "no-store"}

# include_in_schema=False on the router: these are not API, and three HTML
# routes in /openapi.json would be noise in a document Phase 8 publishes.
router = APIRouter(tags=["ui"], include_in_schema=False)


@router.get("/")
def index() -> Response:
    return Response(content=INDEX_HTML, media_type="text/html", headers=NO_STORE)


@router.get("/app.css")
def stylesheet() -> Response:
    return Response(content=APP_CSS, media_type="text/css", headers=NO_STORE)


@router.get("/app.js")
def script() -> Response:
    # text/javascript exactly. X-Content-Type-Options: nosniff means a wrong
    # type here is a script the browser refuses to execute, on a page whose
    # only behaviour is script.
    return Response(content=APP_JS, media_type="text/javascript", headers=NO_STORE)
