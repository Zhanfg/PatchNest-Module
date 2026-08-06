#!/usr/bin/env python3
"""Repository-level contracts for PatchNest boot hardening.

Run from any directory:

    python3 tests/validate_boot_hardening.py

No device, root permission, network, or GitHub Actions runner is required.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        raise AssertionError(f"missing required file: {relative}")
    return path.read_text(encoding="utf-8")


def require(text: str, token: str, message: str) -> None:
    if token not in text:
        raise AssertionError(message)


def reject(text: str, token: str, message: str) -> None:
    if token in text:
        raise AssertionError(message)


def main() -> int:
    guard = read("module/patch/flash_guard.sh")
    patch = read("module/patch/boot_patch.sh")
    unpatch = read("module/patch/boot_unpatch.sh")
    extract = read("module/patch/boot_extract.sh")

    for script_name, script in {
        "boot_patch.sh": patch,
        "boot_unpatch.sh": unpatch,
        "boot_extract.sh": extract,
    }.items():
        require(script, '. "$MODPATH/flash_guard.sh"', f"{script_name} does not source flash_guard.sh")

    for forbidden in (
        "vendor_boot",
        "init_boot",
    ):
        require(guard, forbidden, f"flash guard does not explicitly reject {forbidden}")

    require(guard, "PARTNAME=", "partition validation does not inspect sysfs PARTNAME")
    require(guard, "verify_block_image_prefix", "readback verification helper missing")
    require(guard, "blockdev --getsize64", "target size check missing")
    require(guard, "blockdev --getro", "read-only check missing")
    require(guard, "Flash readback verification failed", "readback mismatch is not surfaced")
    require(guard, "Character-device boot flashing is not verified and is disabled", "unverified NAND writes are not fail-closed")
    require(guard, "Saved image SHA256", "saved image copy is not digest-verified")

    require(patch, "backup_sha256", "backup digest is absent from manifest")
    require(patch, "backup_verified", "backup verification state is absent from manifest")
    require(patch, "date +%Y%m%d%H%M%S", "backup name lacks second-level uniqueness")
    require(patch, "_$$.img", "backup name lacks process-level uniqueness")
    require(patch, "validate_embedded_kpms", "embedded KPM verification helper missing")
    require(patch, "cannot be verified by kptools", "embedded KPM verification is not fail-closed")
    require(patch, "Patched boot image failed independent unpack verification", "repacked patch image is not independently validated")
    require(patch, "Patched kernel does not report patched=true", "patched kernel state is not checked")
    reject(patch, "set -x", "boot patcher enables shell tracing and may expose a superkey")
    reject(patch, "(proceeding)", "unverified embedded KPMs still proceed")

    require(unpatch, "rm -f kernel kernel.ori new-boot.img", "stale work artifacts are not removed")
    require(unpatch, "select_verified_backup", "verified backup selection helper missing")
    require(unpatch, "backup_sha256", "recovery does not enforce backup digest")
    require(unpatch, "backup_verified", "recovery does not enforce verification state")
    require(unpatch, "Generated kernel still reports patched=true", "unpatch output state is not checked")
    require(unpatch, "Unpatched boot image validation failed", "repacked unpatch image is not independently validated")
    require(unpatch, "Flash successful and verified", "unpatch does not require readback verification")
    reject(unpatch, "found backup boot.img", "stale new-boot.img recovery branch remains")

    require(extract, "assert_kernel_boot_target", "boot discovery result is not checked")
    require(extract, "Discovered partition is not a supported KernelPatch boot target", "invalid target error is missing")

    # Guard against accidental reintroduction of minute-only backup names.
    if re.search(r"date \+%[yY][^\n]*%M(?![^\n]*%S)", patch):
        raise AssertionError("minute-only backup timestamp reintroduced")

    print("Boot hardening contracts validated.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
