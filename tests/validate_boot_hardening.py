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
    recovery_state = read("module/patch/recovery_state.sh")
    extract = read("module/patch/boot_extract.sh")
    post_fs = read("module/post-fs-data.sh")
    status = read("module/status.sh")
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

    for token, message in (
        ("PARTNAME=", "partition validation does not inspect sysfs PARTNAME"),
        ("verify_block_image_prefix", "readback verification helper missing"),
        ("blockdev --getsize64", "target capacity is not checked"),
        ("blockdev --getro", "target read-only state is not checked"),
        ("Flash readback verification failed", "readback mismatch is not surfaced"),
        ("Character-device boot flashing is not verified and is disabled", "unverified NAND writes are not fail-closed"),
        ("Saved image SHA256", "saved image copy is not digest-verified"),
        ("partition_name_for_target", "logical partition resolution helper is missing"),
    ):
        require(guard, token, message)

    for token, message in (
        ("resolve_kpimg", "kpimg location is not resolved"),
        ('"$MODPATH/../bin/kpimg"', "installed kpimg path is not considered"),
        ('"$PWD/kpimg"', "WebUI temporary kpimg path is not considered"),
        ('readlink -f "$_image"', "independent image validation does not use an absolute path"),
        ("backup_sha256", "backup digest is absent from manifest"),
        ("backup_verified", "backup verification state is absent from manifest"),
        ("date +%Y%m%d%H%M%S", "backup name lacks second-level uniqueness"),
        ("validate_embedded_kpms", "embedded KPM verification helper missing"),
        ("cannot be verified by kptools", "embedded KPM verification is not fail-closed"),
        ("Patched boot image failed independent unpack verification", "repacked patch image is not independently validated"),
        ("Patched kernel does not report patched=true", "patched kernel state is not checked"),
        ("Refusing to replace recovery backup with an already patched boot image", "forced backup can replace recovery base"),
    ):
        require(patch, token, message)
    require_regex(patch, r"boot_backup_\$\{_stamp\}_\$\$\.img", "backup name lacks process-level uniqueness")
    reject(patch, "set -x", "boot patcher enables shell tracing and may expose a superkey")
    reject(patch, "(proceeding)", "unverified embedded KPMs still proceed")

    # Current-image unpatch is not a backup restore operation.
    for token, message in (
        ("FLASH_TO_DEVICE=${2:-true}", "unpatch lacks an explicit file-only mode"),
        ("Successfully unpatched current image; output saved without flashing", "file-only unpatch does not preserve verified output"),
        ("rm -f kernel kernel.ori new-boot.img", "stale work artifacts are not removed"),
        ('readlink -f "$_image"', "unpatch validation does not use an absolute path"),
        ("Generated kernel still reports patched=true", "unpatch output state is not checked"),
        ("Unpatched boot image validation failed", "repacked unpatch image is not independently validated"),
        ("Current boot image unpatched and read back successfully", "unpatch does not require readback success"),
        ('. "$MODPATH/recovery_state.sh"', "unpatch does not load recovery state helpers"),
        ("patchnest_suspend_recovery_monitoring current-image-unpatched", "unpatch does not suspend failed-boot monitoring"),
    ):
        require(unpatch, token, message)
    for forbidden, message in (
        ("BACKUP_DIR", "current-image unpatch still references the backup directory"),
        ("select_verified_backup", "current-image unpatch still auto-selects a backup"),
        ("auto_unpatch", "current-image unpatch still contains restore behavior"),
        ("backup_sha256", "current-image unpatch still parses backup integrity metadata"),
        ("backup_verified", "current-image unpatch still parses backup verification metadata"),
        ("ls -1t", "current-image unpatch still selects the newest backup"),
        ("if ! flash_image", "negated flash command can hide the original error code"),
    ):
        reject(unpatch, forbidden, message)

    # Missing lazy UI modules must not silently authorize a boot write.
    for token, message in (
        ("require_flash_approval", "block-device unpatch has no approval gate"),
        ("APPROVAL_MAX_AGE=120", "unpatch approval has no short expiry"),
        ("PATCHNEST_UNPATCH_APPROVED", "explicit CLI approval path is missing"),
        ("operation=current-image-unpatch", "approval is not operation-bound"),
        ("Unpatch approval expired or has a future timestamp", "approval timestamp is not validated"),
        ('rm -f "$APPROVAL_FILE" ||', "one-time approval is not consumed before work"),
        ("require_flash_approval || exit 1", "approval failure does not stop the write path"),
    ):
        require(unpatch, token, message)
    approval_pos = unpatch.find("require_flash_approval || exit 1")
    unpack_pos = unpatch.find('magiskboot unpack "$BOOTIMAGE"')
    if approval_pos < 0 or unpack_pos < 0 or approval_pos > unpack_pos:
        raise AssertionError("unpatch approval is checked after boot processing starts")

    for token, message in (
        ("createUnpatchApproval", "WebUI confirmation does not create one-time approval"),
        ("clearUnpatchApproval", "WebUI does not clear stale/cancelled approvals"),
        ('approval_tmp="${approval_file}.tmp.$$"', "WebUI approval staging path is not process-unique"),
        ("trap 'rm -f", "WebUI approval staging file lacks cleanup"),
        ("return false", "missing confirmation UI is not fail-closed"),
    ):
        require(unpatch_ui, token, message)
    reject(unpatch_ui, "readLatestBackupInfo", "current-image unpatch UI still reads a backup plan")
    for token, message in (
        ("usesStoredBackup: false", "UI model still claims a stored backup is used"),
        ("flashesStoredBackup: false", "UI model still claims a stored backup is flashed"),
        ("preservesStoredBackups: true", "UI model does not preserve backup state"),
        ("does not restore or flash any stored backup", "English copy omits the backup boundary"),
        ("不会选择、恢复或刷入任何已保存备份", "Chinese copy omits the backup boundary"),
    ):
        require(unpatch_model, token, message)

    # Backup restoration is exact-input and validation-only by default.
    for token, message in (
        ("FLASH_TO_DEVICE=${3:-false}", "restore does not default to validation-only"),
        ('"$_backup_root"/boot_backup_*.img', "restore accepts backups outside the controlled directory"),
        ("backup_verified", "restore does not require a verified manifest"),
        ("boot_image", "restore does not bind the backup to a target partition"),
        ("backup_file", "restore does not bind the manifest to the selected image"),
        ("backup_sha256", "restore does not require the recorded digest"),
        ("Backup target mismatch", "restore does not fail on target mismatch"),
        ("Selected backup SHA-256 does not match its manifest", "restore does not fail on digest mismatch"),
        ("validate_boot_image", "restore does not independently unpack the selected backup"),
        ("PATCHNEST_RESTORE_APPROVED", "restore write lacks separate approval"),
        ("Validation complete; no block device was written", "restore validation mode is not non-writing"),
        ("Verified backup restored and read back successfully", "restore does not require readback success"),
        ("No automatic backup selection was used", "restore does not state exact-input selection"),
        ('. "$MODPATH/recovery_state.sh"', "restore does not load recovery state helpers"),
        ("patchnest_suspend_recovery_monitoring verified-backup-restored", "restore does not suspend failed-boot monitoring"),
    ):
        require(restore, token, message)
    reject(restore, "ls -1t", "restore auto-selects the newest backup")
    reject(restore, "latest backup", "restore contains latest-backup selection language")
    restore_gate = '[ "${PATCHNEST_RESTORE_APPROVED:-0}" = "1" ]'
    restore_approval_pos = restore.find(restore_gate)
    restore_flash_pos = restore.find('flash_image "$_backup_real" "$BOOTIMAGE"')
    if restore_approval_pos < 0 or restore_flash_pos < 0 or restore_approval_pos > restore_flash_pos:
        raise AssertionError("restore approval is checked after the block write starts")

    # Monitoring is suspended after intentional removal and resumed by health.
    for token, message in (
        ("current-image-unpatched", "unpatch suspension reason is unsupported"),
        ("verified-backup-restored", "restore suspension reason is unsupported"),
        ('"monitoring_suspended": true', "suspension state is not represented"),
        ('"required_next_step": "repatch_or_remove_module"', "suspension lacks remediation"),
        ("patchnest_resume_recovery_monitoring", "monitoring cannot resume"),
    ):
        require(recovery_state, token, message)
    require(post_fs, '. "$MODDIR/patch/recovery_state.sh"', "post-fs does not load recovery state helpers")
    require(post_fs, "patchnest_recovery_monitoring_suspended", "post-fs ignores intentional suspension")
    require(post_fs, "recovery monitoring remains suspended", "suspended boot is not recorded")
    require(status, "patchnest_resume_recovery_monitoring", "healthy status does not resume monitoring")
    require(status, "healthy-kpatch-hello", "healthy status lacks a resolution")

    require(post_fs, '"automatic_flash_performed": false', "early boot incorrectly claims a restore occurred")
    require(post_fs, '"required_next_step": "select_target_bound_verified_backup"', "recovery request lacks verification step")
    reject(post_fs, "flash_image", "post-fs-data must not write a boot block device")

    require(collector, "/data/adb/patchnest/backup", "evidence collector ignores the backup directory")
    require(collector, "No block device was written", "collector lacks a read-only sharing notice")

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
