"""Fixtures for the image suite.

Everything here talks to a real container over real HTTP. Nothing imports bgd:
the point of this suite is to test the artifact, and importing the source would
quietly test the source instead.

The container reaches DynamoDB Local through host.docker.internal rather than
localhost, because localhost inside the container is the container. The
--add-host=host.docker.internal:host-gateway flag is what makes that name
resolve on a Linux CI runner; on Docker Desktop it already resolves and the
flag is harmless.
"""

import json
import subprocess
import time
from collections.abc import Iterator
from pathlib import Path

import httpx2
import pytest

APP_ROOT = Path(__file__).resolve().parents[2]
DIST = APP_ROOT / "dist"

CONTAINER_PORT = 8080
READY_TIMEOUT_SECONDS = 30

# No module-level `pytestmark` here: a conftest.py is not a test module, and a
# pytestmark set in one does not mark the tests it serves. Each test module in
# this directory declares the marker itself.


def _read_artifact(name: str) -> str:
    path = DIST / name
    if not path.exists():
        pytest.fail(f"{path} is missing — run `make build` first")
    return path.read_text().strip()


@pytest.fixture(scope="session")
def image_ref() -> str:
    """The local tag of the image under test, recorded by build-image.sh."""
    return _read_artifact("image-ref.txt")


@pytest.fixture(scope="session")
def image_config(image_ref: str) -> dict:
    """`docker image inspect`'s Config block, for the hygiene assertions."""
    raw = subprocess.run(
        ["docker", "image", "inspect", image_ref, "--format", "{{json .Config}}"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return json.loads(raw)


@pytest.fixture(scope="session")
def container(image_ref: str) -> Iterator[str]:
    """Run the image, wait for /health, yield its base URL, then remove it.

    --publish-all publishes the exposed port on a random free host port, so a
    developer already running `make run-local` on 8080 does not collide with
    this suite.
    """
    container_id = subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--detach",
            "--publish-all",
            "--add-host",
            "host.docker.internal:host-gateway",
            "--env",
            "BGD_ENVIRONMENT=test",
            "--env",
            "BGD_DYNAMODB_ENDPOINT_URL=http://host.docker.internal:8000",
            "--env",
            "BGD_ACCOUNTS_TABLE=bgd-us-east-1-local-accounts",
            "--env",
            "BGD_TRANSACTIONS_TABLE=bgd-us-east-1-local-transactions",
            image_ref,
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()

    try:
        port = (
            subprocess.run(
                ["docker", "port", container_id, f"{CONTAINER_PORT}/tcp"],
                capture_output=True,
                text=True,
                check=True,
            )
            .stdout.strip()
            .splitlines()[0]
            .rsplit(":", 1)[1]
        )

        base_url = f"http://127.0.0.1:{port}"
        _wait_for_health(base_url, container_id)
        yield base_url
    finally:
        subprocess.run(["docker", "rm", "--force", container_id], capture_output=True)


def _wait_for_health(base_url: str, container_id: str) -> None:
    """Poll /health until the process is serving, or fail with the logs.

    A container that dies on startup would otherwise present as a connection
    error thirty seconds later, with the actual traceback discarded.

    TransportError, not ConnectError. Docker publishes the port with a host-side
    proxy that accepts the TCP connection the moment the container exists, so a
    request made before uvicorn binds is answered with a reset — httpx2.ReadError
    — rather than refused. RemoteProtocolError appears the same way. All three
    share TransportError, and all three mean "not up yet", so the poll tolerates
    the family and lets the deadline be the thing that fails.
    """
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            if httpx2.get(f"{base_url}/health", timeout=1.0).status_code == 200:
                return
        except httpx2.TransportError:
            pass
        time.sleep(0.25)

    logs = subprocess.run(["docker", "logs", container_id], capture_output=True, text=True)
    pytest.fail(
        f"container never served /health within {READY_TIMEOUT_SECONDS}s\n"
        f"--- stdout ---\n{logs.stdout}\n--- stderr ---\n{logs.stderr}"
    )


@pytest.fixture
def client(container: str) -> Iterator[httpx2.Client]:
    with httpx2.Client(base_url=container, timeout=10.0) as http_client:
        yield http_client
