#!/system/bin/sh
# PatchNest late-start service.

set -u
umask 077

MODDIR=${0%/*}
PNDIR=/data/adb/patchnest
PATH="$MODDIR/bin:${PATH:-}"
CONFIG="$PNDIR/package_config"
KPN_CONFIG="$PNDIR/config"
LOG="$PNDIR/service.log"
KPM_DIR="$PNDIR/kpm"
KPM_EVENT_DIR="$PNDIR/kpm_events"
KPM_QUARANTINE_DIR="$PNDIR/kpm_quarantine"
KPM_FAILED_DIR="$PNDIR/kpm_failed"
UNSIGNED_LOG="$PNDIR/unsigned_modules.log"

mkdir -p "$PNDIR" "$KPM_DIR" "$KPM_EVENT_DIR" "$KPM_QUARANTINE_DIR" "$KPM_FAILED_DIR"
chmod 0700 "$PNDIR" "$KPM_DIR" "$KPM_EVENT_DIR" "$KPM_QUARANTINE_DIR" "$KPM_FAILED_DIR" 2>/dev/null || true
printf '=== %s service.sh started ===\n' "$(date)" >"$LOG"
: >"$UNSIGNED_LOG"
chmod 0600 "$LOG" "$UNSIGNED_LOG" 2>/dev/null || true

service_log() {
    printf '[%s] %s\n' "$(date)" "$*" >>"$LOG" 2>/dev/null || true
}

# Parse exactly one normalized policy line. post-fs-data.sh repairs missing,
# duplicate, or malformed policy before this service runs; strict remains the
# fail-closed fallback if that preparation was skipped or interrupted.
KPM_SIGNATURE_POLICY=strict
_policy_count=0
_policy_value=""
if [ -f "$KPN_CONFIG" ] && [ ! -L "$KPN_CONFIG" ]; then
    _policy_count=$(grep -c '^KPM_SIGNATURE_POLICY=' "$KPN_CONFIG" 2>/dev/null || true)
    _policy_value=$(sed -n 's/^KPM_SIGNATURE_POLICY=//p' "$KPN_CONFIG" 2>/dev/null | head -n 1 | tr -d ' \t\r\n')
fi
if [ "$_policy_count" = "1" ]; then
    case "$_policy_value" in
        off|warn|strict) KPM_SIGNATURE_POLICY=$_policy_value ;;
        *) service_log "invalid signature policy observed; using strict" ;;
    esac
else
    service_log "missing or duplicate signature policy observed; using strict"
fi

# Only allow the documented rehook values.
REHOOK=$(cat "$PNDIR/rehook" 2>/dev/null || true)
REHOOK=$(printf '%s' "$REHOOK" | tr -d '\000-\037\177' | head -c 16)
case "$REHOOK" in
    enable|disable|'') ;;
    *)
        service_log "invalid rehook request removed"
        rm -f "$PNDIR/rehook" 2>/dev/null || true
        REHOOK=""
        ;;
esac

service_log "MODDIR=$MODDIR"
service_log "KPM_SIGNATURE_POLICY=$KPM_SIGNATURE_POLICY"

# Load shared helpers. Missing transactional storage or signature verification
# must never degrade into ad-hoc file moves or unsigned loading.
TRANSACTION_READY=false
if [ -f "$MODDIR/kpm_transaction_store.sh" ] && [ ! -L "$MODDIR/kpm_transaction_store.sh" ]; then
    # shellcheck disable=SC1091
    . "$MODDIR/kpm_transaction_store.sh"
    command -v patchnest_store_kpm_transaction >/dev/null 2>&1 && TRANSACTION_READY=true
fi

SIGNATURE_READY=false
if [ -f "$MODDIR/kpm_verify.sh" ] && [ ! -L "$MODDIR/kpm_verify.sh" ]; then
    # shellcheck disable=SC1091
    . "$MODDIR/kpm_verify.sh"
    command -v verify_kpm_sig >/dev/null 2>&1 && SIGNATURE_READY=true
fi

store_transaction() {
    _source=$1
    _root=$2
    _reason=$3
    if [ "$TRANSACTION_READY" != "true" ]; then
        service_log "ERROR: transaction store unavailable; left in place: $(basename "$_source") reason=$_reason"
        return 1
    fi
    _entry=$(patchnest_store_kpm_transaction "$_source" "$_root" "$_reason" 2>/dev/null) || {
        service_log "ERROR: transaction store failed; left in place: $(basename "$_source") reason=$_reason"
        return 1
    }
    service_log "stored KPM transaction entry=$_entry reason=$_reason"
    return 0
}

# Detect root manager from the installer-owned, normalized state file.
ROOT_MGR=unknown
if [ -f "$PNDIR/root_manager" ] && [ ! -L "$PNDIR/root_manager" ]; then
    _rm_sane=$(tr -cd 'a-z' <"$PNDIR/root_manager" 2>/dev/null | head -c 16)
    case "$_rm_sane" in apatch|ksu|magisk|unknown) ROOT_MGR=$_rm_sane ;; esac
fi
service_log "root_manager=$ROOT_MGR"

if [ ! -x "$MODDIR/bin/kpatch" ]; then
    service_log "ERROR: kpatch binary not found or not executable"
    touch "$MODDIR/unresolved"
    exit 0
fi

# Retry the kernel handshake on slow devices, then stop without altering KPM
# persistence if the kernel is intentionally or unexpectedly unpatched.
retries=0
max_retries=5
while [ "$retries" -lt "$max_retries" ]; do
    if kpatch hello >/dev/null 2>&1; then
        break
    fi
    retries=$((retries + 1))
    service_log "kpatch hello attempt $retries failed"
    sleep 2
done
if ! kpatch hello >/dev/null 2>&1; then
    service_log "kpatch hello failed after $retries retries"
    touch "$MODDIR/unresolved"
    exit 0
fi
rm -f "$MODDIR/unresolved" 2>/dev/null || true
service_log "kpatch hello OK"

# A confirmed healthy PatchNest kernel resumes failed-boot monitoring after an
# intentional unpatch or verified restore.
if [ -f "$MODDIR/patch/recovery_state.sh" ]; then
    # shellcheck disable=SC1091
    . "$MODDIR/patch/recovery_state.sh"
    patchnest_resume_recovery_monitoring healthy-kpatch-hello \
        || service_log "WARNING: could not resume recovery monitoring"
else
    printf '%s\n' 0 >"$PNDIR/boot_count" 2>/dev/null || true
    rm -f "$PNDIR/autorecovery_active" "$PNDIR/auto_unpatch_requested" 2>/dev/null || true
fi

# Any Linux object that appears after post-fs admission remains invalid. Store
# it as a complete failure transaction rather than letting kpatch parse it.
for _object in "$KPM_DIR"/*.ko "$KPM_DIR"/*.o; do
    [ -e "$_object" ] || continue
    [ -f "$_object" ] && [ ! -L "$_object" ] || {
        service_log "ERROR: unsafe non-KPM object left untouched: $_object"
        continue
    }
    store_transaction "$_object" "$KPM_FAILED_DIR" non-kpm-object || true
done

for kpm in "$KPM_DIR"/*.kpm; do
    [ -e "$kpm" ] || continue
    [ -f "$kpm" ] && [ ! -L "$kpm" ] && [ -s "$kpm" ] || {
        service_log "ERROR: unsafe or empty KPM left untouched: $kpm"
        continue
    }

    mod_basename=$(basename "$kpm" .kpm)
    case "$mod_basename" in
        ''|.|..|*[!A-Za-z0-9_.-]*)
            service_log "ERROR: unsafe KPM basename left untouched: $mod_basename"
            continue
            ;;
    esac

    # Only an explicit autoload marker authorizes boot-time loading. If a KPM
    # arrived after post-fs admission, preserve it in quarantine transaction.
    if [ ! -f "$KPM_EVENT_DIR/${mod_basename}.autoload" ] \
        || [ -L "$KPM_EVENT_DIR/${mod_basename}.autoload" ]; then
        store_transaction "$kpm" "$KPM_QUARANTINE_DIR" autoload-disabled || true
        continue
    fi

    args=""
    if [ -e "$KPM_EVENT_DIR/${mod_basename}.args" ]; then
        if [ ! -f "$KPM_EVENT_DIR/${mod_basename}.args" ] \
            || [ -L "$KPM_EVENT_DIR/${mod_basename}.args" ]; then
            service_log "ERROR: unsafe args sidecar; quarantining $mod_basename"
            store_transaction "$kpm" "$KPM_FAILED_DIR" load-failed || true
            continue
        fi
        _args_size=$(wc -c <"$KPM_EVENT_DIR/${mod_basename}.args" 2>/dev/null || true)
        case "$_args_size" in ''|*[!0-9]*) _args_size=999999 ;; esac
        if [ "$_args_size" -gt 1024 ] \
            || LC_ALL=C grep -q '[[:cntrl:]]' "$KPM_EVENT_DIR/${mod_basename}.args" 2>/dev/null; then
            service_log "ERROR: invalid args sidecar; quarantining $mod_basename"
            store_transaction "$kpm" "$KPM_FAILED_DIR" load-failed || true
            continue
        fi
        args=$(cat "$KPM_EVENT_DIR/${mod_basename}.args" 2>/dev/null || true)
    fi

    _kpm_sig="$KPM_DIR/${mod_basename}.kpm.sig"
    if [ "$KPM_SIGNATURE_POLICY" = "strict" ]; then
        if [ ! -f "$_kpm_sig" ] || [ -L "$_kpm_sig" ]; then
            service_log "REJECTED strict unsigned: ${mod_basename}.kpm"
            store_transaction "$kpm" "$KPM_FAILED_DIR" unsigned-strict || true
            continue
        fi
        if [ "$SIGNATURE_READY" != "true" ]; then
            service_log "ERROR: signature verifier unavailable; leaving signed KPM for retry: $mod_basename"
            continue
        fi
        if ! verify_kpm_sig "$kpm" "$_kpm_sig"; then
            service_log "REJECTED invalid signature: ${mod_basename}.kpm"
            store_transaction "$kpm" "$KPM_FAILED_DIR" invalid-signature || true
            continue
        fi
    elif [ "$KPM_SIGNATURE_POLICY" = "warn" ]; then
        if [ ! -f "$_kpm_sig" ] || [ -L "$_kpm_sig" ]; then
            service_log "WARN unsigned: ${mod_basename}.kpm"
            printf 'unsigned:%s:%s\n' "${mod_basename}.kpm" "$(date +%s)" >>"$UNSIGNED_LOG"
        elif [ "$SIGNATURE_READY" != "true" ]; then
            service_log "ERROR: signature verifier unavailable; leaving KPM for retry: $mod_basename"
            continue
        elif ! verify_kpm_sig "$kpm" "$_kpm_sig"; then
            service_log "REJECTED invalid signature: ${mod_basename}.kpm"
            store_transaction "$kpm" "$KPM_FAILED_DIR" invalid-signature || true
            continue
        fi
    fi

    if [ -n "$args" ]; then
        kpatch kpm load "$kpm" -- "$args"
    else
        kpatch kpm load "$kpm"
    fi
    if [ "$?" -ne 0 ]; then
        service_log "KPM load failed: ${mod_basename}.kpm"
        store_transaction "$kpm" "$KPM_FAILED_DIR" load-failed || true
    else
        service_log "Loaded: ${mod_basename}.kpm"
    fi
done

if [ -n "$REHOOK" ]; then
    if kpatch rehook "$REHOOK" >/dev/null 2>&1; then
        service_log "rehook $REHOOK"
    else
        service_log "WARNING: rehook $REHOOK failed"
    fi
fi

# Event names are fixed constants, not user input.
dispatch_event() {
    service_log "Dispatching event: $1"
    kpatch event "$1" "" "" >/dev/null 2>&1 \
        || service_log "WARNING: event dispatch failed: $1"
}

dispatch_event POST_FS_DATA

wait_count=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    sleep 1
    wait_count=$((wait_count + 1))
    if [ "$wait_count" -ge 300 ]; then
        service_log "WARNING: boot_completed timeout"
        break
    fi
done

dispatch_event BOOT_COMPLETED

# Apply the bounded CSV exclusion configuration. Package and UID values are
# compared as awk data rather than interpolated into regular expressions.
if [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ]; then
    _config_size=$(wc -c <"$CONFIG" 2>/dev/null || true)
    case "$_config_size" in ''|*[!0-9]*) _config_size=99999999 ;; esac
    if [ "$_config_size" -le 1048576 ]; then
        excluded_count=0
        excluded_failed=0
        _line_count=0
        while IFS=, read -r pkg exclude allow uid extra; do
            _line_count=$((_line_count + 1))
            [ "$_line_count" -eq 1 ] && continue
            [ "$_line_count" -le 10000 ] || {
                service_log "WARNING: exclusion config exceeds 10000 lines"
                break
            }
            [ -z "${extra:-}" ] || {
                excluded_failed=$((excluded_failed + 1))
                continue
            }
            case "$pkg" in
                ''|*[!A-Za-z0-9_.]*)
                    excluded_failed=$((excluded_failed + 1))
                    continue
                    ;;
            esac
            case "$uid" in
                ''|*[!0-9]*)
                    excluded_failed=$((excluded_failed + 1))
                    continue
                    ;;
            esac
            [ "$exclude" = "1" ] || continue
            UID_VAL=$(awk -v package="$pkg" -v wanted_uid="$uid" \
                '$1 == package && $2 == wanted_uid { print $2; exit }' \
                /data/system/packages.list 2>/dev/null)
            if [ "$UID_VAL" = "$uid" ] && kpatch exclude_set "$uid" 1 >/dev/null 2>&1; then
                excluded_count=$((excluded_count + 1))
            else
                excluded_failed=$((excluded_failed + 1))
            fi
        done <"$CONFIG"
        service_log "exclusion applied=$excluded_count failed=$excluded_failed"
    else
        service_log "WARNING: exclusion config exceeds 1 MiB and was ignored"
    fi
fi

service_log "service.sh completed"
exit 0
