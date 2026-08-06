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
    verifier = read("module/kpm_verify.sh")
    service = read("module/service.sh")

    reject(customize, 'rm -rf "$MODDIR/webroot"', "destructive self-copy hot update returned")
    reject(customize, 'cp -rf "$MODPATH/webroot"', "installer still recopies its active module directory")
    require(customize, "patch/flash_guard.sh", "package validation omits the flash guard")
    require(customize, "patch/boot_target.sh", "package validation omits boot-only discovery")
    require(customize, "module.prop.bak", "validated module metadata backup is not created")
    require(customize, "KPM_SIGNATURE_POLICY=strict", "new installations do not default to strict KPM signatures")
    require(customize, 'if [ ! -e "$STATE_DIR/config" ]', "installer may overwrite existing KPM signature policy")

    reject(uninstall, "rm -rf /data/adb/patchnest", "uninstall deletes persistent recovery state")
    require(uninstall, "Verified boot backups", "uninstall notice does not explain retained recovery data")
    require(uninstall, "did not flash or unpatch", "uninstall incorrectly implies boot restoration")

    require(service, '"$KPM_DIR"/*.kpm "$KPM_DIR"/*.ko "$KPM_DIR"/*.o', "expected broad legacy service scan changed; review admission assumptions")
    require(post_fs, "kpm_quarantine", "non-autoload modules are not quarantined")
    require(post_fs, '"$KPM_EVENT_DIR/${_name}.autoload"', "autoload marker is not enforced before service")
    require(post_fs, '"$KPM_DIR"/*.ko "$KPM_DIR"/*.o', "Linux objects are not rejected before KPM loading")
    require(post_fs, "move_with_sidecars", "KPM quarantine loses associated metadata/signatures")

    require(status, "awk -v key=", "status still relies on a delimiter-sensitive sed replacement")
    reject(status, 'sed "s|^$prop=', "pipe-delimited sed status update returned")
    require(status, "mark_boot_healthy", "healthy boot does not resolve recovery state")
    require(status, '"recovery_requested": false', "healthy state does not clear recovery request")
    require(status, '"resolution": "healthy_kpatch_hello"', "healthy state lacks an explicit resolution")

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

    # Ed25519 verification must wrap the raw key as RFC 8410 SubjectPublicKeyInfo
    # and use the raw-message pkeyutl interface. A raw key passed to `dgst`
    # cannot be interpreted as a public key object.
    require(verifier, "302a300506032b6570032100", "Ed25519 RFC 8410 SPKI prefix is missing")
    require(verifier, "openssl pkeyutl", "signature verification does not use pkeyutl")
    require(verifier, "-pubin", "signature verification does not mark the key as public")
    require(verifier, "-keyform DER", "signature verification does not parse the generated DER key")
    require(verifier, "-rawin", "Ed25519 verification does not use the raw-message interface")
    require(verifier, "-sigfile", "signature bytes are not passed through sigfile")
    require(verifier, "signature file exceeds 4096 bytes", "signature input size is unbounded")
    require(verifier, "mktemp -d", "signature verification lacks an unpredictable private temp directory")
    reject(verifier, "openssl dgst -ed25519", "broken raw-key dgst verification returned")
    reject(verifier, "mkdir -p \"$_tmpdir\"", "predictable world-writable temp fallback returned")
    reject(verifier, "trap '", "sourced verifier overwrites caller signal traps")

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
