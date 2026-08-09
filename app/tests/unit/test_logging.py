import json
import logging
import sys

from bgd.logging import JsonFormatter, request_id_var


def _record(message: str = "hello", **extra: object) -> logging.LogRecord:
    record = logging.LogRecord("bgd.test", logging.INFO, __file__, 10, message, None, None)
    for key, value in extra.items():
        setattr(record, key, value)
    return record


def test_formatter_emits_one_json_object() -> None:
    payload = json.loads(JsonFormatter().format(_record()))
    assert payload["level"] == "INFO"
    assert payload["logger"] == "bgd.test"
    assert payload["message"] == "hello"
    assert payload["timestamp"].endswith("Z")


def test_formatter_includes_the_request_id() -> None:
    token = request_id_var.set("req-123")
    try:
        payload = json.loads(JsonFormatter().format(_record()))
    finally:
        request_id_var.reset(token)
    assert payload["request_id"] == "req-123"


def test_formatter_promotes_extra_fields_to_top_level_keys() -> None:
    payload = json.loads(JsonFormatter().format(_record("request", status=201, duration_ms=4.2)))
    assert payload["status"] == 201
    assert payload["duration_ms"] == 4.2


def test_formatter_renders_exceptions() -> None:
    try:
        raise ValueError("boom")
    except ValueError:
        record = logging.LogRecord(
            "bgd.test", logging.ERROR, __file__, 10, "failed", None, sys.exc_info()
        )
    payload = json.loads(JsonFormatter().format(record))
    assert "ValueError: boom" in payload["exception"]


def test_a_multiline_message_never_produces_a_multiline_record() -> None:
    """CloudWatch Logs Insights parses one JSON object per line. A record split
    across lines is silently unparseable, so the formatter must escape it."""
    formatted = JsonFormatter().format(_record("line one\nline two"))
    assert "\n" not in formatted
    assert json.loads(formatted)["message"] == "line one\nline two"
