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
    verifier = read("module/kpm_verify.sh")
    quarantine = read("module/manage_kpm_quarantine.sh")
    recovery_state = read("module/patch/recovery_state.sh")
    service = read("module/service.sh")

    # Package installation and persistent-state boundaries.
    reject(customize, 'rm -rf "$MODDIR/webroot"', "destructive self-copy hot update returned")
    reject(customize, 'cp -rf "$MODPATH/webroot"', "installer still recopies its active module directory")
    for token, message in (
        ("patch/flash_guard.sh", "package validation omits the flash guard"),
        ("patch/boot_target.sh", "package validation omits boot-only discovery"),
        ("patch/boot_restore_verified.sh", "package validation omits verified restore"),
        ("patch/kptools_argv.sh", "package validation omits argv normalization"),
        ("patch/recovery_state.sh", "package validation omits recovery monitoring state"),
        ("manage_kpm_quarantine.sh", "package validation omits quarantine management"),
        ("module.prop.bak", "validated module metadata backup is not created"),
        ("KPM_SIGNATURE_POLICY=strict", "new installs do not default to strict signatures"),
        ('if [ ! -e "$STATE_DIR/config" ]', "upgrade can overwrite an existing signature policy"),
    ):
        require(customize, token, message)

    reject(uninstall, "rm -rf /data/adb/patchnest", "uninstall deletes persistent recovery state")
    require(uninstall, "Verified boot backups", "uninstall does not explain retained backups")
    require(uninstall, "did not flash or unpatch", "uninstall incorrectly implies boot restoration")

    # The legacy service loop is broad; post-fs-data must reduce the live set.
    require(service, '"$KPM_DIR"/*.kpm "$KPM_DIR"/*.ko "$KPM_DIR"/*.o', "service scan changed; review admission assumptions")
    for token, message in (
        ("kpm_quarantine", "non-autoload modules are not quarantined"),
        ('"$KPM_EVENT_DIR/${_name}.autoload"', "autoload is not enforced before service"),
        ('"$KPM_DIR"/*.ko "$KPM_DIR"/*.o', "Linux objects are not rejected before service"),
        ("move_with_sidecars", "quarantine loses sidecars"),
        ("state=staging", "transaction has no incomplete state"),
        ("state=complete", "transaction is never finalized"),
        ("manifest.properties", "transaction manifest is missing"),
        ("checksums.sha256", "transaction checksum set is missing"),
        ("sha256sum", "transaction files are not hashed"),
        ("_safe_source", "source names are not sanitized"),
        ("module.kpm.sig", "signature is not stored with its transaction"),
        ("autoload-disabled", "autoload quarantine reason is not recorded"),
        ("signature-policy-unavailable", "policy-failure reason is not recorded"),
    ):
        require(post_fs, token, message)

    # Intentional unpatch/restore must not be counted as repeated patch failures.
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

    # Status updates must tolerate pipe characters and clear suspension after a
    # confirmed healthy kernel handshake.
    require(status, "awk -v key=", "status uses delimiter-sensitive replacement")
    reject(status, 'sed "s|^$prop=', "pipe-delimited sed update returned")
    require(status, "mark_boot_healthy", "healthy boot does not resolve recovery state")
    require(status, '. "$MODDIR/patch/recovery_state.sh"', "healthy status does not load recovery state helper")
    require(status, "patchnest_resume_recovery_monitoring", "healthy status does not resume monitoring")
    require(status, "healthy-kpatch-hello", "healthy status lacks an explicit resolution")

    # KPM package admission: exact prebuilt artifact, bounded ZIP, verified digest.
    for token, message in (
        ('"$MODDIR"/tmp/*', "WebUI upload staging path is not accepted"),
        ("unzip -Z1", "ZIP entries are not preflighted"),
        ("ZIP contains symbolic links", "symbolic links are not rejected"),
        ("Extracted ZIP exceeds 32 MiB", "extracted-size bound is missing"),
        ("Linux .ko/.o files are not KernelPatch KPM artifacts", "Linux objects are accepted"),
        ("On-device KPM source compilation is disabled; provide one prebuilt .kpm", "source packages are not rejected"),
        ("ZIP must contain exactly one prebuilt KPM binary", "ambiguous KPM packages are accepted"),
        ("KPM binary failed kptools validation", "binary parsing is not required"),
        ("KPM signature verification failed", "invalid supplied signatures are not fatal"),
        ("Unsigned KPM prepared with autoload disabled", "unsigned KPM can request autoload"),
        ('kpatch kpm load "$DEST_KPM" -- "$MOD_ARGS"', "immediate-load args are not one argv value"),
        ("Another KPM installation is already running", "concurrent installs are not serialized"),
        (".kpm-stage.$$", "installation is not staged"),
        ('mv "$STAGE_DIR/module.kpm" "$DEST_KPM"', "binary is not committed last"),
        ('ZIP_NAME="${MOD_ID}.zip"', "retained ZIP does not use its final filename"),
        ('sha256sum "$ZIP_NAME" >"$ZIP_DIGEST_NAME"', "staged ZIP digest is not final-name bound"),
        ('sha256sum -c "$ZIP_DIGEST_NAME"', "installed ZIP digest is not rechecked"),
        ("Installed ZIP does not match its retained digest", "final ZIP mismatch is not fatal"),
    ):
        require(installer, token, message)
    for forbidden, message in (
        ('ARGS_OPT="-- $MOD_ARGS"', "unquoted argument concatenation returned"),
        ('"$MODDIR/compile_kpm.sh" "$TMPDIR/root"', "installer invokes on-device source compilation"),
        ("Compiled KPM failed kptools validation", "old source-compilation path returned"),
        ('sha256sum "$STAGE_DIR/source.zip"', "digest still records a staging path"),
    ):
        reject(installer, forbidden, message)

    # Quarantine activation is recovery-oriented, signed, checksummed, and no-overwrite.
    for token, message in (
        ("list_entries", "read-only listing is missing"),
        ("inspect_entry", "read-only inspection is missing"),
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

    # Ed25519 verifier must use RFC 8410 DER and pkeyutl raw-message verification.
    for token, message in (
        ("302a300506032b6570032100", "Ed25519 SPKI prefix is missing"),
        ("openssl pkeyutl", "pkeyutl is not used"),
        ("-pubin", "public-key mode is missing"),
        ("-keyform DER", "DER key parsing is missing"),
        ("-rawin", "raw-message mode is missing"),
        ("-sigfile", "signature file is not supplied"),
        ("signature file exceeds 4096 bytes", "signature input is unbounded"),
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
