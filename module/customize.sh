#!/system/bin/sh
MODDIR="/data/adb/modules/PatchNest"

# This review branch is intentionally non-flashable until the P0 gates in
# FLASH_READINESS.md are closed. The marker is packaged into the module so a
# review artifact cannot be mistaken for a release artifact.
if [ -f "${MODPATH:-$MODDIR}/FLASH_REVIEW_BLOCKED" ]; then
    ui_print "! PatchNest review build: flashing is intentionally blocked"
    ui_print "! P0 flash-readiness gates are still open"
    ui_print "! Use a reviewed release artifact, not this branch"
    abort "! FLASH_REVIEW_BLOCKED"
fi

[ -z "${MODPATH:-}" ] && MODPATH="$MODDIR"
if [ -z "$MODPATH" ] || [ ! -d "$MODPATH" ]; then
    abort "! MODPATH is empty or missing: '$MODPATH'"
fi

if [ "$ARCH" != "arm64" ]; then
    abort "! Only arm64 is supported"
fi

ROOT_MGR="unknown"
if [ -n "$APATCH" ]; then
    ROOT_MGR="apatch"
elif [ -n "$KSU" ]; then
    ROOT_MGR="ksu"
elif [ -n "$MAGISK_VER" ]; then
    ROOT_MGR="magisk"
fi

ui_print "- Root manager: $ROOT_MGR"
ui_print "- Architecture: $ARCH"

set_perm_recursive "$MODPATH/bin" 0 2000 0755 0755

mkdir -p /data/adb/patchnest

if [ -f "$MODPATH/repos.json" ]; then
    cp "$MODPATH/repos.json" /data/adb/patchnest/repos.json
    ui_print "- Installed system repos.json"
fi

if [ -f "/data/adb/ap/package_config" ] && [ ! -f "/data/adb/patchnest/package_config" ]; then
    cp "/data/adb/ap/package_config" /data/adb/patchnest/package_config
    ui_print "- Migrated APatch package_config"
fi

ui_print "- Installing KernelPatch binaries..."

if [ ! -x "$MODPATH/bin/kpatch" ]; then
    abort "! kpatch binary missing or not executable in $MODPATH/bin"
fi
if [ ! -x "$MODPATH/bin/kptools" ]; then
    abort "! kptools binary missing or not executable in $MODPATH/bin"
fi

echo "$ROOT_MGR" > /data/adb/patchnest/root_manager

cp "$MODPATH/module.prop" "$MODPATH/module.prop.bak"

rm -rf "$MODDIR/webroot"/* 2>/dev/null || true
rm -rf "$MODDIR/bin"/*     2>/dev/null || true
rm -rf "$MODDIR/patch"/*   2>/dev/null || true
[ -d "$MODDIR/webroot" ] || mkdir -p "$MODDIR/webroot"
[ -d "$MODDIR/bin" ]     || mkdir -p "$MODDIR/bin"
[ -d "$MODDIR/patch" ]   || mkdir -p "$MODDIR/patch"
cp -rf "$MODPATH/webroot"/* "$MODDIR/webroot/" 2>/dev/null || true
cp -rf "$MODPATH/bin"/*     "$MODDIR/bin/"     2>/dev/null || true
cp -rf "$MODPATH/patch"/*   "$MODDIR/patch/"   2>/dev/null || true

cp -f "$MODPATH/detect_env.sh" "$MODDIR/detect_env.sh" 2>/dev/null || true

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
ui_print "  4. Click 'Start' to patch kernel"
ui_print "  5. Reboot again to activate"
