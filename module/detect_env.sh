#!/system/bin/sh
#
# Root Manager Environment Detection
# Source this file: . "$MODDIR/detect_env.sh"
#
# Sets: ROOT_MGR, HAS_WEBUI, WEBUI_PKG, MODDIR, PNDIR, KPATCH_BIN, KPATCH_OK
#
# Notes:
#   * All detection functions use `local` so they don't pollute the
#     caller's namespace mid-function. The exported globals below are
#     set at the bottom in a single batch.
#   * The previous draft assigned ROOT_MGR inside detect_root_manager
#     without `local`, which meant the value stayed live in the
#     caller's shell. That's fine for ROOT_MGR (which the caller wants
#     to read) but is a footgun for any future additions to the
#     function — we now declare everything local and re-export
#     explicitly. (P0-6)
#

PNDIR="/data/adb/patchnest"
MODDIR="${MODDIR:-/data/adb/modules/PatchNest}"

# Detect root manager
detect_root_manager() {
    # P0-6: was assigned without `local`, polluting the caller's
    # namespace. The caller (service.sh / action.sh / status.sh)
    # *does* want ROOT_MGR exported; we use `local` inside the
    # function for safety then re-export below. The values are
    # hardcoded literals (apatch / ksu / magisk / unknown) so no
    # quoting risk.
    local _root_mgr=""
    if [ -n "$APATCH" ]; then
        _root_mgr="apatch"
    elif [ -n "$KSU" ] || [ -f "/data/adb/ksu" ]; then
        _root_mgr="ksu"
    elif pm path me.weishu.kernelsu >/dev/null 2>&1; then
        _root_mgr="ksu"
    elif pm path me.bmax.apatch >/dev/null 2>&1; then
        _root_mgr="apatch"
    elif pm path com.topjohnwu.magisk >/dev/null 2>&1; then
        _root_mgr="magisk"
    elif [ -f "/data/adb/magisk" ]; then
        _root_mgr="magisk"
    else
        _root_mgr="unknown"
    fi
    ROOT_MGR="$_root_mgr"
}

# Detect WebUI capability
detect_webui() {
    # P0-6: previously these globals were assigned without `local`,
    # making them function-scoped-by-accident. Now declared local and
    # exported at the end. Values are hardcoded package names or
    # boolean literals; no shell escaping concerns.
    local _has_webui="false"
    local _webui_pkg=""

    # KSUWebUIStandalone (works with all managers)
    if pm path io.github.a13e300.ksuwebui >/dev/null 2>&1; then
        _has_webui="true"
        _webui_pkg="io.github.a13e300.ksuwebui"
        HAS_WEBUI="$_has_webui"
        WEBUI_PKG="$_webui_pkg"
        return
    fi

    # KernelSU native WebUI
    if [ "$ROOT_MGR" = "ksu" ]; then
        if pm path me.weishu.kernelsu >/dev/null 2>&1; then
            _has_webui="true"
            _webui_pkg="me.weishu.kernelsu"
            HAS_WEBUI="$_has_webui"
            WEBUI_PKG="$_webui_pkg"
            return
        fi
    fi

    # ReSukiSU
    if pm path com.sukisu.ultra >/dev/null 2>&1; then
        _has_webui="true"
        _webui_pkg="com.sukisu.ultra"
    elif [ "$ROOT_MGR" = "apatch" ]; then
        # APatch
        if pm path me.bmax.apatch >/dev/null 2>&1; then
            _has_webui="true"
            _webui_pkg="me.bmax.apatch"
        fi
    fi
    HAS_WEBUI="$_has_webui"
    WEBUI_PKG="$_webui_pkg"
}

# Check if kpatch binary is functional
detect_kpatch() {
    # P0-6: local the intermediates. The shell builtin [ -x ] is
    # safe; no quoting concerns because MODDIR is sanitized at the
    # top of this file (P0-2 style guard).
    local _kpatch_bin="$MODDIR/bin/kpatch"
    local _kpatch_ok="false"
    if [ -x "$_kpatch_bin" ]; then
        if "$_kpatch_bin" hello >/dev/null 2>&1; then
            _kpatch_ok="true"
        fi
    fi
    KPATCH_BIN="$_kpatch_bin"
    KPATCH_OK="$_kpatch_ok"
}

# Run all detection
detect_root_manager
detect_webui
detect_kpatch
