#!/system/bin/sh
# PatchNest physical-device validation harness.
# Read-only by default. Destructive modes require exact unlock tokens.

set -u

MODE=${1:-preflight}
[ "$#" -gt 0 ] && shift
MODDIR=${PATCHNEST_MODDIR:-/data/adb/modules/PatchNest}
PNDIR=${PATCHNEST_STATE_DIR:-/data/adb/patchnest}
STAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%S)
EVIDENCE=${PATCHNEST_EVIDENCE_DIR:-/data/local/tmp/patchnest-evidence-$STAMP}
LOG="$EVIDENCE/validation.log"
TARGET=''

mkdir -p "$EVIDENCE" || exit 1
chmod 0700 "$EVIDENCE" 2>/dev/null || true

log() {
    printf '%s\n' "$*" | tee -a "$LOG"
}

fail() {
    log "FAIL: $*"
    exit 1
}

record_cmd() {
    _pn_name=$1
    shift
    {
        printf '### %s\n' "$_pn_name"
        "$@"
        _pn_rc=$?
        printf 'exit=%s\n\n' "$_pn_rc"
        return "$_pn_rc"
    } >> "$LOG" 2>&1
}

json_string() {
    _pn_key=$1
    _pn_file=$2
    grep -o "\"${_pn_key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$_pn_file" 2>/dev/null \
        | head -n 1 \
        | sed -E "s/.*\"${_pn_key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/"
}

json_number() {
    _pn_key=$1
    _pn_file=$2
    grep -o "\"${_pn_key}\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" "$_pn_file" 2>/dev/null \
        | head -n 1 \
        | sed -E "s/.*\"${_pn_key}\"[[:space:]]*:[[:space:]]*([0-9][0-9]*).*/\\1/"
}

hash_prefix() {
    _pn_target=$1
    _pn_size=$2
    printf '%s' "$_pn_size" | grep -Eq '^[1-9][0-9]*$' || return 1
    _pn_blocks=$(((_pn_size + 1048575) / 1048576))
    dd if="$_pn_target" bs=1048576 count="$_pn_blocks" 2>/dev/null \
        | head -c "$_pn_size" \
        | sha256sum \
        | awk '{print $1}'
}

require_root() {
    [ "$(id -u 2>/dev/null)" = "0" ] || fail "root shell required"
}

require_module_tree() {
    [ -d "$MODDIR" ] || fail "module directory missing: $MODDIR"
    [ -x "$MODDIR/bin/kpatch" ] || fail "kpatch missing"
    [ -x "$MODDIR/bin/kptools" ] || fail "kptools missing"
    [ -x "$MODDIR/bin/magiskboot" ] || fail "magiskboot missing"
    [ -f "$MODDIR/patch/transaction_safety.sh" ] || fail "transaction helper missing"
}

resolve_target() {
    _pn_out=$(PATH="$MODDIR/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH" \
        "$MODDIR/patch/boot_extract.sh" false 2>>"$LOG") || fail "boot target resolution failed"
    printf '%s\n' "$_pn_out" >> "$LOG"
    TARGET=$(printf '%s\n' "$_pn_out" | sed -n 's/^BOOTIMAGE=//p' | tail -n 1)
    [ -n "$TARGET" ] || fail "boot target was not emitted"
    TARGET=$(readlink -f "$TARGET" 2>/dev/null || printf '%s' "$TARGET")
    [ -e "$TARGET" ] || fail "resolved target does not exist: $TARGET"
}

copy_if_present() {
    _pn_src=$1
    _pn_name=$2
    [ -f "$_pn_src" ] || return 0
    cp "$_pn_src" "$EVIDENCE/$_pn_name" 2>/dev/null || true
}

collect_common() {
    log "mode=$MODE"
    log "timestamp=$STAMP"
    log "module_dir=$MODDIR"
    log "state_dir=$PNDIR"
    log "boot_target=$TARGET"
    log "boot_slot=$(getprop ro.boot.slot_suffix 2>/dev/null)"
    log "product_device=$(getprop ro.product.device 2>/dev/null)"
    log "boot_completed=$(getprop sys.boot_completed 2>/dev/null)"
    log "vbmeta_device_state=$(getprop ro.boot.vbmeta.device_state 2>/dev/null)"

    copy_if_present "$MODDIR/module.prop" "module.prop"
    copy_if_present "$MODDIR/provenance/kpatch-public1158.json" "kpatch-public1158.json"
    copy_if_present "$PNDIR/last_flash.json" "last_flash.json"
    copy_if_present "$PNDIR/rollback_binding.json" "rollback_binding.json"
    copy_if_present "$PNDIR/abi_profile" "abi_profile"
    copy_if_present "$PNDIR/service.log" "service.log"

    if [ -f "$PNDIR/superkey" ]; then
        log "superkey_present=1"
        log "superkey_mode=$(stat -c '%a' "$PNDIR/superkey" 2>/dev/null || printf unknown)"
        log "superkey_file_sha256=$(sha256sum "$PNDIR/superkey" 2>/dev/null | awk '{print $1}')"
    else
        log "superkey_present=0"
    fi

    if [ -f "$MODDIR/FLASH_REVIEW_BLOCKED" ]; then
        log "flash_review_blocked=1"
    else
        log "flash_review_blocked=0"
    fi
}

