#!/bin/sh

MODDIR=${0%/*}
PNDIR="/data/adb/patchnest"
PATH="$MODDIR/bin:$PATH"
CONFIG="$PNDIR/package_config"
REHOOK="$(cat "$PNDIR/rehook" 2>/dev/null || true)"
LOG="$PNDIR/service.log"
KPM_DIR="$PNDIR/kpm"
KPM_EVENT_DIR="$PNDIR/kpm_events"
BOOT_COUNT_FILE="$PNDIR/boot_count"
AUTO_UNPATCH_REQUEST="$PNDIR/auto_unpatch_requested"
AUTORECOVERY_MARKER="$PNDIR/autorecovery_active"

get_prop() {
    grep "^${1}=" "$2" 2>/dev/null | head -1 | cut -d'=' -f2-
}

KPN_CONFIG="$PNDIR/config"
KPM_SIGNATURE_POLICY=warn
if [ -f "$KPN_CONFIG" ]; then
    _val=$(grep -E '^[[:space:]]*(export[[:space:]]+)?KPM_SIGNATURE_POLICY[[:space:]]*=' \
        "$KPN_CONFIG" 2>/dev/null | tail -1 | sed -E 's/^[^=]*=//' | tr -d '"\r\n' | tr 'A-Z' 'a-z')
    case "$_val" in
        off|warn|strict) KPM_SIGNATURE_POLICY="$_val" ;;
        0|false) KPM_SIGNATURE_POLICY=off ;;
        1|true|yes|on) KPM_SIGNATURE_POLICY=strict ;;
        *) KPM_SIGNATURE_POLICY=warn ;;
    esac
fi

case "$KPM_SIGNATURE_POLICY" in
    off) REQUIRE_KPM_SIGNATURES=0 ;;
    warn|strict) REQUIRE_KPM_SIGNATURES=1 ;;
    *) REQUIRE_KPM_SIGNATURES=1 ;;
esac

# shellcheck disable=SC1091
. "$MODDIR/kpm_verify.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$MODDIR/patch/superkey_safety.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$MODDIR/patch/transaction_safety.sh" 2>/dev/null || true

mkdir -p "$PNDIR" "$KPM_DIR/failed" "$KPM_EVENT_DIR"
echo "=== $(date) service.sh started ===" > "$LOG"
echo "[$(date)] MODDIR=$MODDIR" >> "$LOG"
echo "[$(date)] PATH=$PATH" >> "$LOG"
echo "[$(date)] KPM_SIGNATURE_POLICY=$KPM_SIGNATURE_POLICY" >> "$LOG"

ROOT_MGR="unknown"
if [ -f "$PNDIR/root_manager" ]; then
    _rm_raw="$(cat "$PNDIR/root_manager" 2>/dev/null || true)"
    _rm_sane="$(printf '%s' "$_rm_raw" | tr -cd 'a-z')"
    [ -z "$_rm_sane" ] || ROOT_MGR="$_rm_sane"
fi
echo "[$(date)] root_manager=$ROOT_MGR" >> "$LOG"

if [ ! -x "$MODDIR/bin/kpatch" ]; then
    echo "[$(date)] ERROR: kpatch binary not found or not executable" >> "$LOG"
    touch "$MODDIR/unresolved"
    exit 0
fi

try_pending_public1158_key() {
    command -v patchnest_read_key_file >/dev/null 2>&1 || return 1
    command -v patchnest_pending_transaction_matches_written_key >/dev/null 2>&1 || return 1
    command -v patchnest_commit_binding_from_pending_written >/dev/null 2>&1 || return 1
    [ ! -e "$PATCHNEST_SUPERKEY_FILE" ] || return 1
    [ -e "$PATCHNEST_SUPERKEY_PENDING_FILE" ] || return 1
    [ -e "$PATCHNEST_PENDING_TRANSACTION_FILE" ] || return 1

    _pn_pending_key=$(patchnest_read_key_file "$PATCHNEST_SUPERKEY_PENDING_FILE") || {
        echo "[$(date)] ERROR: pending Public1158 key is insecure or invalid" >> "$LOG"
        return 1
    }
    if ! patchnest_pending_transaction_matches_written_key "$_pn_pending_key"; then
        echo "[$(date)] ERROR: pending key has no matching verified written transaction" >> "$LOG"
        _pn_pending_key=''
        return 1
    fi

    _pn_pending_hello=$(PATCHNEST_SUPERKEY="$_pn_pending_key" kpatch hello 2>>"$LOG")
    _pn_pending_rc=$?
    if [ "$_pn_pending_rc" -ne 0 ] || [ "$_pn_pending_hello" != "hello1158" ]; then
        echo "[$(date)] Pending Public1158 key did not authenticate the running kernel" >> "$LOG"
        _pn_pending_key=''
        return 1
    fi

    if ! mv -f "$PATCHNEST_SUPERKEY_PENDING_FILE" "$PATCHNEST_SUPERKEY_FILE"; then
        echo "[$(date)] ERROR: authenticated pending key could not be promoted" >> "$LOG"
        _pn_pending_key=''
        return 1
    fi
    if ! patchnest_key_file_is_secure "$PATCHNEST_SUPERKEY_FILE"; then
        mv -f "$PATCHNEST_SUPERKEY_FILE" "$PATCHNEST_SUPERKEY_PENDING_FILE" 2>/dev/null || true
        echo "[$(date)] ERROR: promoted Public1158 key failed security verification" >> "$LOG"
        _pn_pending_key=''
        return 1
    fi

    if ! patchnest_commit_binding_from_pending_written "$_pn_pending_key"; then
        # Keep the active key: it is the only authenticated access to the
        # already-running patched kernel. Block all further mutations instead.
        echo "[$(date)] ERROR: pending key recovered, but rollback binding reconstruction failed" >> "$LOG"
        patchnest_mark_recovery_required "pending_key_promoted_binding_recovery_failed" || true
        touch "$MODDIR/unresolved"
        _pn_pending_key=''
        return 1
    fi

    _pn_pending_key=''
    echo "[$(date)] RECOVERY: authenticated pending key promoted and rollback binding reconstructed" >> "$LOG"
    touch "$PNDIR/credential_recovered_pending"
    hello_out="hello1158"
    hello_rc=0
    return 0
}

resolve_runtime_boot_target() {
    _pn_out=$(PATH="$MODDIR/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH" \
        "$MODDIR/patch/boot_extract.sh" false 2>>"$LOG") || return 1
    printf '%s\n' "$_pn_out" >> "$LOG"
    _pn_target=$(printf '%s\n' "$_pn_out" | sed -n 's/^BOOTIMAGE=//p' | tail -n 1)
    [ -n "$_pn_target" ] || return 1
    _pn_target=$(readlink -f "$_pn_target" 2>/dev/null || printf '%s' "$_pn_target")
    [ -e "$_pn_target" ] || return 1
    printf '%s\n' "$_pn_target"
}

request_reboot_after_recovery() {
    sync
    if command -v setprop >/dev/null 2>&1; then
        setprop sys.powerctl reboot 2>>"$LOG" || true
    elif command -v reboot >/dev/null 2>&1; then
        reboot 2>>"$LOG" || true
    fi
}

handle_requested_auto_recovery() {
    [ -f "$AUTO_UNPATCH_REQUEST" ] || return 0
    echo "[$(date)] AUTO-RECOVERY: boot failure threshold reached; refusing normal runtime mutations" >> "$LOG"

    _pn_target=$(resolve_runtime_boot_target) || {
        echo "[$(date)] ERROR: auto-recovery cannot resolve exact boot target" >> "$LOG"
        patchnest_mark_recovery_required "auto_recovery_target_resolution_failed" || true
        return 1
    }

    # Normal case: a committed binding exists and recovery needs no working
    # kernel ABI at all. This is deliberately attempted before hello/KPM work.
    if PATH="$MODDIR/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH" \
        "$MODDIR/patch/boot_unpatch.sh" --restore-bound-backup "$_pn_target" >>"$LOG" 2>&1; then
        echo "[$(date)] AUTO-RECOVERY: exact rollback restored and read back" >> "$LOG"
        touch "$PNDIR/auto_recovery_restored"
        rm -f "$AUTO_UNPATCH_REQUEST"
        request_reboot_after_recovery
        return 10
    fi

    # Crash-window fallback: the boot write may have completed before key and
    # binding commit. Only a state=written transaction + authenticated pending
    # key is allowed to reconstruct rollback authorization, then retry restore.
    echo "[$(date)] AUTO-RECOVERY: committed binding unavailable; checking verified pending transaction" >> "$LOG"
    if try_pending_public1158_key; then
        if PATH="$MODDIR/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH" \
            "$MODDIR/patch/boot_unpatch.sh" --restore-bound-backup "$_pn_target" >>"$LOG" 2>&1; then
            echo "[$(date)] AUTO-RECOVERY: recovered binding and restored exact backup" >> "$LOG"
            touch "$PNDIR/auto_recovery_restored"
            rm -f "$AUTO_UNPATCH_REQUEST"
            request_reboot_after_recovery
            return 10
        fi
    fi

    echo "[$(date)] CRITICAL: automatic transaction-bound recovery failed" >> "$LOG"
    patchnest_mark_recovery_required "automatic_bootloop_recovery_failed" || true
    touch "$MODDIR/unresolved"
    return 1
}

# A boot-loop recovery request is a higher-priority safety action than ABI
# probing or KPM/exclusion mutations. Attempt rollback before normal service.
if [ -f "$AUTO_UNPATCH_REQUEST" ]; then
    handle_requested_auto_recovery
    _pn_auto_rc=$?
    case "$_pn_auto_rc" in
        10) exit 0 ;;
        *) exit 0 ;;
    esac
fi

retries=0
max_retries=5
hello_out=""
hello_rc=1
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
    if ! try_pending_public1158_key; then
        echo "[$(date)] ERROR: kpatch/kernel ABI handshake failed after $retries retries" >> "$LOG"
        echo "[$(date)] Refusing KPM/exclude/rehook/event operations; package is unresolved." >> "$LOG"
        touch "$MODDIR/unresolved"
        exit 0
    fi
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
# IMPORTANT: hello does not prove a healthy Android boot. boot_count and
# autorecovery markers are cleared only after sys.boot_completed=1 below.

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
            fi
            echo "[$(date)] WARN (unsigned, policy=$KPM_SIGNATURE_POLICY): $(basename "$kpm") — loading anyway" >> "$LOG"
            echo "unsigned:$(basename "$kpm"):$(date +%s)" >> "$PNDIR/unsigned_modules.log"
        elif ! verify_kpm_sig "$kpm" "$_kpm_sig"; then
            echo "[$(date)] REJECTED (sig invalid): $(basename "$kpm"), moving to failed/" >> "$LOG"
            mv "$kpm" "$KPM_DIR/failed/$(basename "$kpm")"
            mv "$_kpm_sig" "$KPM_DIR/failed/$(basename "$_kpm_sig")" 2>/dev/null || true
            continue
        fi
    fi

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
boot_completed=0
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
    wait_count=$((wait_count + 1))
    if [ "$wait_count" -ge 300 ]; then
        echo "[$(date)] ERROR: boot_completed timeout; failed-boot counter intentionally retained" >> "$LOG"
        touch "$MODDIR/unresolved"
        break
    fi
done

if [ "$(getprop sys.boot_completed)" = "1" ]; then
    boot_completed=1
    dispatch_event "BOOT_COMPLETED" || true
    echo "0" > "$BOOT_COUNT_FILE" 2>/dev/null
    rm -f "$AUTORECOVERY_MARKER" "$AUTO_UNPATCH_REQUEST"
    echo "[$(date)] healthy boot confirmed; bootloop counter reset" >> "$LOG"
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
    [ "$excluded_failed" -eq 0 ] || touch "$MODDIR/unresolved"
fi

echo "[$(date)] service.sh completed boot_completed=$boot_completed" >> "$LOG"
