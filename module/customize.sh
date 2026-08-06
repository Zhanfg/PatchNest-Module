#!/system/bin/sh
# PatchNest module installation validation and state migration.
# The root manager owns placement of $MODPATH; this script never deletes or
# recopies the active module directory.

STATE_DIR=/data/adb/patchnest

[ -n "${MODPATH:-}" ] && [ -d "$MODPATH" ] || abort "! MODPATH is empty or missing"
[ "${ARCH:-}" = "arm64" ] || abort "! Only arm64 is supported"

ROOT_MGR=unknown
if [ -n "${APATCH:-}" ]; then
    ROOT_MGR=apatch
elif [ -n "${KSU:-}" ]; then
    ROOT_MGR=ksu
elif [ -n "${MAGISK_VER:-}" ]; then
    ROOT_MGR=magisk
fi

ui_print "- Root manager: $ROOT_MGR"
ui_print "- Architecture: $ARCH"

# Validate the package before touching persistent state. Missing WebUI or boot
# safety files must stop installation rather than produce a partial module.
for _required_file in \
    module.prop \
    bin/kpatch \
    bin/kptools \
    bin/kpimg \
    bin/magiskboot \
    patch/boot_extract.sh \
    patch/boot_patch.sh \
    patch/boot_unpatch.sh \
    patch/flash_guard.sh \
    patch/boot_target.sh \
    patch/util_functions.sh \
    webroot/index.html \
    webroot/index.js; do
    [ -s "$MODPATH/$_required_file" ] || abort "! Required package file missing or empty: $_required_file"
done

# Apply deterministic permissions to the framework-provided staging directory.
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 2000 0755 0755
set_perm_recursive "$MODPATH/patch" 0 0 0755 0755
for _script in \
    action.sh customize.sh detect_env.sh install_kpm.sh kpm_verify.sh \
    post-fs-data.sh service.sh status.sh uninstall.sh compile_kpm.sh; do
    [ -f "$MODPATH/$_script" ] && set_perm "$MODPATH/$_script" 0 0 0755
 done

mkdir -p "$STATE_DIR" || abort "! Cannot create $STATE_DIR"
chmod 0700 "$STATE_DIR" 2>/dev/null || true

# Persist root manager information atomically.
_root_tmp="$STATE_DIR/root_manager.tmp.$$"
printf '%s\n' "$ROOT_MGR" >"$_root_tmp" || abort "! Cannot write root manager state"
mv "$_root_tmp" "$STATE_DIR/root_manager" || abort "! Cannot finalize root manager state"
chmod 0600 "$STATE_DIR/root_manager" 2>/dev/null || true

# Optional system-managed repository policy. Validate the top-level JSON type
# when a parser is available, then install atomically. Existing user policy is
# not overwritten when the package does not provide repos.json.
if [ -f "$MODPATH/repos.json" ]; then
    if command -v jq >/dev/null 2>&1; then
        jq -e 'type == "array"' "$MODPATH/repos.json" >/dev/null 2>&1 \
            || abort "! repos.json must contain a JSON array"
    fi
    _repos_tmp="$STATE_DIR/repos.json.tmp.$$"
    cp "$MODPATH/repos.json" "$_repos_tmp" || abort "! Cannot stage repos.json"
    chmod 0600 "$_repos_tmp" 2>/dev/null || true
    mv "$_repos_tmp" "$STATE_DIR/repos.json" || abort "! Cannot install repos.json"
    ui_print "- Installed system repos.json"
fi

# Migrate APatch package policy only when PatchNest has no policy yet. Copy to
# a temporary file first so interruption cannot leave a truncated policy.
if [ -f /data/adb/ap/package_config ] && [ ! -f "$STATE_DIR/package_config" ]; then
    _policy_tmp="$STATE_DIR/package_config.tmp.$$"
    cp /data/adb/ap/package_config "$_policy_tmp" || abort "! Cannot migrate APatch package_config"
    [ -s "$_policy_tmp" ] || { rm -f "$_policy_tmp"; abort "! Migrated package_config is empty"; }
    chmod 0600 "$_policy_tmp" 2>/dev/null || true
    mv "$_policy_tmp" "$STATE_DIR/package_config" || abort "! Cannot finalize package_config"
    ui_print "- Migrated APatch package_config"
fi

ui_print "- Package validation and state migration complete"
ui_print ""
ui_print "  Next steps:"
ui_print "  1. Reboot your device"
if [ "$ROOT_MGR" = "magisk" ]; then
    ui_print "  2. Install KSUWebUIStandalone app"
    ui_print "  3. Open PatchNest from the module Action button"
else
    ui_print "  2. Open PatchNest from the manager WebUI"
fi
ui_print "  4. Review the detected boot target before patching"
ui_print "  5. Reboot only after patch and readback verification succeeds"
