#!/system/bin/sh
# PatchNest physical-device validation harness.
# Read-only by default. Destructive modes require exact unlock tokens.

set -u

MODE=${1:-preflight}
[ "$#" -gt 0 ] && shift
SCRIPT_DIR=${0%/*}
MODDIR=${PATCHNEST_MODDIR:-$SCRIPT_DIR}
MODDIR=$(readlink -f "$MODDIR" 2>/dev/null || printf '%s' "$MODDIR")
PNDIR=${PATCHNEST_STATE_DIR:-/data/adb/patchnest}
STAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%S)
EVIDENCE=${PATCHNEST_EVIDENCE_DIR:-/data/local/tmp/patchnest-evidence-$STAMP}
LOG="$EVIDENCE/validation.log"
TARGET=''

mkdir -p "$EVIDENCE" || exit 1
chmod 0700 "$EVIDENCE" 2>/dev/null || true

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }

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

json_bool() {
    _pn_key=$1
    _pn_file=$2
    grep -Eo "\"${_pn_key}\"[[:space:]]*:[[:space:]]*(true|false)" "$_pn_file" 2>/dev/null \
        | head -n 1 \
        | sed -E "s/.*\"${_pn_key}\"[[:space:]]*:[[:space:]]*(true|false).*/\\1/"
}

hash_prefix() {
    _pn_target=$1
    _pn_size=$2
    printf '%s' "$_pn_size" | grep -Eq '^[1-9][0-9]*$' || return 1
    _pn_blocks=$(((_pn_size + 1048575) / 1048576))
    dd if="$_pn_target" bs=1048576 count="$_pn_blocks" 2>/dev/null \
        | head -c "$_pn_size" | sha256sum | awk '{print $1}'
}

require_root() { [ "$(id -u 2>/dev/null)" = "0" ] || fail "root shell required"; }

require_module_tree() {
    [ -d "$MODDIR" ] || fail "module directory missing: $MODDIR"
    [ -x "$MODDIR/bin/kpatch" ] || fail "kpatch missing"
    [ -x "$MODDIR/bin/kptools" ] || fail "kptools missing"
    [ -x "$MODDIR/bin/magiskboot" ] || fail "magiskboot missing"
    [ -f "$MODDIR/patch/transaction_safety.sh" ] || fail "transaction helper missing"
    [ -f "$MODDIR/patch/transactional_flash.sh" ] || fail "transactional writer missing"
    [ -x "$MODDIR/patch/boot_unpatch.sh" ] || fail "bound restore helper missing or not executable"
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
    copy_if_present "$PNDIR/last_restore.json" "last_restore.json"
    copy_if_present "$PNDIR/rollback_binding.json" "rollback_binding.json"
    copy_if_present "$PNDIR/transaction.pending.json" "transaction.pending.json"
    copy_if_present "$PNDIR/flash_recovery_required" "flash_recovery_required"
    copy_if_present "$PNDIR/abi_profile" "abi_profile"
    copy_if_present "$PNDIR/service.log" "service.log"

    if [ -f "$PNDIR/superkey" ]; then
        log "superkey_present=1"
        log "superkey_mode=$(stat -c '%a' "$PNDIR/superkey" 2>/dev/null || printf unknown)"
        log "superkey_file_sha256=$(sha256sum "$PNDIR/superkey" 2>/dev/null | awk '{print $1}')"
    else
        log "superkey_present=0"
    fi
    [ -f "$PNDIR/superkey.pending" ] && log "pending_superkey_present=1" || log "pending_superkey_present=0"
    [ -f "$PNDIR/transaction.pending.json" ] && log "pending_transaction_present=1" || log "pending_transaction_present=0"
    [ -f "$PNDIR/flash_recovery_required" ] && log "recovery_required=1" || log "recovery_required=0"
    [ -f "$MODDIR/FLASH_REVIEW_BLOCKED" ] && log "flash_review_blocked=1" || log "flash_review_blocked=0"
}

validate_target_unpack() {
    _pn_tmp=$(mktemp -d /data/local/tmp/patchnest-device-unpack.XXXXXX) || fail "cannot create unpack workspace"
    if ! (cd "$_pn_tmp" && "$MODDIR/bin/magiskboot" unpack "$TARGET" >/dev/null 2>&1); then
        rm -rf "$_pn_tmp"; fail "magiskboot cannot unpack resolved target"
    fi
    [ -s "$_pn_tmp/kernel" ] || { rm -rf "$_pn_tmp"; fail "resolved target unpack produced no kernel"; }
    if ! PATH="$MODDIR/bin:$PATH" "$MODDIR/bin/kptools" -i "$_pn_tmp/kernel" -l > "$EVIDENCE/kernel-info.txt" 2>&1; then
        rm -rf "$_pn_tmp"; fail "kptools cannot inspect resolved target kernel"
    fi
    rm -rf "$_pn_tmp"
}

