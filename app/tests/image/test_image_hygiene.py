"""Properties of the image itself, independent of what it serves."""

import re
import subprocess
from pathlib import Path

import pytest

APP_ROOT = Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.image


def test_the_image_does_not_run_as_root(image_config: dict) -> None:
    assert image_config["User"] == "10001:10001"


def test_the_running_process_is_not_root(image_ref: str) -> None:
    """Config.User is a declaration; this is the observation."""
    uid = subprocess.run(
        ["docker", "run", "--rm", "--entrypoint", "id", image_ref, "-u"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    assert uid == "10001"


def test_the_application_port_is_exposed(image_config: dict) -> None:
    assert "8080/tcp" in image_config["ExposedPorts"]


def test_the_image_ships_no_host_compiled_bytecode(image_ref: str) -> None:
    """No .pyc under /app/src — nothing in the build compiles the application.

    Any that appear were compiled on the developer's machine and swept in by the
    build context, which is a reproducibility hole rather than a cosmetic one:
    running the test suite regenerates them, so the image digest would change
    without a single line of source changing. That is precisely what happened
    before .dockerignore gained its **/ prefixes.

    Asked through python rather than a shell, so this keeps working if the image
    ever moves to a base without one.
    """
    found = subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--entrypoint",
            "python",
            image_ref,
            "-c",
            "import pathlib; print('\\n'.join(str(p) for p in "
            "pathlib.Path('/app/src').rglob('*.pyc')))",
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    assert not found, f"host-compiled bytecode leaked into the image:\n{found}"


def test_the_package_is_reachable_without_being_installed(image_config: dict) -> None:
    """The package is never pip-installed; PYTHONPATH is how it is found."""
    assert "PYTHONPATH=/app/src" in image_config["Env"]


def test_the_base_image_is_pinned_by_digest() -> None:
    dockerfile = (APP_ROOT / "Dockerfile").read_text()
    assert "ARG BASE_IMAGE=" in dockerfile
    assert re.search(r"ARG BASE_IMAGE=\S+@sha256:[0-9a-f]{64}", dockerfile), (
        "the base image must be pinned by digest, not by tag (design §4.1)"
    )
    assert ":latest" not in dockerfile
