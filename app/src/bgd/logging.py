"""Structured JSON logging.

One JSON object per line, because CloudWatch Logs Insights parses line by line
and a record split across lines is silently dropped from every query.

Written against the standard library rather than structlog: the whole
requirement is a formatter and a context variable, and design §4.1's
reproducibility argument is easier to make with a smaller dependency set.
"""

import json
import logging
import sys
import time
from contextvars import ContextVar

request_id_var: ContextVar[str] = ContextVar("request_id", default="-")

# Everything LogRecord sets on itself. Anything else came from `extra=` and is
# promoted to a top-level key. Snapshotted from a real record so it cannot
# drift as the standard library adds attributes.
_RESERVED = frozenset(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {
    "asctime",
    "message",
    "taskName",
}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        created = time.gmtime(record.created)
        payload: dict[str, object] = {
            "timestamp": f"{time.strftime('%Y-%m-%dT%H:%M:%S', created)}.{int(record.msecs):03d}Z",
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "request_id": request_id_var.get(),
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED:
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str, separators=(",", ":"))


def configure_logging(level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level.upper())

    # uvicorn.access duplicates the access line RequestContextMiddleware emits,
    # in a different format. Silence it rather than log every request twice.
    logging.getLogger("uvicorn.access").handlers = []
    logging.getLogger("uvicorn.access").propagate = False
    logging.getLogger("uvicorn.error").handlers = [handler]
    logging.getLogger("uvicorn.error").propagate = False