validate_target_unpack() {
    _pn_tmp=$(mktemp -d /data/local/tmp/patchnest-device-unpack.XXXXXX) || fail "cannot create unpack workspace"
    if ! (cd "$_pn_tmp" && "$MODDIR/bin/magiskboot" unpack "$TARGET" >/dev/null 2>&1); then
        rm -rf "$_pn_tmp"
        fail "magiskboot cannot unpack resolved target"
    fi
    [ -s "$_pn_tmp/kernel" ] || {
        rm -rf "$_pn_tmp"
        fail "resolved target unpack produced no kernel"
    }
    PATH="$MODDIR/bin:$PATH" "$MODDIR/bin/kptools" -i "$_pn_tmp/kernel" -l \
        > "$EVIDENCE/kernel-info.txt" 2>&1 || true
    rm -rf "$_pn_tmp"
}

load_transaction_context() {
    # The installed helpers intentionally key device identity to BOOT_TARGET and
    # discover transaction_safety.sh through MODPATH. Map validation state onto
    # those exact production variable names before sourcing the reviewed code.
    MODPATH="$MODDIR/patch"
    BOOT_TARGET="$TARGET"
    export MODPATH BOOT_TARGET
    # shellcheck disable=SC1090
    . "$MODDIR/patch/util_functions.sh"
    # shellcheck disable=SC1090
    . "$MODDIR/patch/flash_safety.sh"
    command -v patchnest_device_binding_sha256 >/dev/null 2>&1 \
        || fail "transaction identity helper was not loaded"
}

validate_binding_read_only() {
    _pn_binding="$PNDIR/rollback_binding.json"
    [ -f "$_pn_binding" ] || fail "rollback binding is missing"

    _pn_recorded_target=$(json_string boot_target "$_pn_binding")
    _pn_recorded_device=$(json_string device_binding_sha256 "$_pn_binding")
    _pn_backup_name=$(json_string rollback_backup "$_pn_binding")
    _pn_backup_sha=$(json_string rollback_backup_sha256 "$_pn_binding")
    _pn_patched_sha=$(json_string patched_image_sha256 "$_pn_binding")
    _pn_patched_size=$(json_number patched_image_size "$_pn_binding")

    [ "$_pn_recorded_target" = "$TARGET" ] || fail "binding target mismatch"
    printf '%s' "$_pn_recorded_device" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid device binding digest"
    printf '%s' "$_pn_backup_sha" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid rollback digest"
    printf '%s' "$_pn_patched_sha" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid patched digest"
    printf '%s' "$_pn_patched_size" | grep -Eq '^[1-9][0-9]*$' || fail "invalid patched size"

    load_transaction_context
    _pn_current_device=$(patchnest_device_binding_sha256) || fail "cannot derive device binding"
    [ "$_pn_current_device" = "$_pn_recorded_device" ] || fail "device binding mismatch"

    case "$_pn_backup_name" in
        boot_backup_*.img) ;;
        *) fail "unsafe backup name in rollback binding" ;;
    esac
    case "$_pn_backup_name" in
        */*|*..*) fail "unsafe backup path in rollback binding" ;;
    esac

    _pn_backup="$PNDIR/backup/$_pn_backup_name"
    [ -f "$_pn_backup" ] || fail "rollback backup missing"
    [ "$(sha256sum "$_pn_backup" | awk '{print $1}')" = "$_pn_backup_sha" ] \
        || fail "rollback backup SHA mismatch"

    _pn_current_sha=$(hash_prefix "$TARGET" "$_pn_patched_size") \
        || fail "cannot hash current patched byte range"
    [ "$_pn_current_sha" = "$_pn_patched_sha" ] \
        || fail "current boot no longer matches committed patched transaction"

    log "rollback_binding_eligible=1"
    log "rollback_backup=$_pn_backup_name"
}

finalize() {
    _pn_bundle="/storage/emulated/0/Download/PatchNest_Device_Evidence_${STAMP}_${MODE}.tar.gz"
    if [ -d /storage/emulated/0/Download ] && command -v tar >/dev/null 2>&1; then
        tar -czf "$_pn_bundle" -C "${EVIDENCE%/*}" "${EVIDENCE##*/}" 2>/dev/null \
            && log "evidence_bundle=$_pn_bundle" \
            || log "evidence_bundle_failed=1"
    fi
    log "evidence_dir=$EVIDENCE"
}

