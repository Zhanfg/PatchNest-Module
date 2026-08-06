#!/system/bin/sh

MODDIR="/data/adb/modules/PatchNest"
PNDIR="/data/adb/patchnest"
PATH="$MODDIR/bin:$PATH"
PROP_FILE="$MODDIR/module.prop"
PROP_BAK="$PROP_FILE.bak"
RECOVERY_STATE="$PNDIR/recovery_state.json"

set_prop() {
    _prop=$1
    _value=$2
    _file=$3
    [ -f "$_file" ] || return 1
    _tmp=$(mktemp "${_file}.XXXXXX" 2>/dev/null || printf '%s.%s' "$_file" "$$")
    awk -v key="$_prop" -v value="$_value" '
        BEGIN { found = 0 }
        index($0, key "=") == 1 {
            print key "=" value
            found = 1
            next
        }
        { print }
        END {
            if (!found) print key "=" value
        }
    ' "$_file" >"$_tmp" || { rm -f "$_tmp"; return 1; }
    mv "$_tmp" "$_file"
}

restore_prop_if_needed() {
    [ -f "$PROP_FILE" ] && grep -q '^id=' "$PROP_FILE" 2>/dev/null && return 0
    [ -s "$PROP_BAK" ] || return 1
    cp "$PROP_BAK" "$PROP_FILE"
}

mark_boot_healthy() {
    mkdir -p "$PNDIR" 2>/dev/null || return 1
    printf '0\n' >"$PNDIR/boot_count" 2>/dev/null || true
    rm -f "$PNDIR/autorecovery_active" "$PNDIR/auto_unpatch_requested"

    _resolved_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    _state_tmp="${RECOVERY_STATE}.tmp.$$"
    cat >"$_state_tmp" <<EOF
{
  "schema_version": 1,
  "boot_count": 0,
  "threshold": 3,
  "recovery_requested": false,
  "resolved_at": "$_resolved_at",
  "automatic_flash_performed": false,
  "resolution": "healthy_kpatch_hello"
}
EOF
    mv "$_state_tmp" "$RECOVERY_STATE" 2>/dev/null || rm -f "$_state_tmp"
}

# Self-cleanup if the module was removed improperly.
if [ ! -d "$MODDIR" ]; then
    self_path=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    rm -f "$self_path"
    exit 0
fi

ROOT_MGR=unknown
if [ -f "$PNDIR/root_manager" ]; then
    _rm_raw=$(cat "$PNDIR/root_manager" 2>/dev/null || true)
    _rm_sane=$(printf '%s' "$_rm_raw" | tr -cd 'a-z')
    case "$_rm_sane" in
        apatch|ksu|magisk|unknown) ROOT_MGR=$_rm_sane ;;
    esac
elif [ -n "${APATCH:-}" ]; then
    ROOT_MGR=apatch
elif [ -n "${KSU:-}" ]; then
    ROOT_MGR=ksu
elif [ -n "${MAGISK_VER:-}" ]; then
    ROOT_MGR=magisk
fi

active="Status: active"
inactive="Status: inactive"
string="$inactive | info: kernel not patched yet | $ROOT_MGR"

BOOT_WAIT_MAX=300
i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    i=$((i + 1))
    if [ "$i" -ge "$BOOT_WAIT_MAX" ]; then
        string="$inactive | info: boot timeout (${BOOT_WAIT_MAX}s) | $ROOT_MGR"
        restore_prop_if_needed || exit 0
        set_prop description "$string" "$PROP_FILE" || true
        exit 0
    fi
    sleep 1
done

if kpatch hello >/dev/null 2>&1; then
    KPM_COUNT=$(kpatch kpm num 2>/dev/null | tr -cd '0-9' | head -c 8)
    [ -n "$KPM_COUNT" ] || KPM_COUNT=0

    REHOOK_MODE=$(kpatch rehook_status 2>/dev/null | awk '{print $NF}')
    case "$REHOOK_MODE" in
        enabled|disabled) ;;
        *) REHOOK_MODE=unknown ;;
    esac

    string="$active | kpmodule: $KPM_COUNT | rehook: $REHOOK_MODE | $ROOT_MGR"
    mark_boot_healthy || true
fi

restore_prop_if_needed || exit 0
set_prop description "$string" "$PROP_FILE" || true
exit 0
