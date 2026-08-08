#!/system/bin/sh
# PatchNest physical-device validation harness.
#
# Default phases are read-only. Destructive restore/KPM-cycle phases require an
# exact unlock token and are never run automatically by the module or CI.
#
# Usage:
#   sh device_validation.sh preflight
#   sh device_validation.sh postboot
#   sh device_validation.sh rollback-check
#   PATCHNEST_DEVICE_TEST_UNLOCK=RESTORE_BOUND_BACKUP sh device_validation.sh restore
#   PATCHNEST_DEVICE_TEST_UNLOCK=KPM_CYCLE sh device_validation.sh kpm-cycle /path/test.kpm

set -u

MODE=${1:-preflight}
shift 2>/dev/null || true
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
    name=$1
    shift
    {
        printf '### %s\n' "$name"
        "$@"
        rc=$?
        printf 'exit=%s\n\n' "$rc"
        return "$rc"
    } >> "$LOG" 2>&1
}

json_string() {
    key=$1
    file=$2
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
        | head -n 1 \
        | sed -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/"
}

json_number() {
    key=$1
    file=$2
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" "$file" 2>/dev/null \
        | head -n 1 \
        | sed -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*([0-9][0-9]*).*/\\1/"
}

hash_prefix() {
    target=$1
    size=$2
    printf '%s' "$size" | grep -Eq '^[1-9][0-9]*$' || return 1
    blocks=$(((size + 1048575) / 1048576))
    dd if="$target" bs=1048576 count="$blocks" 2>/dev/null \
        | head -c "$size" \
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
}

resolve_target() {
    out=$(PATH="$MODDIR/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH" \
        "$MODDIR/patch/boot_extract.sh" false 2>>"$LOG") || fail "boot target resolution failed"
    printf '%s\n' "$out" >> "$LOG"
    TARGET=$(printf '%s\n' "$out" | sed -n 's/^BOOTIMAGE=//p' | tail -n 1)
    [ -n "$TARGET" ] || fail "boot target was not emitted"
    TARGET=$(readlink -f "$TARGET" 2>/dev/null || printf '%s' "$TARGET")
    [ -e "$TARGET" ] || fail "resolved target does not exist: $TARGET"
}

copy_if_present() {
    src=$1
    name=$2
    [ -f "$src" ] || return 0
    cp "$src" "$EVIDENCE/$name" 2>/dev/null || true
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

    if [ -f "$MODDIR/module.prop" ]; then
        cp "$MODDIR/module.prop" "$EVIDENCE/module.prop"
    fi
    copy_if_present "$MODDIR/provenance/kpatch-public1158.json" "kpatch-public1158.json"
    copy_if_present "$PNDIR/last_flash.json" "last_flash.json"
    copy_if_present "$PNDIR/rollback_binding.json" "rollback_binding.json"
    copy_if_present "$PNDIR/abi_profile" "abi_profile"
    copy_if_present "$PNDIR/service.log" "service.log"

    if [ -f "$PNDIR/superkey" ]; then
        key_mode=$(stat -c '%a' "$PNDIR/superkey" 2>/dev/null || printf unknown)
        key_sha=$(sha256sum "$PNDIR/superkey" 2>/dev/null | awk '{print $1}')
        log "superkey_present=1"
        log "superkey_mode=$key_mode"
        log "superkey_file_sha256=$key_sha"
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
    tmp=$(mktemp -d /data/local/tmp/patchnest-device-unpack.XXXXXX) || fail "cannot create unpack workspace"
    if ! (cd "$tmp" && "$MODDIR/bin/magiskboot" unpack "$TARGET" >/dev/null 2>&1); then
        rm -rf "$tmp"
        fail "magiskboot cannot unpack resolved target"
    fi
    [ -s "$tmp/kernel" ] || {
        rm -rf "$tmp"
        fail "resolved target unpack produced no kernel"
    }
    PATH="$MODDIR/bin:$PATH" "$MODDIR/bin/kptools" -i "$tmp/kernel" -l > "$EVIDENCE/kernel-info.txt" 2>&1 || true
    rm -rf "$tmp"
}

