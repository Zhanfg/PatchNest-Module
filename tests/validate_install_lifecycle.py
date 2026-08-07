#!/usr/bin/env python3
"""Offline contracts for install, uninstall, KPM admission, and quarantine."""

from __future__ import annotations

import re
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
    customize = read("module/customize.sh")
    uninstall = read("module/uninstall.sh")
    post_fs = read("module/post-fs-data.sh")
    status = read("module/status.sh")
    installer = read("module/install_kpm.sh")
    transaction_store = read("module/kpm_transaction_store.sh")
    verifier = read("module/kpm_verify.sh")
    quarantine = read("module/manage_kpm_quarantine.sh")
    recovery_state = read("module/patch/recovery_state.sh")
    service = read("module/service.sh")

    reject(customize, 'rm -rf "$MODDIR/webroot"', "destructive self-copy hot update returned")
    reject(customize, 'cp -rf "$MODPATH/webroot"', "installer still recopies its active module directory")
    for token, message in (
        ("patch/flash_guard.sh", "package validation omits the flash guard"),
        ("patch/boot_target.sh", "package validation omits boot-only discovery"),
        ("patch/boot_restore_verified.sh", "package validation omits verified restore"),
        ("patch/kptools_argv.sh", "package validation omits argv normalization"),
        ("patch/recovery_state.sh", "package validation omits recovery monitoring state"),
        ("kpm_transaction_store.sh", "package validation omits shared KPM transactions"),
        ("manage_kpm_quarantine.sh", "package validation omits quarantine management"),
        ("module.prop.bak", "validated module metadata backup is not created"),
        ("KPM_SIGNATURE_POLICY=strict", "new installs do not default to strict signatures"),
        ('if [ ! -e "$STATE_DIR/config" ]', "upgrade can overwrite an existing signature policy"),
    ):
        require(customize, token, message)

    reject(uninstall, "rm -rf /data/adb/patchnest", "uninstall deletes persistent recovery state")
    require(uninstall, "Verified boot backups", "uninstall does not explain retained backups")
    require(uninstall, "did not flash or unpatch", "uninstall incorrectly implies boot restoration")

    for token, message in (
        ("patchnest_store_kpm_transaction", "shared transaction API is missing"),
        ("patchnest_valid_transaction_root", "transaction destinations are not constrained"),
        ("patchnest_valid_transaction_reason", "transaction reasons are not constrained"),
        ("unsigned-strict", "strict unsigned failures are unsupported"),
        ("invalid-signature", "signature failures are unsupported"),
        ("load-failed", "runtime load failures are unsupported"),
        ("patchnest_restore_moved_sidecar", "failed transactions cannot restore sidecars"),
        ("checksums.sha256", "shared transaction store lacks integrity metadata"),
        ("state=staging", "shared transaction store lacks an incomplete state"),
        ("state=complete", "shared transaction store never finalizes"),
    ):
        require(transaction_store, token, message)
    reject(transaction_store, "eval ", "shared transaction store evaluates untrusted input")

    for token, message in (
        ('. "$MODDIR/kpm_transaction_store.sh"', "post-fs does not load the shared transaction store"),
        ("store_admission_transaction", "post-fs has no shared-store wrapper"),
        ('"$KPM_DIR"/*.ko "$KPM_DIR"/*.o', "Linux objects are not rejected before service"),
        ('"$KPM_EVENT_DIR/${_name}.autoload"', "autoload is not enforced before service"),
        ('[ -L "$KPM_EVENT_DIR/${_name}.autoload" ]', "autoload symlinks are accepted"),
        ("signature policy symlink removed", "signature-policy symlinks are not rejected"),
        ("non-kpm-object", "non-KPM transaction reason is not recorded"),
        ("autoload-disabled", "autoload quarantine reason is not recorded"),
        ("signature-policy-unavailable", "policy-failure reason is not recorded"),
    ):
        require(post_fs, token, message)
    reject(post_fs, "move_with_sidecars", "post-fs still has a duplicate transaction implementation")
    reject(post_fs, "manifest.properties.tmp", "post-fs still writes transaction manifests directly")
    reject(post_fs, "checksums.sha256.tmp", "post-fs still writes transaction checksums directly")

    for token, message in (
        ("KPM_SIGNATURE_POLICY=strict", "service signature policy is not fail-closed"),
        ('for _object in "$KPM_DIR"/*.ko "$KPM_DIR"/*.o', "service does not reject late Linux objects"),
        ('for kpm in "$KPM_DIR"/*.kpm', "service does not use a KPM-only load loop"),
        ('"$KPM_EVENT_DIR/${mod_basename}.autoload"', "service does not require autoload"),
        ("kpm_transaction_store.sh", "service does not load the shared transaction store"),
        ("store_transaction", "service failure storage wrapper is missing"),
        ("unsigned-strict", "strict unsigned KPMs are not transactionally stored"),
        ("invalid-signature", "invalid signatures are not transactionally stored"),
        ("load-failed", "load failures are not transactionally stored"),
        ("signature verifier unavailable; leaving signed KPM for retry", "missing verifier does not fail closed"),
        ("exclusion config exceeds 1 MiB", "service exclusion input is unbounded"),
    ):
        require(service, token, message)
    reject(service, '"$KPM_DIR/failed/', "service still performs legacy flat failure moves")
    reject(service, 'mv "$kpm"', "service still moves only the primary KPM")
    reject(service, "KPM_SIGNATURE_POLICY=off", "service defaults signature verification off")

    for token, message in (
        ('. "$MODDIR/patch/recovery_state.sh"', "post-fs does not load recovery state helpers"),
        ("patchnest_recovery_monitoring_suspended", "post-fs ignores intentional monitoring suspension"),
        ("recovery monitoring remains suspended", "suspended boot is not recorded"),
        ("invalid recovery suspension state removed", "invalid suspension does not restore normal monitoring"),
        ('"monitoring_suspended": false', "normal recovery state omits monitoring status"),
    ):
        require(post_fs, token, message)

    for token, message in (
        ("current-image-unpatched", "unpatch suspension reason is unsupported"),
        ("verified-backup-restored", "restore suspension reason is unsupported"),
        ('"monitoring_suspended": true', "suspended state is not represented"),
        ('"required_next_step": "repatch_or_remove_module"', "suspension state lacks remediation"),
        ("patchnest_resume_recovery_monitoring", "recovery monitoring cannot resume"),
    ):
        require(recovery_state, token, message)

    require(status, "awk -v key=", "status uses delimiter-sensitive replacement")
    reject(status, 'sed "s|^$prop=', "pipe-delimited sed update returned")
    require(status, "mark_boot_healthy", "healthy boot does not resolve recovery state")
    require(status, '. "$MODDIR/patch/recovery_state.sh"', "healthy status does not load recovery state helper")
    require(status, "patchnest_resume_recovery_monitoring", "healthy status does not resume monitoring")
    require(status, "healthy-kpatch-hello", "healthy status lacks an explicit resolution")

    for token, message in (
        ('"$MODDIR"/tmp/*', "WebUI upload staging path is not accepted"),
        ("ZIP exceeds 64 MiB", "compressed ZIP size is unbounded"),
        ("unzip -Z1", "ZIP entries are not preflighted"),
        ("ZIP contains duplicate entry", "duplicate ZIP paths are not rejected"),
        ("Declared ZIP extraction exceeds 32 MiB", "declared extraction size is not bounded"),
        ("ZIP contains symbolic links", "symbolic links are not rejected"),
        ("Extracted ZIP exceeds 32 MiB", "actual extracted size is not rechecked"),
        ("load_optional_prop", "optional metadata is not checked in the parent shell"),
        ("module.prop contains duplicate key", "duplicate metadata keys are accepted"),
        ("module.prop is missing required key: id", "required module id is not enforced"),
        ("Linux .ko/.o files are not KernelPatch KPM artifacts", "Linux objects are accepted"),
        ("On-device KPM source compilation is disabled; provide one prebuilt .kpm", "source packages are not rejected"),
        ("ZIP must contain exactly one prebuilt KPM binary", "ambiguous KPM packages are accepted"),
        ("ZIP contains multiple signature files for the KPM", "multiple matching signatures are accepted"),
        ("ZIP contains a signature file that does not match the KPM", "unrelated signature files are accepted"),
        ("KPM binary failed kptools validation", "binary parsing is not required"),
        ("KPM signature verification failed", "invalid supplied signatures are not fatal"),
        ("Unsigned KPM prepared with autoload disabled", "unsigned KPM can request autoload"),
        ("Signed KPM installed; reboot required before loading", "new signed KPMs do not use reboot-only activation"),
        ("Another KPM installation is already running", "concurrent installs are not serialized"),
        (".kpm-stage.$$", "installation is not staged"),
        ('ZIP_NAME="${MOD_ID}.zip"', "retained ZIP does not use its final filename"),
        ('sha256sum "$ZIP_NAME" >"$ZIP_DIGEST_NAME"', "staged ZIP digest is not final-name bound"),
        ('sha256sum -c "$ZIP_DIGEST_NAME"', "installed ZIP digest is not rechecked"),
        ("Installed ZIP does not match its retained digest", "final ZIP mismatch is not fatal"),
    ):
        require(installer, token, message)

    for token, message in (
        ("rollback_install", "KPM update has no rollback routine"),
        ("COMMIT_STARTED", "KPM update has no transaction start state"),
        ("COMMIT_WRITING", "KPM update cannot distinguish backup and write phases"),
        ("COMMIT_COMPLETE", "KPM update has no commit completion state"),
        ("move_existing_to_previous", "existing persistent state is not preserved"),
        ("Persistent KPM state rolled back after failed install", "rollback is not observable"),
        ("KPM install rollback was incomplete", "incomplete rollback is not surfaced"),
        ("Signed KPM update installed; reboot required before loading", "updates can hot-load over an existing KPM"),
        ("Cannot finalize durable KPM install journal", "journal finalization failure is not fatal"),
        ('mv "$STAGE_DIR/module.kpm" "$DEST_KPM"', "binary is not committed from staging"),
    ):
        require(installer, token, message)

    for forbidden, message in (
        ('ARGS_OPT="-- $MOD_ARGS"', "unquoted argument concatenation returned"),
        ('"$MODDIR/compile_kpm.sh" "$TMPDIR/root"', "installer invokes on-device source compilation"),
        ("Compiled KPM failed kptools validation", "old source-compilation path returned"),
        ('sha256sum "$STAGE_DIR/source.zip"', "digest still records a staging path"),
        ('kpatch kpm load "$DEST_KPM"', "installer can mutate kernel state before transaction completion"),
        ("MOD_NAME=$(read_optional_prop", "optional metadata failure can be swallowed by command substitution"),
    ):
        reject(installer, forbidden, message)

    for token, message in (
        ("list_entries", "read-only listing is missing"),
        ("inspect_scope_entry", "scoped read-only inspection is missing"),
        ("activate_entry", "verified activation is missing"),
        ("verify_entry_checksums", "transaction checksums are not verified"),
        ("sha256sum -c checksums.sha256", "digest set is not checked"),
        ("is_allowed_transaction_name", "unknown files are not rejected"),
        ("Quarantine transaction checksum verification failed", "tampering is not fatal"),
        ("Staged quarantine transaction checksum verification failed", "copied transaction is not reverified"),
        ("Transaction changed during activation", "activation has no TOCTOU detection"),
        ("Only quarantined .kpm transactions can be activated", "non-KPM transaction can activate"),
        ("Quarantined KPM failed kptools validation", "activation skips KPM parsing"),
        ("Quarantined KPM signature is invalid", "activation skips signature verification"),
        ("Live KPM already exists", "activation can overwrite a live KPM"),
        ("Activation commit failed and was rolled back", "activation lacks rollback"),
        (".quarantine-manager.lock", "activation is not serialized"),
        ("Reboot to load it through the normal admission path", "activation bypasses normal admission"),
    ):
        require(quarantine, token, message)
    reject(quarantine, "eval ", "quarantine manager evaluates manifest content")
    reject(quarantine, "--force", "quarantine manager exposes force overwrite")
    if re.search(r"(?m)^\s*delete\)", quarantine):
        raise AssertionError("quarantine manager exposes destructive delete")

    for token, message in (
        ("302a300506032b6570032100", "Ed25519 SPKI prefix is missing"),
        ("openssl pkeyutl", "pkeyutl is not used"),
        ("-pubin", "public-key mode is missing"),
        ("-keyform DER", "DER key parsing is missing"),
        ("-rawin", "raw-message mode is missing"),
        ("-sigfile", "signature file is not supplied"),
        ("signature file exceeds 4096 bytes", "signature input is unbounded"),
        ("signature file must contain exactly one non-empty line", "ambiguous signature text is accepted"),
        ("mktemp -d", "private unpredictable temp directory is missing"),
    ):
        require(verifier, token, message)
    reject(verifier, "openssl dgst -ed25519", "broken raw-key dgst verification returned")
    reject(verifier, 'mkdir -p "$_tmpdir"', "predictable temp fallback returned")
    reject(verifier, "trap '", "sourced verifier replaces caller traps")

    if re.search(r'case "\$_resolved" in[\s\S]*?\*/data/local/tmp', installer):
        raise AssertionError("trusted KPM source path pattern is not rooted")

    print("Install and KPM lifecycle contracts validated.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
