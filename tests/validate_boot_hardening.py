#!/usr/bin/env python3
"""Repository-level contracts for PatchNest boot hardening."""

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


def require_regex(text: str, pattern: str, message: str) -> None:
    if not re.search(pattern, text, re.MULTILINE):
        raise AssertionError(message)


def main() -> int:
    guard = read("module/patch/flash_guard.sh")
    target = read("module/patch/boot_target.sh")
    patch = read("module/patch/boot_patch.sh")
    unpatch = read("module/patch/boot_unpatch.sh")
    restore = read("module/patch/boot_restore_verified.sh")
    extract = read("module/patch/boot_extract.sh")
    post_fs = read("module/post-fs-data.sh")
    collector = read("scripts/collect_device_evidence.sh")
    unpatch_ui = read("webui/page/boot_unpatch.js")
    unpatch_model = read("webui/page/boot-unpatch-model.js")

    for script_name, script in {
        "boot_patch.sh": patch,
        "boot_unpatch.sh": unpatch,
        "boot_restore_verified.sh": restore,
        "boot_extract.sh": extract,
    }.items():
        require(script, '. "$MODPATH/flash_guard.sh"', f"{script_name} does not source flash_guard.sh")

    require(extract, '. "$MODPATH/boot_target.sh"', "boot discovery does not load the boot-only resolver")
    require(extract, "find_kernel_boot_image", "boot discovery still calls the broad upstream resolver")
    require(target, "find_kernel_boot_image", "boot-only discovery helper is missing")
    require(target, "assert_kernel_boot_target", "boot-only discovery does not validate its result")
    for forbidden in ("vendor_boot", "init_boot"):
        require(guard, forbidden, f"flash guard does not explicitly reject {forbidden}")
        if re.search(rf"(?m)^[^#\n]*find_block[^\n]*\b{forbidden}\b", target):
            raise AssertionError(f"boot-only resolver searches forbidden partition {forbidden}")

    require(guard, "PARTNAME=", "partition validation does not inspect sysfs PARTNAME")
    require(guard, "verify_block_image_prefix", "readback verification helper missing")
    require(guard, "blockdev --getsize64", "target capacity is not checked")
    require(guard, "blockdev --getro", "target read-only state is not checked")
    require(guard, "Flash readback verification failed", "readback mismatch is not surfaced")
    require(guard, "Character-device boot flashing is not verified and is disabled", "unverified NAND writes are not fail-closed")
    require(guard, "Saved image SHA256", "saved image copy is not digest-verified")
    require(guard, "partition_name_for_target", "logical partition resolution helper is missing")

    require(patch, "resolve_kpimg", "kpimg location is not resolved across module/tmp layouts")
    require(patch, '"$MODPATH/../bin/kpimg"', "installed kpimg path is not considered")
    require(patch, '"$PWD/kpimg"', "WebUI temporary kpimg path is not considered")
    require(patch, 'readlink -f "$_image"', "independent image validation does not use an absolute path")
    require(patch, "backup_sha256", "backup digest is absent from manifest")
    require(patch, "backup_verified", "backup verification state is absent from manifest")
    require(patch, "date +%Y%m%d%H%M%S", "backup name lacks second-level uniqueness")
    require_regex(patch, r"boot_backup_\$\{_stamp\}_\$\$\.img", "backup name lacks process-level uniqueness")
    require(patch, "validate_embedded_kpms", "embedded KPM verification helper missing")
    require(patch, "cannot be verified by kptools", "embedded KPM verification is not fail-closed")
    require(patch, "Patched boot image failed independent unpack verification", "repacked patch image is not independently validated")
    require(patch, "Patched kernel does not report patched=true", "patched kernel state is not checked")
    require(patch, "Refusing to replace recovery backup with an already patched boot image", "forced backup can replace recovery base with a patched image")
    reject(patch, "set -x", "boot patcher enables shell tracing and may expose a superkey")
    reject(patch, "(proceeding)", "unverified embedded KPMs still proceed")

    # Current-image unpatch is not a backup restore operation.
    require(unpatch, "FLASH_TO_DEVICE=${2:-true}", "unpatch lacks an explicit file-only mode")
    require(unpatch, "Successfully unpatched current image; output saved without flashing", "file-only unpatch does not preserve a verified output")
    require(unpatch, "rm -f kernel kernel.ori new-boot.img", "stale work artifacts are not removed")
    require(unpatch, 'readlink -f "$_image"', "unpatch validation does not use an absolute path")
    require(unpatch, "Generated kernel still reports patched=true", "unpatch output state is not checked")
    require(unpatch, "Unpatched boot image validation failed", "repacked unpatch image is not independently validated")
    require(unpatch, "Current boot image unpatched and read back successfully", "current-image unpatch does not require readback success")
    reject(unpatch, "BACKUP_DIR", "current-image unpatch still references the backup directory")
    reject(unpatch, "select_verified_backup", "current-image unpatch still auto-selects a backup")
    reject(unpatch, "auto_unpatch", "current-image unpatch still contains a backup-restore primitive")
    reject(unpatch, "backup_sha256", "current-image unpatch still parses backup integrity metadata")
    reject(unpatch, "backup_verified", "current-image unpatch still parses backup verification metadata")
    reject(unpatch, "ls -1t", "current-image unpatch still selects the newest backup")
    reject(unpatch, "if ! flash_image", "negated flash command can hide the original error code")

    # A WebUI module-load failure must not silently authorize a boot write.
    # The script boundary requires a one-time approval even if index.js falls
    # through to patchModule.patch("unpatch").
    require(unpatch, "require_flash_approval", "block-device unpatch has no approval gate")
    require(unpatch, "APPROVAL_MAX_AGE=120", "unpatch approval has no short expiry")
    require(unpatch, "PATCHNEST_UNPATCH_APPROVED", "explicit CLI approval path is missing")
    require(unpatch, "operation=current-image-unpatch", "approval is not operation-bound")
    require(unpatch, "Unpatch approval expired or has a future timestamp", "approval timestamp is not validated")
    require(unpatch, "rm -f \"$APPROVAL_FILE\" ||", "one-time approval is not consumed before work")
    require(unpatch, "require_flash_approval || exit 1", "approval failure does not stop the write path")
    approval_pos = unpatch.find("require_flash_approval || exit 1")
    unpack_pos = unpatch.find('magiskboot unpack "$BOOTIMAGE"')
    if approval_pos < 0 or unpack_pos < 0 or approval_pos > unpack_pos:
        raise AssertionError("unpatch approval is checked after boot-image processing starts")

    require(unpatch_ui, "createUnpatchApproval", "WebUI confirmation does not create one-time approval")
    require(unpatch_ui, "clearUnpatchApproval", "WebUI does not clear stale/cancelled approvals")
    require(unpatch_ui, "return false", "missing confirmation UI is not fail-closed")
    reject(unpatch_ui, "readLatestBackupInfo", "current-image unpatch UI still reads a backup plan")
    require(unpatch_model, "usesStoredBackup: false", "UI model still claims a stored backup is used")
    require(unpatch_model, "flashesStoredBackup: false", "UI model still claims a stored backup is flashed")
    require(unpatch_model, "preservesStoredBackups: true", "UI model does not preserve backup state")
    require(unpatch_model, "does not restore or flash any stored backup", "English copy does not state the backup boundary")
    require(unpatch_model, "不会选择、恢复或刷入任何已保存备份", "Chinese copy does not state the backup boundary")

    # Backup restoration is an explicit, exact-input operation. Validation is
    # the default; a write requires a separate CLI approval.
    require(restore, "FLASH_TO_DEVICE=${3:-false}", "restore does not default to validation-only mode")
    require(restore, '"$_backup_root"/boot_backup_*.img', "restore accepts backups outside the controlled directory")
    require(restore, "backup_verified", "restore does not require a verified manifest")
    require(restore, "boot_image", "restore does not bind the backup to a target partition")
    require(restore, "backup_file", "restore does not bind the manifest to the selected image")
    require(restore, "backup_sha256", "restore does not require the recorded digest")
    require(restore, "Backup target mismatch", "restore does not fail on a target mismatch")
    require(restore, "Selected backup SHA-256 does not match its manifest", "restore does not fail on a digest mismatch")
    require(restore, "validate_boot_image", "restore does not independently unpack the selected backup")
    require(restore, "PATCHNEST_RESTORE_APPROVED", "restore write lacks a separate explicit approval")
    require(restore, "Validation complete; no block device was written", "restore validation mode is not clearly non-writing")
    require(restore, "Verified backup restored and read back successfully", "restore write does not require readback success")
    require(restore, "No automatic backup selection was used", "restore does not state exact-input selection")
    reject(restore, "ls -1t", "restore auto-selects the newest backup")
    reject(restore, "latest backup", "restore contains newest/latest backup selection language")
    restore_approval_pos = restore.find("PATCHNEST_RESTORE_APPROVED")
    restore_flash_pos = restore.find('flash_image "$_backup_real" "$BOOTIMAGE"')
    if restore_approval_pos < 0 or restore_flash_pos < 0 or restore_approval_pos > restore_flash_pos:
        raise AssertionError("restore approval is checked after the block write starts")

    require(post_fs, '"automatic_flash_performed": false', "early-boot state incorrectly claims a restore occurred")
    require(post_fs, '"required_next_step": "select_target_bound_verified_backup"', "recovery request lacks its required verification step")
    reject(post_fs, "flash_image", "post-fs-data must not write a boot block device")

    require(collector, "/data/adb/patchnest/backup", "evidence collector ignores the current backup directory")
    require(collector, "No block device was written", "collector lacks an explicit read-only sharing notice")

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
