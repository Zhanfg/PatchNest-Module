#!/usr/bin/env python3
"""Verify the pinned Monocypher tag and official GitHub Release asset metadata."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

API_ROOT = "https://api.github.com/repos/LoupVaillant/Monocypher"


def parse_kv(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"{path}:{number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if key in result:
            raise ValueError(f"{path}:{number}: duplicate key {key}")
        result[key] = value
    return result


def validate_payloads(
    *,
    version: str,
    expected_commit: str,
    expected_digest: str,
    tag_payload: dict[str, Any],
    release_payload: dict[str, Any],
) -> list[str]:
    errors: list[str] = []

    expected_ref = f"refs/tags/{version}"
    if tag_payload.get("ref") != expected_ref:
        errors.append(f"tag ref mismatch: expected {expected_ref}")
    tag_object = tag_payload.get("object")
    if not isinstance(tag_object, dict):
        errors.append("tag payload has no object")
    else:
        if tag_object.get("type") != "commit":
            errors.append("Monocypher release tag must point directly to a commit")
        if tag_object.get("sha") != expected_commit:
            errors.append(
                f"tag commit mismatch: expected {expected_commit}, got {tag_object.get('sha')}"
            )

    if release_payload.get("tag_name") != version:
        errors.append("release tag_name does not match the pinned version")
    if release_payload.get("draft") is not False:
        errors.append("pinned Monocypher release is a draft")
    if release_payload.get("prerelease") is not False:
        errors.append("pinned Monocypher release is marked prerelease")

    expected_name = f"monocypher-{version}.tar.gz"
    expected_url = (
        "https://github.com/LoupVaillant/Monocypher/releases/download/"
        f"{version}/{expected_name}"
    )
    assets = release_payload.get("assets")
    if not isinstance(assets, list):
        errors.append("release payload has no assets array")
        assets = []
    matching = [
        asset
        for asset in assets
        if isinstance(asset, dict) and asset.get("name") == expected_name
    ]
    if len(matching) != 1:
        errors.append(f"release must contain exactly one {expected_name} asset")
    else:
        asset = matching[0]
        if asset.get("state") != "uploaded":
            errors.append("Monocypher release asset is not in uploaded state")
        if not isinstance(asset.get("size"), int) or int(asset["size"]) <= 0:
            errors.append("Monocypher release asset size is invalid")
        if asset.get("digest") != f"sha256:{expected_digest}":
            errors.append(
                "Monocypher GitHub asset digest mismatch: "
                f"expected sha256:{expected_digest}, got {asset.get('digest')}"
            )
        if asset.get("browser_download_url") != expected_url:
            errors.append("Monocypher release asset download URL mismatch")

    return errors


def request_headers(token: str | None = None) -> dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "PatchNest-release-verifier",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def fetch_json(url: str, *, token: str | None = None) -> dict[str, Any]:
    if not url.startswith(f"{API_ROOT}/"):
        raise ValueError("refusing to send GitHub credentials outside the pinned API root")
    request = urllib.request.Request(url, headers=request_headers(token))
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status != 200:
            raise RuntimeError(f"unexpected HTTP status {response.status} for {url}")
        payload = json.load(response)
    if not isinstance(payload, dict):
        raise RuntimeError(f"unexpected non-object JSON from {url}")
    return payload


def verify_online(root: Path, *, token: str | None = None) -> list[str]:
    versions = parse_kv(root / "version.properties")
    version = versions.get("monocypher", "")
    commit = versions.get("monocypher_commit", "")
    digest = versions.get(f"monocypher_tar_{version}", "")
    if not version or not commit or not digest:
        return ["Monocypher version, commit, or trusted digest is missing"]

    tag = fetch_json(f"{API_ROOT}/git/ref/tags/{version}", token=token)
    release = fetch_json(f"{API_ROOT}/releases/tags/{version}", token=token)
    return validate_payloads(
        version=version,
        expected_commit=commit,
        expected_digest=digest,
        tag_payload=tag,
        release_payload=release,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    args = parser.parse_args()

    try:
        errors = verify_online(
            Path(args.root).resolve(), token=os.environ.get("GITHUB_TOKEN") or None
        )
    except (OSError, ValueError, RuntimeError, urllib.error.URLError, json.JSONDecodeError) as exc:
        print(f"ERROR: Monocypher metadata verification could not complete: {exc}", file=sys.stderr)
        return 2

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("Monocypher tag and GitHub Release asset metadata verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
