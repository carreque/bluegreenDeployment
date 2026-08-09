"""The two locks must agree, and both must carry hashes.

requirements-dev.in includes requirements.in, so pip-compile resolves the two
files separately and could pin the same package to two different versions —
which would mean the boto3 the tests exercise is not the boto3 the image ships.
That drift is silent, so it is asserted rather than assumed.
"""

import re
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[2]
PIN = re.compile(r"^(?P<name>[A-Za-z0-9._-]+)==(?P<version>[^\s;\\]+)")


def _pins(path: Path) -> dict[str, str]:
    pins: dict[str, str] = {}
    for line in path.read_text().splitlines():
        match = PIN.match(line.strip())
        if match:
            pins[match["name"].lower().replace("_", "-")] = match["version"]
    return pins


def test_runtime_lock_is_populated() -> None:
    assert _pins(APP_ROOT / "requirements.txt"), "requirements.txt pins nothing"


def test_dev_lock_contains_every_runtime_package() -> None:
    missing = set(_pins(APP_ROOT / "requirements.txt")) - set(
        _pins(APP_ROOT / "requirements-dev.txt")
    )
    assert not missing, f"dev lock is missing runtime packages: {sorted(missing)}"


def test_dev_lock_agrees_with_the_runtime_lock() -> None:
    runtime = _pins(APP_ROOT / "requirements.txt")
    dev = _pins(APP_ROOT / "requirements-dev.txt")
    drifted = {n: (v, dev[n]) for n, v in runtime.items() if n in dev and dev[n] != v}
    assert not drifted, f"runtime/dev version drift (runtime, dev): {drifted}"


def test_both_locks_are_hash_pinned() -> None:
    for name in ("requirements.txt", "requirements-dev.txt"):
        text = (APP_ROOT / name).read_text()
        assert "--hash=sha256:" in text, f"{name} was compiled without --generate-hashes"