require_clean_fr014_candidate() {
    # Review packages remain intentionally blocked and are allowed to collect
    # read-only diagnostics. A flashable FR-014 candidate must be explicitly
    # marked and start from a clean pre-test state so old PatchNest artifacts
    # cannot contaminate the lifecycle evidence.
    [ ! -f "$MODDIR/FLASH_REVIEW_BLOCKED" ] || return 0
    [ -f "$MODDIR/FR014_DEVICE_CANDIDATE" ] || fail "unblocked package is not an FR-014 device candidate"
    [ ! -f "$MODDIR/unresolved" ] || fail "module is already marked unresolved"

    for _pn_stale in \
        rollback_binding.json \
        transaction.pending.json \
        flash_recovery_required \
        superkey \
        superkey.pending \
        last_flash.json \
        last_restore.json \
        auto_unpatch_requested \
        autorecovery_active \
        auto_recovery_restored \
        credential_recovered_pending; do
        [ ! -e "$PNDIR/$_pn_stale" ] || fail "stale PatchNest state blocks clean FR-014 preflight: $_pn_stale"
    done

    if [ -f "$PNDIR/boot_count" ]; then
        _pn_boot_count=$(tr -cd '0-9' < "$PNDIR/boot_count" 2>/dev/null | head -c 6)
        [ -z "$_pn_boot_count" ] || [ "$_pn_boot_count" -eq 0 ] 2>/dev/null \
            || fail "non-zero historical boot_count blocks clean FR-014 preflight"
    fi

    _pn_old_kpm=''
    if [ -d "$PNDIR/kpm" ]; then
        _pn_old_kpm=$(find "$PNDIR/kpm" -maxdepth 1 -type f \( -name '*.kpm' -o -name '*.ko' -o -name '*.o' \) -print -quit 2>/dev/null)
    fi
    [ -z "$_pn_old_kpm" ] || fail "pre-existing runtime KPM blocks clean FR-014 preflight: $(basename "$_pn_old_kpm")"

    if grep -Eq '(^|[[:space:]])patched[[:space:]]*=[[:space:]]*true([[:space:]]|$)' "$EVIDENCE/kernel-info.txt"; then
        fail "resolved boot kernel is already KernelPatch-patched; clean FR-014 baseline required"
    fi
}

run_production_rollback_check() {
    _pn_binding=${1:-$PNDIR/rollback_binding.json}
    PATCHNEST_ROLLBACK_BINDING_FILE="$_pn_binding" \
      PATH="$MODDIR/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH" \
      "$MODDIR/patch/boot_unpatch.sh" --check-bound-backup "$TARGET"
}