require_root
require_module_tree
resolve_target
collect_common

case "$MODE" in
    preflight)
        validate_target_unpack
        record_cmd "kpatch file digest" sha256sum "$MODDIR/bin/kpatch" || true
        record_cmd "kptools file digest" sha256sum "$MODDIR/bin/kptools" || true
        record_cmd "kpimg file digest" sha256sum "$MODDIR/bin/kpimg" || true
        if [ -f "$MODDIR/FLASH_REVIEW_BLOCKED" ]; then
            log "result=REVIEW_PACKAGE_INTENTIONALLY_BLOCKED"
        else
            log "result=PREFLIGHT_PASS"
        fi
        ;;

    postboot)
        [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] || fail "Android boot_completed is not 1"
        _pn_hello=$(PATH="$MODDIR/bin:$PATH" kpatch hello 2>>"$LOG") || fail "kpatch hello failed"
        [ "$_pn_hello" = "hello1158" ] || fail "unexpected ABI hello: $_pn_hello"
        log "hello=$_pn_hello"
        record_cmd "kpver" env PATH="$MODDIR/bin:$PATH" kpatch kpver || fail "kpver failed"
        record_cmd "kpm num" env PATH="$MODDIR/bin:$PATH" kpatch kpm num || fail "kpm num failed"
        record_cmd "kpm list" env PATH="$MODDIR/bin:$PATH" kpatch kpm list || fail "kpm list failed"
        [ -f "$PNDIR/superkey" ] || fail "superkey was not committed"
        [ "$(stat -c '%a' "$PNDIR/superkey" 2>/dev/null)" = "600" ] || fail "superkey permissions are not 0600"
        validate_binding_read_only
        [ ! -f "$MODDIR/unresolved" ] || fail "module runtime marked unresolved"
        log "result=POSTBOOT_PASS"
        ;;

    rollback-check)
        validate_binding_read_only
        log "result=ROLLBACK_ELIGIBLE"
        ;;

    restore)
        [ "${PATCHNEST_DEVICE_TEST_UNLOCK:-}" = "RESTORE_BOUND_BACKUP" ] \
            || fail "restore requires PATCHNEST_DEVICE_TEST_UNLOCK=RESTORE_BOUND_BACKUP"
        validate_binding_read_only
        cp "$PNDIR/rollback_binding.json" "$EVIDENCE/rollback_binding.before-restore.json"
        log "destructive_restore=START"
        PATH="$MODDIR/bin:$PATH" "$MODDIR/patch/boot_unpatch.sh" --restore-bound-backup "$TARGET" \
            >> "$LOG" 2>&1 || fail "bound-backup restore failed"
        log "destructive_restore=PASS"
        log "result=RESTORE_WRITE_VERIFIED_REBOOT_REQUIRED"
        ;;

    kpm-cycle)
        _pn_candidate=${1:-}
        [ "${PATCHNEST_DEVICE_TEST_UNLOCK:-}" = "KPM_CYCLE" ] \
            || fail "KPM cycle requires PATCHNEST_DEVICE_TEST_UNLOCK=KPM_CYCLE"
        [ -f "$_pn_candidate" ] || fail "KPM candidate missing: $_pn_candidate"
        _pn_meta=$(PATH="$MODDIR/bin:$PATH" kptools -l -M "$_pn_candidate" 2>>"$LOG") \
            || fail "candidate metadata validation failed"
        _pn_name=$(printf '%s\n' "$_pn_meta" | sed -n 's/^name=//p' | head -n 1)
        [ -n "$_pn_name" ] || fail "candidate KPM has no name"
        log "kpm_candidate=$_pn_candidate"
        log "kpm_name=$_pn_name"
        PATH="$MODDIR/bin:$PATH" kpatch kpm load "$_pn_candidate" >> "$LOG" 2>&1 \
            || fail "KPM load failed"
        PATH="$MODDIR/bin:$PATH" kpatch kpm info "$_pn_name" >> "$LOG" 2>&1 || {
            PATH="$MODDIR/bin:$PATH" kpatch kpm unload "$_pn_name" >> "$LOG" 2>&1 || true
            fail "KPM info failed after load"
        }
        PATH="$MODDIR/bin:$PATH" kpatch kpm unload "$_pn_name" >> "$LOG" 2>&1 \
            || fail "KPM unload failed"
        log "result=KPM_CYCLE_PASS"
        ;;

    *)
        fail "unknown mode: $MODE"
        ;;
esac

finalize
exit 0