validate_binding_read_only() {
    binding="$PNDIR/rollback_binding.json"
    [ -f "$binding" ] || fail "rollback binding is missing"

    recorded_target=$(json_string boot_target "$binding")
    recorded_device=$(json_string device_binding_sha256 "$binding")
    backup_name=$(json_string rollback_backup "$binding")
    backup_sha=$(json_string rollback_backup_sha256 "$binding")
    patched_sha=$(json_string patched_image_sha256 "$binding")
    patched_size=$(json_number patched_image_size "$binding")

    [ "$recorded_target" = "$TARGET" ] || fail "binding target mismatch"
    printf '%s' "$recorded_device" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid device binding digest"
    printf '%s' "$backup_sha" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid rollback digest"
    printf '%s' "$patched_sha" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid patched digest"
    printf '%s' "$patched_size" | grep -Eq '^[1-9][0-9]*$' || fail "invalid patched size"

    # shellcheck disable=SC1091
    . "$MODDIR/patch/util_functions.sh"
    # shellcheck disable=SC1091
    . "$MODDIR/patch/flash_safety.sh"
    current_device=$(patchnest_device_binding_sha256) || fail "cannot derive device binding"
    [ "$current_device" = "$recorded_device" ] || fail "device binding mismatch"

    case "$backup_name" in
        boot_backup_*.img) ;;
        *) fail "unsafe backup name in rollback binding" ;;
    esac
    case "$backup_name" in
        */*|*..*) fail "unsafe backup path in rollback binding" ;;
    esac
    backup="$PNDIR/backup/$backup_name"
    [ -f "$backup" ] || fail "rollback backup missing"
    [ "$(sha256sum "$backup" | awk '{print $1}')" = "$backup_sha" ] || fail "rollback backup SHA mismatch"

    current_sha=$(hash_prefix "$TARGET" "$patched_size") || fail "cannot hash current patched byte range"
    [ "$current_sha" = "$patched_sha" ] || fail "current boot no longer matches committed patched transaction"
    log "rollback_binding_eligible=1"
    log "rollback_backup=$backup_name"
}

finalize() {
    bundle="/storage/emulated/0/Download/PatchNest_Device_Evidence_${STAMP}_${MODE}.tar.gz"
    if [ -d /storage/emulated/0/Download ] && command -v tar >/dev/null 2>&1; then
        tar -czf "$bundle" -C "${EVIDENCE%/*}" "${EVIDENCE##*/}" 2>/dev/null \
            && log "evidence_bundle=$bundle" \
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
        hello=$(PATH="$MODDIR/bin:$PATH" kpatch hello 2>>"$LOG") || fail "kpatch hello failed"
        [ "$hello" = "hello1158" ] || fail "unexpected ABI hello: $hello"
        log "hello=$hello"
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
        candidate=${1:-}
        [ "${PATCHNEST_DEVICE_TEST_UNLOCK:-}" = "KPM_CYCLE" ] \
            || fail "KPM cycle requires PATCHNEST_DEVICE_TEST_UNLOCK=KPM_CYCLE"
        [ -f "$candidate" ] || fail "KPM candidate missing: $candidate"
        meta=$(PATH="$MODDIR/bin:$PATH" kptools -l -M "$candidate" 2>>"$LOG") || fail "candidate metadata validation failed"
        name=$(printf '%s\n' "$meta" | sed -n 's/^name=//p' | head -n 1)
        [ -n "$name" ] || fail "candidate KPM has no name"
        log "kpm_candidate=$candidate"
        log "kpm_name=$name"
        PATH="$MODDIR/bin:$PATH" kpatch kpm load "$candidate" >> "$LOG" 2>&1 || fail "KPM load failed"
        PATH="$MODDIR/bin:$PATH" kpatch kpm info "$name" >> "$LOG" 2>&1 || {
            PATH="$MODDIR/bin:$PATH" kpatch kpm unload "$name" >> "$LOG" 2>&1 || true
            fail "KPM info failed after load"
        }
        PATH="$MODDIR/bin:$PATH" kpatch kpm unload "$name" >> "$LOG" 2>&1 || fail "KPM unload failed"
        log "result=KPM_CYCLE_PASS"
        ;;

    *)
        fail "unknown mode: $MODE"
        ;;
esac

finalize
exit 0
