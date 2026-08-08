#!/bin/sh

MODDIR=${0%/*}
PNDIR="/data/adb/patchnest"
PATH="$MODDIR/bin:$PATH"
CONFIG="$PNDIR/package_config"
REHOOK="$(cat "$PNDIR/rehook" 2>/dev/null || true)"
LOG="$PNDIR/service.log"
KPM_DIR="$PNDIR/kpm"
KPM_EVENT_DIR="$PNDIR/kpm_events"

get_prop() {
    grep "^${1}=" "$2" 2>/dev/null | head -1 | cut -d'=' -f2-
}

KPN_CONFIG="$PNDIR/config"
# Review branch default: surface unsigned KPMs instead of silently loading
# them. Users can still choose off explicitly while developing local KPMs.
KPM_SIGNATURE_POLICY=warn
if [ -f "$KPN_CONFIG" ]; then
    _val=$(grep -E '^[[:space:]]*(export[[:space:]]+)?KPM_SIGNATURE_POLICY[[:space:]]*=' \
        "$KPN_CONFIG" 2>/dev/null | tail -1 | sed -E 's/^[^=]*=//' | tr -d '"\r\n' | tr 'A-Z' 'a-z')
    case "$_val" in
        off|warn|strict) KPM_SIGNATURE_POLICY="$_val" ;;
        0|false)         KPM_SIGNATURE_POLICY=off ;;
        1|true|yes|on)   KPM_SIGNATURE_POLICY=strict ;;
        *)               KPM_SIGNATURE_POLICY=warn ;;
    esac
fi

case "$KPM_SIGNATURE_POLICY" in
    off)    REQUIRE_KPM_SIGNATURES=0 ;;
    warn|strict) REQUIRE_KPM_SIGNATURES=1 ;;
    *)      REQUIRE_KPM_SIGNATURES=1 ;;
esac

# shellcheck disable=SC1091
. "$MODDIR/kpm_verify.sh" 2>/dev/null || true

mkdir -p "$PNDIR" "$KPM_DIR/failed" "$KPM_EVENT_DIR"
echo "=== $(date) service.sh started ===" > "$LOG"
echo "[$(date)] MODDIR=$MODDIR" >> "$LOG"
echo "[$(date)] PATH=$PATH" >> "$LOG"
echo "[$(date)] KPM_SIGNATURE_POLICY=$KPM_SIGNATURE_POLICY" >> "$LOG"

ROOT_MGR="unknown"
if [ -f "$PNDIR/root_manager" ]; then
    _rm_raw="$(cat "$PNDIR/root_manager" 2>/dev/null || true)"
    _rm_sane="$(printf '%s' "$_rm_raw" | tr -cd 'a-z')"
    if [ -n "$_rm_sane" ]; then
        ROOT_MGR="$_rm_sane"
    fi
fi
echo "[$(date)] root_manager=$ROOT_MGR" >> "$LOG"

if [ ! -x "$MODDIR/bin/kpatch" ]; then
    echo "[$(date)] ERROR: kpatch binary not found or not executable" >> "$LOG"
    touch "$MODDIR/unresolved"
    exit 0
fi

# kpatch hello is the package-level ABI readiness gate. Capture the exact echo
# and turn it into a capability profile; never infer mutation safety from a
# numeric command ID shared by multiple KernelPatch families.
retries=0
max_retries=5
hello_out=""
while [ "$retries" -lt "$max_retries" ]; do
    hello_out="$(kpatch hello 2>>"$LOG")"
    hello_rc=$?
    if [ "$hello_rc" -eq 0 ] && [ -n "$hello_out" ]; then
        break
    fi
    retries=$((retries + 1))
    echo "[$(date)] kpatch hello attempt $retries failed, retrying..." >> "$LOG"
    sleep 2
done

if [ "$hello_rc" -ne 0 ] || [ -z "$hello_out" ]; then
    echo "[$(date)] ERROR: kpatch/kernel ABI handshake failed after $retries retries" >> "$LOG"
    echo "[$(date)] Refusing KPM/exclude/rehook/event operations; package is unresolved." >> "$LOG"
    touch "$MODDIR/unresolved"
    exit 0
fi

case "$hello_out" in
    hello1158) ABI_PROFILE=public1158 ;;
    hello2026) ABI_PROFILE=next2026 ;;
    *)
        echo "[$(date)] ERROR: unrecognized successful hello response: $hello_out" >> "$LOG"
        touch "$MODDIR/unresolved"
        exit 0
        ;;
esac

echo "[$(date)] kpatch hello OK: $hello_out profile=$ABI_PROFILE" >> "$LOG"
printf '%s\n' "$ABI_PROFILE" > "$PNDIR/abi_profile"

# Healthy userspace/kernel handshake. This only clears the userspace marker;
# it does not claim physical boot-loop recovery has been validated.
echo "0" > "$PNDIR/boot_count" 2>/dev/null
rm -f "$PNDIR/autorecovery_active" "$PNDIR/auto_unpatch_requested"

for kpm in "$KPM_DIR"/*.kpm "$KPM_DIR"/*.ko "$KPM_DIR"/*.o; do
    [ -e "$kpm" ] || continue
    [ -s "$kpm" ] || continue
    mod_basename=$(basename "$kpm" | sed 's/\.\(kpm\|ko\|o\)$//')
    args=""
    if [ -f "$KPM_EVENT_DIR/${mod_basename}.args" ]; then
        raw_args="$(cat "$KPM_EVENT_DIR/${mod_basename}.args" 2>/dev/null || true)"
        args="$(printf '%s' "$raw_args" | tr -cd 'A-Za-z0-9_=,.+:/@% -')"
    fi

    _kpm_sig="$KPM_DIR/${mod_basename}.kpm.sig"
    if [ "$KPM_SIGNATURE_POLICY" != "off" ]; then
        if [ ! -f "$_kpm_sig" ]; then
            if [ "$KPM_SIGNATURE_POLICY" = "strict" ]; then
                echo "[$(date)] REJECTED (strict, unsigned): $(basename "$kpm"), moving to failed/" >> "$LOG"
                mv "$kpm" "$KPM_DIR/failed/$(basename "$kpm")"
                continue
            else
                echo "[$(date)] WARN (unsigned, policy=$KPM_SIGNATURE_POLICY): $(basename "$kpm") — loading anyway" >> "$LOG"
                echo "unsigned:$(basename "$kpm"):$(date +%s)" >> "$PNDIR/unsigned_modules.log"
            fi
        elif ! verify_kpm_sig "$kpm" "$_kpm_sig"; then
            echo "[$(date)] REJECTED (sig invalid): $(basename "$kpm"), moving to failed/" >> "$LOG"
            mv "$kpm" "$KPM_DIR/failed/$(basename "$kpm")"
            mv "$_kpm_sig" "$KPM_DIR/failed/$(basename "$_kpm_sig")" 2>/dev/null || true
            continue
        fi
    fi

    # The C CLI accepts `load PATH [ARGS]`; preserve the sanitized args string
    # as one argv element rather than sending a literal option terminator.
    if [ -n "$args" ]; then
        kpatch kpm load "$kpm" "$args"
    else
        kpatch kpm load "$kpm"
    fi
    if [ $? -ne 0 ]; then
        echo "[$(date)] Failed to load: $(basename "$kpm"), moving to failed/" >> "$LOG"
        mv "$kpm" "$KPM_DIR/failed/$(basename "$kpm")"
    else
        echo "[$(date)] Loaded: $(basename "$kpm") args=[$args]" >> "$LOG"
    fi
done

# 0x1100/0x1101 are rehook in Next2026 but SU grant/revoke in Public1158.
# Never dispatch rehook merely because the numeric command exists.
if [ -n "$REHOOK" ]; then
    if [ "$ABI_PROFILE" = "public1158" ]; then
        echo "[$(date)] rehook request ignored: unsupported and unsafe on Public1158" >> "$LOG"
        rm -f "$PNDIR/rehook"
    elif [ "$REHOOK" = "enable" ] || [ "$REHOOK" = "disable" ]; then
        if kpatch rehook "$REHOOK" >>"$LOG" 2>&1; then
            echo "[$(date)] rehook $REHOOK" >> "$LOG"
        else
            echo "[$(date)] ERROR: rehook $REHOOK failed" >> "$LOG"
            touch "$MODDIR/unresolved"
        fi
    else
        rm -f "$PNDIR/rehook"
    fi
fi

dispatch_event() {
    event_name="$1"
    if [ "$ABI_PROFILE" != "public1158" ]; then
        echo "[$(date)] Event $event_name skipped: ABI $ABI_PROFILE has no reviewed event capability" >> "$LOG"
        return 0
    fi

    echo "[$(date)] Dispatching Public1158 event: $event_name" >> "$LOG"
    if ! kpatch event "$event_name" "PatchNest" "" >>"$LOG" 2>&1; then
        echo "[$(date)] ERROR: Public1158 event dispatch failed: $event_name" >> "$LOG"
        touch "$MODDIR/unresolved"
        return 1
    fi
    return 0
}

dispatch_event "POST_FS_DATA" || true

wait_count=0
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
    wait_count=$((wait_count + 1))
    if [ "$wait_count" -ge 300 ]; then
        echo "[$(date)] WARN: boot_completed timeout; BOOT_COMPLETED event will not be forged" >> "$LOG"
        break
    fi
done

if [ "$(getprop sys.boot_completed)" = "1" ]; then
    dispatch_event "BOOT_COMPLETED" || true
fi

if [ -f "$CONFIG" ]; then
    excluded_count=0
    excluded_failed=0
    _cfg_tmp=$(mktemp /data/local/tmp/patchnest_cfg.XXXXXX)
    tail -n +2 "$CONFIG" > "$_cfg_tmp"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        pkg=$(echo "$line" | awk -F, '{print $1}')
        exclude=$(echo "$line" | awk -F, '{print $2}')
        uid=$(echo "$line" | awk -F, '{print $4}')
        if [ "$exclude" = "1" ] && [ -n "$pkg" ] && [ -n "$uid" ]; then
            pkgq=$(printf '%s' "$pkg" | sed 's/[][\.*^$()+?{|/]/\\&/g')
            UID_VAL=$(grep -F " $uid" /data/system/packages.list 2>/dev/null | grep "^$pkgq " | head -1 | awk '{print $2}')
            if [ -n "$UID_VAL" ]; then
                if kpatch exclude_set "$UID_VAL" 1 >>"$LOG" 2>&1; then
                    excluded_count=$((excluded_count + 1))
                else
                    excluded_failed=$((excluded_failed + 1))
                fi
            else
                excluded_failed=$((excluded_failed + 1))
            fi
        fi
    done < "$_cfg_tmp"
    rm -f "$_cfg_tmp"
    echo "[$(date)] exclusion: applied=$excluded_count failed=$excluded_failed" >> "$LOG"
    if [ "$excluded_failed" -gt 0 ]; then
        touch "$MODDIR/unresolved"
    fi
fi

echo "[$(date)] service.sh completed" >> "$LOG"
