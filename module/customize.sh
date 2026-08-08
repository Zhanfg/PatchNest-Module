#!/system/bin/sh
# PatchNest installer customization. This file is sourced by the root manager
# after the module ZIP has already been extracted into $MODPATH.

if [ -z "${MODPATH:-}" ] || [ ! -d "$MODPATH" ]; then
    abort "! MODPATH is empty or missing: '${MODPATH:-}'"
fi

# Review packages are deliberately non-installable. This check must remain
# before every persistent PatchNest write.
if [ -f "$MODPATH/FLASH_REVIEW_BLOCKED" ]; then
    ui_print "! PatchNest review build: flashing is intentionally blocked"
    ui_print "! Physical-device flash-readiness gate is still open"
    ui_print "! Use the isolated device-validation candidate only for FR-014"
    abort "! FLASH_REVIEW_BLOCKED"
fi

if [ "${ARCH:-}" != "arm64" ]; then
    abort "! Only arm64 is supported"
fi

# Production state is fixed. The alternate path is accepted only by the
# repository's installer contract and cannot be selected accidentally in a
# normal manager installation.
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

# The manager already extracted the final module tree into MODPATH. Only set
# explicit permissions; never copy the tree into a hard-coded manager path.
set_perm_recursive "$MODPATH/bin" 0 2000 0755 0755
set_perm_recursive "$MODPATH/patch" 0 0 0755 0755
for _pn_tool in device_validation.sh arm_auto_recovery.sh verify_auto_recovery.sh; do
    [ ! -f "$MODPATH/$_pn_tool" ] || set_perm "$MODPATH/$_pn_tool" 0 0 0755
done

# Fail before creating persistent state if the extracted install tree is not a
# complete runnable package.
for _pn_bin in kpatch kptools magiskboot; do
    if [ ! -x "$MODPATH/bin/$_pn_bin" ]; then
        abort "! Required binary missing or not executable: bin/$_pn_bin"
    fi
done
if [ ! -s "$MODPATH/bin/kpimg" ]; then
    abort "! Required KernelPatch image missing or empty: bin/kpimg"
fi
for _pn_script in \
    boot_patch.sh \
    boot_extract.sh \
    boot_unpatch.sh \
    flash_safety.sh \
    transaction_safety.sh \
    transactional_flash.sh \
    superkey_safety.sh; do
    if [ ! -x "$MODPATH/patch/$_pn_script" ]; then
        abort "! Required patch helper missing or not executable: patch/$_pn_script"
    fi
done
for _pn_tool in device_validation.sh arm_auto_recovery.sh verify_auto_recovery.sh; do
    if [ ! -x "$MODPATH/$_pn_tool" ]; then
        abort "! Required physical-validation tool missing or not executable: $_pn_tool"
    fi
done

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
ui_print "- Persistent state initialized"
ui_print "- Installation complete"
ui_print ""
ui_print "  Next steps:"
ui_print "  1. Reboot your device"
if [ "$ROOT_MGR" = "magisk" ]; then
    ui_print "  2. Install KSUWebUIStandalone app"
    ui_print "     (no native WebUI support in Magisk)"
    ui_print "  3. Open WebUI via Manager → Action button"
else
    ui_print "  2. Open WebUI via Manager → PatchNest → Action"
fi
ui_print "  4. Run read-only device_validation.sh preflight before patching"
ui_print "  5. Do not remove the review blocker outside the FR-014 candidate"
