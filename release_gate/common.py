#!/usr/bin/env python3
"""Shared helpers for PatchNest release-gate checks."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path
from typing import Any, Sequence


class GateError(RuntimeError):
    """Raised when a release gate is not satisfied."""


def root_path(value: str | os.PathLike[str]) -> Path:
    return Path(value).expanduser().resolve()


def run(command: Sequence[str], *, cwd: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        list(command), cwd=cwd, text=True, capture_output=True, check=False
    )
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise GateError(f"command failed ({' '.join(command)}): {detail}")
    return result


def git_head(root: Path) -> str:
    value = run(["git", "rev-parse", "HEAD"], cwd=root).stdout.strip()
    if len(value) != 40 or any(ch not in "0123456789abcdef" for ch in value):
        raise GateError("Git HEAD is not a full lowercase SHA-1")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_yaml12_json(path: Path) -> dict[str, Any]:
    """Load a JSON document. JSON is a strict subset of YAML 1.2."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise GateError(f"cannot parse YAML 1.2 JSON document {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise GateError(f"matrix root must be an object: {path}")
    return data


def emit(payload: dict[str, Any], *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return
    print(payload.get("summary", "gate passed"))
    for item in payload.get("details", []):
        print(f"- {item}")
