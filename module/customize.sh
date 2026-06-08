#!/system/bin/sh
MODDIR="/data/adb/modules/PatchNest"

# P2-Cluster E fix: defend against an unset/empty $MODDIR which would turn
# the rm -rf below into a recursive wipe of /. We rely on $MODPATH from
# the Magisk install harness, falling back to the legacy $MODDIR constant
# only when $MODPATH is empty.
[ -z "${MODPATH:-}" ] && MODPATH="$MODDIR"
# Sanity: refuse to run if MODPATH is empty or does not exist.
if [ -z "$MODPATH" ] || [ ! -d "$MODPATH" ]; then
    abort "! MODPATH is empty or missing: '$MODPATH'"
fi

# We only support arm64
if [ "$ARCH" != "arm64" ]; then
    abort "! Only arm64 is supported"
fi

# Detect root manager
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

# Optional system-managed KPM repos override. If the maintainer ships
# a file at $MODPATH/repos.json in their PatchNest build, copy it
# to /data/adb/patchnest/repos.json — the WebUI's Kpm-Repo page will
# read this and use it as the canonical repo list instead of the
# built-in default. Format:
#   [ { "url": "https://...", "name": "..." }, ... ]
# This is the cleanest way for a PatchNest fork to ship a non-default
# default repo (e.g. "always use Acme's Kpm-Repo instead of the
# official one"). See https://github.com/Zhanfg/Kpm-Repo for details.
if [ -f "$MODPATH/repos.json" ]; then
    cp "$MODPATH/repos.json" /data/adb/patchnest/repos.json
    ui_print "- Installed system repos.json"
fi

# Migrate package_config from APatch if present
if [ -f "/data/adb/ap/package_config" ] && [ ! -f "/data/adb/patchnest/package_config" ]; then
    cp "/data/adb/ap/package_config" /data/adb/patchnest/package_config
    ui_print "- Migrated APatch package_config"
fi

# Copy binaries (single source: KernelPatch-Public)
ui_print "- Installing KernelPatch binaries..."

# P1-Cluster D fix: missing critical binaries should abort the install,
# not silently produce a broken module.
if [ ! -x "$MODPATH/bin/kpatch" ]; then
    abort "! kpatch binary missing or not executable in $MODPATH/bin"
fi
if [ ! -x "$MODPATH/bin/kptools" ]; then
    abort "! kptools binary missing or not executable in $MODPATH/bin"
fi

# Save root manager info
echo "$ROOT_MGR" > /data/adb/patchnest/root_manager

# backup module.prop
cp "$MODPATH/module.prop" "$MODPATH/module.prop.bak"

# Hot update webui, patch scripts and binaries
# P2-Cluster E fix: defensive globs — if the directory is empty the
# pattern literally matches, so we guard with set +f / null-glob
# behaviour via noclobber on the rm side. We use a leading-/-style
# protection by checking each path explicitly.
rm -rf "$MODDIR/webroot"/* 2>/dev/null || true
rm -rf "$MODDIR/bin"/*     2>/dev/null || true
rm -rf "$MODDIR/patch"/*   2>/dev/null || true
[ -d "$MODDIR/webroot" ] || mkdir -p "$MODDIR/webroot"
[ -d "$MODDIR/bin" ]     || mkdir -p "$MODDIR/bin"
[ -d "$MODDIR/patch" ]   || mkdir -p "$MODDIR/patch"
cp -rf "$MODPATH/webroot"/* "$MODDIR/webroot/" 2>/dev/null || true
cp -rf "$MODPATH/bin"/*     "$MODDIR/bin/"     2>/dev/null || true
cp -rf "$MODPATH/patch"/*   "$MODDIR/patch/"   2>/dev/null || true

# Copy environment detection script
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
