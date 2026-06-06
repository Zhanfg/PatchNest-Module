#!/bin/sh

MODDIR="/data/adb/modules/KPatch-Next"
KPNDIR="/data/adb/kp-next"
PATH="$MODDIR/bin:$PATH"

PROP_FILE="$MODDIR/module.prop"
PROP_BAK="$PROP_FILE.bak"

set_prop() {
    local prop="$1"
    local value="$2"
    local file="$3"

    if ! grep -q "^$prop=" "$file"; then
        printf '%s=%s\n' "$prop" "$value" >> "$file"
        return
    fi
    # Use a different delimiter (|) so values containing "/" don't break sed,
    # and escape both the prop key and value for sed regex.
    # shellcheck disable=SC3001  # ash on Android handles this fine
    sed "s|^$prop=.*|$prop=$value|" "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

restore_prop_if_needed() {
    grep -q "^id=" "$PROP_FILE" && return
    [ -f "$PROP_BAK" ] && cat "$PROP_BAK" > "$PROP_FILE"
}

# self cleanup if module removed improperly
if [ ! -d "$MODDIR" ]; then
    # realpath isn't on all toybox builds; readlink -f is a safer fallback.
    self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    rm -f "$self_path"
    exit 0
fi

# Detect root manager
ROOT_MGR="unknown"
if [ -f "$KPNDIR/root_manager" ]; then
    ROOT_MGR="$(cat $KPNDIR/root_manager)"
elif [ -n "$APATCH" ]; then
    ROOT_MGR="apatch"
elif [ -n "$KSU" ]; then
    ROOT_MGR="ksu"
elif [ -n "$MAGISK_VER" ]; then
    ROOT_MGR="magisk"
fi

active="Status: active"
inactive="Status: inactive"
info="info: kernel not patched yet"
string="$inactive | $info | $ROOT_MGR"

# P0-6 fix: the previous `until` loop with no timeout would hang forever
# on devices where getprop is broken or SELinux blocks the read. Bound
# the wait to 5 minutes (matching service.sh's timeout) and fall through
# with a "boot timeout" status so the user gets visible feedback.
BOOT_WAIT_MAX=300  # 5 minutes
i=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    i=$((i + 1))
    if [ "$i" -ge "$BOOT_WAIT_MAX" ]; then
        string="$inactive | info: boot timeout ($BOOT_WAIT_MAX s) | $ROOT_MGR"
        restore_prop_if_needed
        set_prop "description" "$string" "$PROP_FILE"
        exit 0
    fi
    sleep 1
done

if kpatch hello >/dev/null 2>&1; then
    KPM_COUNT="$(kpatch kpm num 2>/dev/null || echo 0)"
    [ -z "$KPM_COUNT" ] && KPM_COUNT=0

    REHOOK_MODE="$(kpatch rehook_status 2>/dev/null | awk '{print $NF}')"
    # P1-Cluster B fix: normalize the rehook mode value. The command can
    # return "enabled", "disabled", or an unexpected value if kpatch's
    # output format changes.  Previously the default was "enabled" which
    # made an unparseable output look like rehook was on — misleading to
    # the user.  We now default to "unknown" and only accept known values.
    case "$REHOOK_MODE" in
        enabled|disabled) ;;
        *) REHOOK_MODE="unknown";;
    esac

    string="$active | kpmodule: $KPM_COUNT | rehook: $REHOOK_MODE | $ROOT_MGR"
fi

restore_prop_if_needed

set_prop "description" "$string" "$PROP_FILE"
