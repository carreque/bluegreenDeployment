"""/version must report what the build injected.

This is the endpoint Phase 6 curls against the :443 and :8443 listeners during
a blue/green shift, where two different git_sha values are the direct proof of
which colour serves whom. If the build arguments do not reach it, that evidence
does not exist.
"""

from pathlib import Path

import httpx2
import pytest

APP_ROOT = Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.image


def test_version_reports_the_injected_build_identity(client: httpx2.Client) -> None:
    body = client.get("/version").json()
    expected_prefix = (APP_ROOT / "VERSION").read_text().strip()

    assert body["version"].startswith(f"{expected_prefix}."), body["version"]
    assert body["git_sha"] not in ("", "unknown"), "GIT_SHA never reached the image"
    assert body["built_at"].endswith("Z"), body["built_at"]


def test_image_digest_is_unknown_until_terraform_injects_it(client: httpx2.Client) -> None:
    """An image cannot contain its own digest — the digest is its hash.

    Phases 5 and 6 set BGD_IMAGE_DIGEST in the ECS task definition, which is
    the only place that knows which digest is actually deployed. This asserts
    the deliberate gap so that closing it wrongly, at build time, is a red test.
    """
    assert client.get("/version").json()["image_digest"] == "unknown"


def test_release_color_reaches_the_image(client: httpx2.Client) -> None:
    """The tint the demonstration rests on is a build argument like any other.

    If RELEASE_COLOR does not reach the image, the page renders the "slate"
    default and both listeners show the same colour during a shift — which
    looks like a blue/green failure and is not one. Two causes, one symptom;
    this is the test that rules out the boring cause before anybody starts
    reading CloudTrail for the interesting one.
    """
    expected = (APP_ROOT / "RELEASE_COLOR").read_text().strip()
    assert client.get("/version").json()["release_color"] == expected
