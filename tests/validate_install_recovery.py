#!/usr/bin/env python3
"""Static contracts for durable KPM install journaling and recovery."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    target = ROOT / path
    if not target.is_file():
        raise AssertionError(f"missing required file: {path}")
    return target.read_text(encoding="utf-8")


def require(text: str, token: str, message: str) -> None:
    if token not in text:
        raise AssertionError(message)


def reject(text: str, token: str, message: str) -> None:
    if token in text:
        raise AssertionError(message)


def main() -> int:
    helper = read("module/kpm_install_recovery.sh")
    installer = read("module/install_kpm.sh")
    customize = read("module/customize.sh")
    runner = read("scripts/run_offline_checks.sh")

    require(customize, "kpm_install_recovery.sh", "package validation omits durable install recovery")
    require(installer, '. "$MODDIR/kpm_install_recovery.sh"', "installer does not load recovery helper")
    require(installer, "patchnest_acquire_install_lock", "installer does not recover stale state before locking")
    require(installer, "patchnest_release_install_lock", "installer does not release its owned lock")
    require(installer, "Cannot recover stale KPM installation state", "stale recovery failure is not surfaced")

    states = ["preparing", "backup", "writing", "complete"]
    positions: list[int] = []
    for state in states:
        token = f'patchnest_write_install_journal "$STAGE_DIR" {state} "$MOD_ID"'
        require(installer, token, f"installer does not record {state} journal state")
        positions.append(installer.index(token))
    if positions != sorted(positions) or len(set(positions)) != len(positions):
        raise AssertionError("install journal phases are not ordered preparing -> backup -> writing -> complete")

    require(installer, "COMMIT_STARTED=true", "normal-error rollback has no transaction start boundary")
    require(installer, "COMMIT_WRITING=true", "normal-error rollback has no write boundary")
    require(installer, "COMMIT_COMPLETE=true", "normal cleanup cannot distinguish a committed install")
    require(installer, "rollback_install", "normal failure rollback is missing")
    reject(installer, 'mkdir "$LOCK_DIR"', "installer bypasses durable lock acquisition")
    reject(installer, 'rmdir "$LOCK_DIR"', "installer bypasses owned lock release")

    for token, message in (
        ("patchnest_recover_install_stage", "single-stage recovery API is missing"),
        ("patchnest_recover_abandoned_installs", "abandoned-stage scan is missing"),
        ("patchnest_install_lock_active", "active lock detection is missing"),
        ("patchnest_write_install_journal", "journal writer is missing"),
        ("patchnest_remove_destinations", "interrupted writes cannot remove partial new files"),
        ("patchnest_restore_previous_set", "interrupted transactions cannot restore old files"),
        ("removed abandoned preparing stage", "preparing recovery is not observable"),
        ("restored partial backup stage", "backup recovery is not observable"),
        ("rolled back interrupted write stage", "writing recovery is not observable"),
        ("removed committed stale stage", "complete-stage cleanup is not observable"),
        ('"$PATCHNEST_STATE_DIR"/.kpm-stage.*', "stage recovery is not path-bound"),
        ("install_kpm.sh", "lock ownership is not tied to the installer process"),
    ):
        require(helper, token, message)

    reject(helper, "eval ", "install recovery evaluates journal content")
    reject(helper, "source ", "install recovery executes journal content")
    require(runner, "tests/test_kpm_install_recovery.sh", "focused recovery vectors are not in the offline runner")

    print("Durable KPM install recovery contracts validated.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