finalize() {
    _pn_bundle="/storage/emulated/0/Download/PatchNest_Device_Evidence_${STAMP}_${MODE}.tar.gz"
    if [ -d /storage/emulated/0/Download ] && command -v tar >/dev/null 2>&1; then
        tar -czf "$_pn_bundle" -C "${EVIDENCE%/*}" "${EVIDENCE##*/}" 2>/dev/null \
            && log "evidence_bundle=$_pn_bundle" || log "evidence_bundle_failed=1"
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
        [ ! -f "$PNDIR/transaction.pending.json" ] || fail "unfinished flash transaction already exists"
        [ ! -f "$PNDIR/flash_recovery_required" ] || fail "flash recovery is already required"
        require_clean_fr014_candidate
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
        [ ! -e "$PNDIR/superkey.pending" ] || fail "unexpected pending credential after healthy boot"
        [ ! -e "$PNDIR/transaction.pending.json" ] || fail "unexpected pending transaction after healthy boot"
        [ ! -e "$PNDIR/flash_recovery_required" ] || fail "recovery marker present after healthy boot"
        run_production_rollback_check >> "$LOG" 2>&1 || fail "production rollback validator rejected live transaction"
        [ ! -f "$MODDIR/unresolved" ] || fail "module runtime marked unresolved"
        log "result=POSTBOOT_PASS"
        ;;

    rollback-check)
        run_production_rollback_check >> "$LOG" 2>&1 || fail "production rollback validator rejected live transaction"
        log "result=ROLLBACK_ELIGIBLE"
        ;;

    rollback-negative)
        run_production_rollback_check >> "$LOG" 2>&1 || fail "real binding must be eligible before negative tests"
        _pn_real="$PNDIR/rollback_binding.json"
        [ -f "$_pn_real" ] || fail "rollback binding missing"
        _pn_foreign="$EVIDENCE/rollback.foreign-device.json"
        _pn_stale="$EVIDENCE/rollback.stale-bytes.json"
        _pn_zero='0000000000000000000000000000000000000000000000000000000000000000'
        _pn_ff='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'

        awk -v v="$_pn_zero" '{
          if ($0 ~ /"device_binding_sha256"/) print "  \"device_binding_sha256\": \"" v "\",";
          else print $0
        }' "$_pn_real" > "$_pn_foreign"
        chmod 0600 "$_pn_foreign"
        if run_production_rollback_check "$_pn_foreign" >> "$LOG" 2>&1; then
            fail "foreign-device binding copy was incorrectly accepted"
        fi

        awk -v v="$_pn_ff" '{
          if ($0 ~ /"patched_image_sha256"/) print "  \"patched_image_sha256\": \"" v "\",";
          else print $0
        }' "$_pn_real" > "$_pn_stale"
        chmod 0600 "$_pn_stale"
        if run_production_rollback_check "$_pn_stale" >> "$LOG" 2>&1; then
            fail "stale-byte binding copy was incorrectly accepted"
        fi
        log "result=ROLLBACK_NEGATIVE_PASS"
        ;;

    restore)
        [ "${PATCHNEST_DEVICE_TEST_UNLOCK:-}" = "RESTORE_BOUND_BACKUP" ] \
            || fail "restore requires PATCHNEST_DEVICE_TEST_UNLOCK=RESTORE_BOUND_BACKUP"
        run_production_rollback_check >> "$LOG" 2>&1 || fail "rollback not eligible before destructive restore"
        cp "$PNDIR/rollback_binding.json" "$EVIDENCE/rollback_binding.before-restore.json"
        log "destructive_restore=START"
        PATH="$MODDIR/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH" \
          "$MODDIR/patch/boot_unpatch.sh" --restore-bound-backup "$TARGET" >> "$LOG" 2>&1 \
          || fail "bound-backup restore failed"
        [ -f "$PNDIR/last_restore.json" ] || fail "restore receipt missing"
        log "destructive_restore=PASS"
        log "result=RESTORE_WRITE_VERIFIED_REBOOT_REQUIRED"
        ;;

    postrestore)
        [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] || fail "Android did not reach boot_completed after restore"
        _pn_receipt="$PNDIR/last_restore.json"
        [ -f "$_pn_receipt" ] || fail "last_restore.json missing"
        [ "$(json_bool verified_readback "$_pn_receipt")" = "true" ] || fail "restore receipt is not readback-qualified"
        _pn_receipt_target=$(json_string boot_target "$_pn_receipt")
        _pn_receipt_device=$(json_string device_binding_sha256 "$_pn_receipt")
        _pn_restore_sha=$(json_string restored_backup_sha256 "$_pn_receipt")
        _pn_restore_size=$(json_number restored_backup_size "$_pn_receipt")
        [ "$_pn_receipt_target" = "$TARGET" ] || fail "postrestore target differs from receipt"
        printf '%s' "$_pn_receipt_device$_pn_restore_sha" | grep -Eq '^[0-9a-f]{128}$' || fail "restore receipt digest fields invalid"
        printf '%s' "$_pn_restore_size" | grep -Eq '^[1-9][0-9]*$' || fail "restore receipt size invalid"
        _pn_now=$(hash_prefix "$TARGET" "$_pn_restore_size") || fail "cannot hash restored boot byte range"
        [ "$_pn_now" = "$_pn_restore_sha" ] || fail "current boot bytes differ from restored backup receipt"
        [ ! -e "$PNDIR/rollback_binding.json" ] || fail "rollback authorization still live after restore"
        [ ! -e "$PNDIR/transaction.pending.json" ] || fail "pending transaction survived restore"
        [ ! -e "$PNDIR/flash_recovery_required" ] || fail "recovery marker survived successful restore"
        log "result=POSTRESTORE_PASS"
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
        PATH="$MODDIR/bin:$PATH" kpatch kpm load "$_pn_candidate" >> "$LOG" 2>&1 || fail "KPM load failed"
        PATH="$MODDIR/bin:$PATH" kpatch kpm info "$_pn_name" >> "$LOG" 2>&1 || {
            PATH="$MODDIR/bin:$PATH" kpatch kpm unload "$_pn_name" >> "$LOG" 2>&1 || true
            fail "KPM info failed after load"
        }
        PATH="$MODDIR/bin:$PATH" kpatch kpm unload "$_pn_name" >> "$LOG" 2>&1 || fail "KPM unload failed"
        log "result=KPM_CYCLE_PASS"
        ;;

    *) fail "unknown mode: $MODE" ;;
esac

finalize
exit 0
