#!/usr/bin/env python3
"""Validate source and packaged file types and permission boundaries."""
from __future__ import annotations

import argparse
import stat
import zipfile
from pathlib import Path
import sys

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from release_gate.common import GateError, emit, root_path, run

EXECUTABLE_CANDIDATE = (
    "bin/kpatch",
    "bin/kptools",
    "bin/kpimg",
    "bin/magiskboot",
    "bin/kpm-verify",
    "bin/kp-safemode",
)


def _check_source(root: Path) -> list[str]:
    records = run(["git", "ls-files", "-s", "module"], cwd=root).stdout.splitlines()
    if not records:
        raise GateError("Git index has no module files")
    for line in records:
        mode, _sha, _stage_path = line.split(maxsplit=2)
        path = _stage_path.split("\t", 1)[-1]
        if mode in {"120000", "160000"}:
            raise GateError(f"module contains unsupported Git mode {mode}: {path}")
        if mode not in {"100644", "100755"}:
            raise GateError(f"unexpected Git mode {mode}: {path}")
    for path in (root / "module").rglob("*"):
        if path.is_symlink():
            raise GateError(f"source module symlink: {path.relative_to(root)}")
        if path.is_file() and path.stat().st_mode & 0o022:
            raise GateError(f"source file is group/world writable: {path.relative_to(root)}")
    return [f"indexed module files={len(records)}", "no source symlink or writable file"]


def _check_candidate(candidate: Path) -> list[str]:
    with zipfile.ZipFile(candidate) as archive:
        names = set(archive.namelist())
        for required in EXECUTABLE_CANDIDATE:
            if required not in names:
                raise GateError(f"candidate missing executable: {required}")
            info = archive.getinfo(required)
            mode = (info.external_attr >> 16) & 0xFFFF
            if not mode or not stat.S_ISREG(mode):
                raise GateError(f"candidate executable lacks regular-file mode: {required}")
            if not (mode & 0o100):
                raise GateError(f"candidate executable lacks owner execute bit: {required}")
            if mode & 0o022:
                raise GateError(f"candidate executable is group/world writable: {required}")
        for info in archive.infolist():
            mode = (info.external_attr >> 16) & 0xFFFF
            if mode and stat.S_ISLNK(mode):
                raise GateError(f"candidate contains symlink: {info.filename}")
            if mode and mode & 0o022:
                raise GateError(f"candidate entry is group/world writable: {info.filename}")
    return ["candidate executable modes valid", "candidate has no writable/symlink entries"]


def check(root: Path, *, candidate: Path | None, release_ready: bool) -> dict:
    details = _check_source(root)
    if candidate:
        details.extend(_check_candidate(candidate.resolve()))
    elif release_ready:
        raise GateError("release-ready permission gate requires --candidate")
    return {
        "gate": "permissions",
        "status": "pass",
        "releaseReady": release_ready,
        "summary": "Permission gate passed",
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
    except (GateError, zipfile.BadZipFile) as exc:
        print(f"ERROR: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
