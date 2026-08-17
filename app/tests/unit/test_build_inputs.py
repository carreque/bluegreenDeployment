"""The inputs the image build reads, asserted rather than assumed.

Both contracts here fail silently if broken. A malformed VERSION produces a
nonsense image tag that still pushes; a .dockerignore that stops excluding
app/.venv silently ships a 400 MB host virtualenv built for macOS into a Linux
image, where it would shadow /opt/venv on PYTHONPATH.
"""

import re
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[2]

MAJOR_MINOR = re.compile(r"^\d+\.\d+$")


def _dockerignore_patterns() -> set[str]:
    lines = (APP_ROOT / ".dockerignore").read_text().splitlines()
    return {line.strip() for line in lines if line.strip() and not line.startswith("#")}


def test_version_is_major_minor_only() -> None:
    """The patch position is the build number, supplied at build time."""
    version = (APP_ROOT / "VERSION").read_text().strip()
    assert MAJOR_MINOR.match(version), f"VERSION must be MAJOR.MINOR, got {version!r}"


def test_dockerignore_excludes_the_host_virtualenv() -> None:
    assert ".venv" in _dockerignore_patterns()


def test_dockerignore_excludes_tests_and_build_output() -> None:
    patterns = _dockerignore_patterns()
    for expected in ("tests", "dist"):
        assert expected in patterns, f".dockerignore must exclude {expected}"


def test_bytecode_is_excluded_recursively_not_just_at_the_root() -> None:
    """A bare `__pycache__` entry excludes nothing that matters.

    .dockerignore patterns are anchored to the context root, so `__pycache__`
    matches app/__pycache__ and never app/src/bgd/__pycache__ — where the host's
    bytecode actually lives. The first version of this file made exactly that
    mistake and shipped 24 host-compiled .pyc files into the image, which also
    meant the image digest changed whenever anyone ran the test suite.

    tests/image/test_image_hygiene.py asserts the outcome; this asserts the
    cause, because the pattern is the part that is easy to "tidy" back.
    """
    patterns = _dockerignore_patterns()
    for expected in ("**/__pycache__", "**/*.pyc"):
        assert expected in patterns, f".dockerignore must exclude {expected} recursively"
