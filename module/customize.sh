#!/system/bin/sh
# PatchNest installer customization. This file is sourced by the root manager
# after the module ZIP has already been extracted into $MODPATH.

if [ -z "${MODPATH:-}" ] || [ ! -d "$MODPATH" ]; then
    abort "! MODPATH is empty or missing: '${MODPATH:-}'"
fi

# Review packages are deliberately non-installable. This check must remain
# before every persistent PatchNest write or installed-tree mutation.
if [ -f "$MODPATH/FLASH_REVIEW_BLOCKED" ]; then
    ui_print "! PatchNest review build: flashing is intentionally blocked"
    ui_print "! Physical-device flash-readiness gate is still open"
    ui_print "! Use the isolated device-validation candidate only for FR-014"
    abort "! FLASH_REVIEW_BLOCKED"
fi

if [ "${ARCH:-}" != "arm64" ]; then
    abort "! Only arm64 is supported"
fi

PNDIR="/data/adb/patchnest"
if [ "${PATCHNEST_INSTALL_TEST:-0}" = "1" ]; then
    if [ -z "${PATCHNEST_STATE_DIR:-}" ]; then
        abort "! PATCHNEST_STATE_DIR is required in installer-test mode"
    fi
    PNDIR=$PATCHNEST_STATE_DIR
fi

ROOT_MGR="unknown"
if [ -n "${APATCH:-}" ]; then
    ROOT_MGR="apatch"
elif [ -n "${KSU:-}" ]; then
    ROOT_MGR="ksu"
elif [ -n "${MAGISK_VER:-}" ]; then
    ROOT_MGR="magisk"
fi

ui_print "- Root manager: $ROOT_MGR"
ui_print "- Architecture: $ARCH"

set_perm_recursive "$MODPATH/bin" 0 2000 0755 0755
set_perm_recursive "$MODPATH/patch" 0 0 0755 0755
for _pn_tool in \
    device_validation.sh \
    arm_auto_recovery.sh \
    verify_auto_recovery.sh \
    export_recovery_boot.sh \
    validate_kpm_file.sh \
    kpatch_runtime_wrapper.sh; do
    [ ! -f "$MODPATH/$_pn_tool" ] || set_perm "$MODPATH/$_pn_tool" 0 0 0755
done

# Validate the extracted package before creating state or replacing the CLI
# entry point with its runtime policy wrapper.
for _pn_bin in kpatch kptools magiskboot; do
    if [ ! -x "$MODPATH/bin/$_pn_bin" ] || [ -L "$MODPATH/bin/$_pn_bin" ]; then
        abort "! Required binary missing/not executable/unsafe: bin/$_pn_bin"
    fi
done
if [ ! -s "$MODPATH/bin/kpimg" ] || [ -L "$MODPATH/bin/kpimg" ]; then
    abort "! Required KernelPatch image missing, empty, or unsafe: bin/kpimg"
fi
for _pn_script in \
    boot_patch.sh \
    boot_extract.sh \
    boot_unpatch.sh \
    flash_safety.sh \
    transaction_safety.sh \
    transactional_flash.sh \
    fr014_gate.sh \
    superkey_safety.sh; do
    if [ ! -x "$MODPATH/patch/$_pn_script" ] || [ -L "$MODPATH/patch/$_pn_script" ]; then
        abort "! Required patch helper missing/not executable/unsafe: patch/$_pn_script"
    fi
done
for _pn_tool in \
    device_validation.sh \
    arm_auto_recovery.sh \
    verify_auto_recovery.sh \
    export_recovery_boot.sh \
    validate_kpm_file.sh \
    kpatch_runtime_wrapper.sh; do
    if [ ! -x "$MODPATH/$_pn_tool" ] || [ -L "$MODPATH/$_pn_tool" ]; then
        abort "! Required runtime/validation tool missing/not executable/unsafe: $_pn_tool"
    fi
done

command -v sha256sum >/dev/null 2>&1 || abort "! sha256sum is required"
PROVENANCE="$MODPATH/provenance/kpatch-public1158.json"
[ -f "$PROVENANCE" ] && [ ! -L "$PROVENANCE" ] || abort "! Public1158 provenance is missing or unsafe"
EXPECTED_KPATCH_SHA=$(sed -n 's/.*"binarySha256"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p' "$PROVENANCE" | head -n 1)
ACTUAL_KPATCH_SHA=$(sha256sum "$MODPATH/bin/kpatch" 2>/dev/null | awk '{print $1}')
[ -n "$EXPECTED_KPATCH_SHA" ] && [ "$ACTUAL_KPATCH_SHA" = "$EXPECTED_KPATCH_SHA" ] \
    || abort "! Packaged Public1158 kpatch does not match provenance"

# Centralize all runtime `kpatch kpm load` calls behind the same admission
# helper. This closes WebUI/direct-shell paths that could otherwise bypass the
# hardened ZIP installer. The reviewed ARM64 ELF remains available as
# kpatch.real and is what provenance authenticates.
rm -f "$MODPATH/bin/kpatch.real"
mv "$MODPATH/bin/kpatch" "$MODPATH/bin/kpatch.real" \
    || abort "! Cannot preserve validated Public1158 CLI as kpatch.real"
cp "$MODPATH/kpatch_runtime_wrapper.sh" "$MODPATH/bin/kpatch" \
    || abort "! Cannot install kpatch runtime wrapper"
set_perm "$MODPATH/bin/kpatch.real" 0 2000 0755
set_perm "$MODPATH/bin/kpatch" 0 2000 0755
[ -x "$MODPATH/bin/kpatch.real" ] && [ -x "$MODPATH/bin/kpatch" ] \
    || abort "! kpatch runtime wrapper installation failed"
[ "$(sha256sum "$MODPATH/bin/kpatch.real" 2>/dev/null | awk '{print $1}')" = "$EXPECTED_KPATCH_SHA" ] \
    || abort "! kpatch.real changed while installing runtime wrapper"

mkdir -p "$PNDIR" || abort "! Cannot create PatchNest state directory"
chmod 0700 "$PNDIR" 2>/dev/null || true

if [ -f "$MODPATH/repos.json" ]; then
    cp "$MODPATH/repos.json" "$PNDIR/repos.json" || abort "! Cannot install repos.json"
fi

if [ "$ROOT_MGR" = "apatch" ] && [ -f "/data/adb/ap/package_config" ] && [ ! -f "$PNDIR/package_config" ]; then
    cp "/data/adb/ap/package_config" "$PNDIR/package_config" || abort "! Cannot migrate APatch package_config"
fi

printf '%s\n' "$ROOT_MGR" > "$PNDIR/root_manager" || abort "! Cannot persist root manager identity"
chmod 0600 "$PNDIR/root_manager" 2>/dev/null || true

ui_print "- PatchNest files validated in manager-provided MODPATH"
ui_print "- kpatch runtime KPM admission wrapper installed"
ui_print "- Persistent state initialized"
ui_print "- Installation complete"
ui_print ""
ui_print "  Before the first destructive FR-014 flash:"
ui_print "  1. Run device_validation.sh preflight"
ui_print "  2. Run export_recovery_boot.sh with the explicit RECOVERY_EXPORT unlock"
ui_print "  3. Copy the recovery image + manifest off-device and verify SHA-256"
ui_print "  4. Only then start the controlled flash lifecycle"
