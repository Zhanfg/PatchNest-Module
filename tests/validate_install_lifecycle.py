#!/usr/bin/env python3
"""Offline contracts for module install, uninstall, KPM admission, and status."""

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
    service = read("module/service.sh")

    # The installer framework owns MODPATH. Never clear a fixed module path and
    # copy from a potentially identical source directory.
    reject(customize, 'rm -rf "$MODDIR/webroot"', "destructive self-copy hot update returned")
    reject(customize, 'cp -rf "$MODPATH/webroot"', "installer still recopies its active module directory")
    require(customize, "patch/flash_guard.sh", "package validation omits the flash guard")
    require(customize, "patch/boot_target.sh", "package validation omits boot-only discovery")
    require(customize, "module.prop.bak", "validated module metadata backup is not created")
    require(customize, "KPM_SIGNATURE_POLICY=strict", "new installations do not default to strict KPM signatures")
    require(customize, 'if [ ! -e "$STATE_DIR/config" ]', "installer may overwrite existing KPM signature policy")

    # Module removal must not destroy the only verified boot recovery material.
    reject(uninstall, "rm -rf /data/adb/patchnest", "uninstall deletes persistent recovery state")
    require(uninstall, "Verified boot backups", "uninstall notice does not explain retained recovery data")
    require(uninstall, "did not flash or unpatch", "uninstall incorrectly implies boot restoration")

    # service.sh currently scans broadly, so post-fs-data must narrow the live
    # directory before service starts.
    require(service, '"$KPM_DIR"/*.kpm "$KPM_DIR"/*.ko "$KPM_DIR"/*.o', "expected broad legacy service scan changed; review admission assumptions")
    require(post_fs, "kpm_quarantine", "non-autoload modules are not quarantined")
    require(post_fs, '"$KPM_EVENT_DIR/${_name}.autoload"', "autoload marker is not enforced before service")
    require(post_fs, '"$KPM_DIR"/*.ko "$KPM_DIR"/*.o', "Linux objects are not rejected before KPM loading")
    require(post_fs, "move_with_sidecars", "KPM quarantine loses associated metadata/signatures")

    # Status updates must accept descriptions containing pipes and must resolve
    # stale recovery-request state after a confirmed healthy kernel handshake.
    require(status, "awk -v key=", "status still relies on a delimiter-sensitive sed replacement")
    reject(status, 'sed "s|^$prop=', "pipe-delimited sed status update returned")
    require(status, "mark_boot_healthy", "healthy boot does not resolve recovery state")
    require(status, '"recovery_requested": false', "healthy state does not clear recovery request")
    require(status, '"resolution": "healthy_kpatch_hello"', "healthy state lacks an explicit resolution")

    # KPM ZIP admission and installation contracts.
    require(installer, '"$MODDIR"/tmp/*', "WebUI upload staging path is not accepted")
    require(installer, "unzip -Z1", "ZIP entries are not preflighted before extraction")
    require(installer, "ZIP contains symbolic links", "symbolic-link entries are not rejected")
    require(installer, "Extracted ZIP exceeds 32 MiB", "extracted-size limit is missing")
    require(installer, "Linux .ko/.o files are not KernelPatch KPM artifacts", "Linux objects are accepted as KPMs")
    require(installer, "ZIP contains multiple KPM binaries", "multi-binary archives are not rejected")
    require(installer, "KPM binary failed kptools validation", "binary KPM validation is missing")
    require(installer, "Compiled KPM failed kptools validation", "compiled KPM validation is missing")
    require(installer, "KPM signature verification failed", "supplied invalid signatures are not fatal")
    require(installer, "Unsigned KPM prepared with autoload disabled", "unsigned KPM can request autoload")
    require(installer, 'kpatch kpm load "$DEST_KPM" -- "$MOD_ARGS"', "immediate-load arguments are not passed as one quoted argv value")
    reject(installer, 'ARGS_OPT="-- $MOD_ARGS"', "unquoted argument concatenation returned")
    require(installer, "Another KPM installation is already running", "concurrent KPM installation lock is missing")
    require(installer, ".kpm-stage.$$", "installation files are not prepared in a staging directory")
    require(installer, 'mv "$STAGE_DIR/module.kpm" "$DEST_KPM"', "KPM binary is not committed after staged metadata")

    # No source path may be accepted solely because it contains a trusted path
    # as a substring; the case patterns must be rooted.
    if re.search(r"case \"\$_resolved\" in[\s\S]*?\*/data/local/tmp", installer):
        raise AssertionError("trusted KPM source path pattern is not rooted")

    print("Install and KPM lifecycle contracts validated.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
