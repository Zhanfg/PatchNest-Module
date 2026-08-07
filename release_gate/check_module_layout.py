#!/usr/bin/env python3
"""Validate source-module and candidate ZIP layout without executing package code."""
from __future__ import annotations

import argparse
import re
import stat
import zipfile
from pathlib import Path, PurePosixPath
import sys

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from release_gate.common import GateError, emit, root_path

SOURCE_REQUIRED = (
    "module/module.prop",
    "module/customize.sh",
    "module/post-fs-data.sh",
    "module/service.sh",
    "module/uninstall.sh",
    "module/runtime_compat_check.sh",
    "module/kpm_verify.sh",
    "module/kpm_transaction_store.sh",
    "module/kpm_install_recovery.sh",
    "module/manage_kpm_quarantine.sh",
    "module/patch/boot_extract.sh",
    "module/patch/boot_patch.sh",
    "module/patch/boot_unpatch.sh",
    "module/patch/boot_restore_verified.sh",
    "module/patch/boot_target.sh",
    "module/patch/flash_guard.sh",
    "module/patch/recovery_state.sh",
)
CANDIDATE_REQUIRED = tuple(item.removeprefix("module/") for item in SOURCE_REQUIRED) + (
    "bin/kpatch",
    "bin/kptools",
    "bin/kpimg",
    "bin/magiskboot",
    "bin/kpm-verify",
    "bin/kp-safemode",
    "licenses/Monocypher-LICENCE.md",
    "webroot/index.html",
    "webroot/index.js",
)
FORBIDDEN_PARTS = {".git", "node_modules", "out", "audit-output", "__pycache__", ".pytest_cache"}
TEMP_SUFFIXES = (".tmp", ".bak", ".orig", ".rej", "~")


def _parse_module_prop(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise GateError(f"module.prop line {number} is not key=value")
        key, value = line.split("=", 1)
        if key in values:
            raise GateError(f"module.prop duplicate key: {key}")
        values[key] = value
    if values.get("id") != "PatchNest":
        raise GateError("module.prop id must be PatchNest")
    if not re.fullmatch(r"[0-9]+", values.get("versionCode", "")):
        raise GateError("module.prop versionCode must be numeric")
    if not values.get("version"):
        raise GateError("module.prop version is missing")
    return values


def _safe_name(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(name) and not name.startswith("/") and "\\" not in name and ".." not in path.parts


def _check_source(root: Path) -> list[str]:
    missing = [item for item in SOURCE_REQUIRED if not (root / item).is_file()]
    if missing:
        raise GateError("source module missing: " + ", ".join(missing))
    _parse_module_prop((root / "module/module.prop").read_text(encoding="utf-8"))
    for path in (root / "module").rglob("*"):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise GateError(f"source module contains symlink: {relative}")
        if any(part in FORBIDDEN_PARTS for part in path.parts):
            raise GateError(f"source module contains forbidden path: {relative}")
        if path.is_file() and path.name.endswith(TEMP_SUFFIXES):
            raise GateError(f"source module contains temporary file: {relative}")
    return ["source module layout valid"]


def _check_candidate(candidate: Path) -> list[str]:
    if not candidate.is_file():
        raise GateError(f"candidate archive not found: {candidate}")
    with zipfile.ZipFile(candidate) as archive:
        infos = archive.infolist()
        names = [item.filename for item in infos]
        if len(names) != len(set(names)):
            raise GateError("candidate contains duplicate paths")
        for info in infos:
            name = info.filename
            if not _safe_name(name):
                raise GateError(f"unsafe candidate path: {name}")
            parts = PurePosixPath(name).parts
            if any(part in FORBIDDEN_PARTS for part in parts):
                raise GateError(f"candidate contains forbidden path: {name}")
            if name.endswith(TEMP_SUFFIXES):
                raise GateError(f"candidate contains temporary file: {name}")
            mode = (info.external_attr >> 16) & 0xFFFF
            if mode and stat.S_ISLNK(mode):
                raise GateError(f"candidate contains symlink: {name}")
        missing = [item for item in CANDIDATE_REQUIRED if item not in names]
        if missing:
            raise GateError("candidate missing required files: " + ", ".join(missing))
        _parse_module_prop(archive.read("module.prop").decode("utf-8"))
    return [f"candidate layout valid: {candidate}"]


def check(root: Path, *, candidate: Path | None, release_ready: bool) -> dict:
    details = _check_source(root)
    if candidate:
        details.extend(_check_candidate(candidate.resolve()))
    elif release_ready:
        raise GateError("release-ready layout gate requires --candidate")
    return {
        "gate": "module-layout",
        "status": "pass",
        "releaseReady": release_ready,
        "summary": "Module layout gate passed",
        "details": details,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    parser.add_argument("--candidate")
    parser.add_argument("--release-ready", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        candidate = Path(args.candidate) if args.candidate else None
        emit(check(root_path(args.root), candidate=candidate, release_ready=args.release_ready), as_json=args.json)
        return 0
    except (GateError, UnicodeDecodeError, zipfile.BadZipFile) as exc:
        print(f"ERROR: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
