#!/system/bin/sh
#######################################################################################
# PatchNest transaction-bound boot restorer
#######################################################################################
# Usage:
#   boot_unpatch.sh <bootimage>                         # safe bound restore
#   boot_unpatch.sh --restore-bound-backup <bootimage> # same, explicit
#   boot_unpatch.sh --check-bound-backup <bootimage>   # validation only, no write
#######################################################################################

MODPATH=${0%/*}
PNDIR="/data/adb/patchnest"
BACKUP_DIR="$PNDIR/backup"
AUTORECOVERY_MARKER="$PNDIR/autorecovery_active"
RESTORE_RECEIPT="$PNDIR/last_restore.json"

# shellcheck disable=SC1091
. "$MODPATH/util_functions.sh"
# shellcheck disable=SC1091
. "$MODPATH/flash_safety.sh"

MODE=restore
case "${1:-}" in
    --restore-bound-backup) MODE=restore; shift ;;
    --check-bound-backup) MODE=check; shift ;;
esac

BOOTIMAGE=${1:-}
[ -n "$BOOTIMAGE" ] || { >&2 echo "! BOOTIMAGE is required"; exit 2; }
[ -e "$BOOTIMAGE" ] || { >&2 echo "! $BOOTIMAGE does not exist"; exit 2; }
BOOT_TARGET=$(readlink -f "$BOOTIMAGE" 2>/dev/null || printf '%s' "$BOOTIMAGE")

command -v sha256sum >/dev/null 2>&1 || { >&2 echo "! sha256sum not found"; exit 1; }
command -v patchnest_device_binding_sha256 >/dev/null 2>&1 || {
    >&2 echo "! transaction helper unavailable"; exit 1;
}

BOUND_BACKUP=''
BOUND_BACKUP_SHA=''
BOUND_BACKUP_SIZE=''
BOUND_PATCHED_SHA=''
BOUND_PATCHED_SIZE=''
BOUND_DEVICE_SHA=''
BOUND_TARGET=''

resolve_bound_backup() {
    _pn_binding=${PATCHNEST_ROLLBACK_BINDING_FILE:-$PNDIR/rollback_binding.json}
    patchnest_state_file_is_secure "$_pn_binding" || {
        >&2 echo "! No secure committed rollback transaction"; return 1;
    }
    [ "$(patchnest_json_bool verified_readback "$_pn_binding")" = "true" ] || return 2

    BOUND_TARGET=$(patchnest_json_string boot_target "$_pn_binding")
    BOUND_DEVICE_SHA=$(patchnest_json_string device_binding_sha256 "$_pn_binding")
    _pn_backup_name=$(patchnest_json_string rollback_backup "$_pn_binding")
    BOUND_BACKUP_SHA=$(patchnest_json_string rollback_backup_sha256 "$_pn_binding")
    BOUND_PATCHED_SHA=$(patchnest_json_string patched_image_sha256 "$_pn_binding")
    BOUND_PATCHED_SIZE=$(patchnest_json_number patched_image_size "$_pn_binding")

    [ "$BOUND_TARGET" = "$BOOT_TARGET" ] || { >&2 echo "! Rollback target mismatch"; return 3; }
    printf '%s' "$BOUND_DEVICE_SHA$BOUND_BACKUP_SHA$BOUND_PATCHED_SHA" | grep -Eq '^[0-9a-f]{192}$' || return 3
    printf '%s' "$BOUND_PATCHED_SIZE" | grep -Eq '^[1-9][0-9]*$' || return 3

    _pn_current_device=$(patchnest_device_binding_sha256 "$BOOT_TARGET") || return 4
    [ "$_pn_current_device" = "$BOUND_DEVICE_SHA" ] || {
        >&2 echo "! Rollback binding belongs to another device/slot/target context"; return 4;
    }

    case "$_pn_backup_name" in
        boot_backup_*.img) ;;
        *) >&2 echo "! Unsafe rollback backup name"; return 5 ;;
    esac
    case "$_pn_backup_name" in
        */*|*..*) >&2 echo "! Unsafe rollback backup path"; return 5 ;;
    esac

    BOUND_BACKUP="$BACKUP_DIR/$_pn_backup_name"
    [ -f "$BOUND_BACKUP" ] || { >&2 echo "! Bound rollback backup missing"; return 5; }
    _pn_actual_backup=$(patchnest_hash_file "$BOUND_BACKUP") || return 6
    [ "$_pn_actual_backup" = "$BOUND_BACKUP_SHA" ] || {
        >&2 echo "! Bound rollback backup digest mismatch"; return 6;
    }
    BOUND_BACKUP_SIZE=$(stat -c '%s' "$BOUND_BACKUP" 2>/dev/null)
    printf '%s' "$BOUND_BACKUP_SIZE" | grep -Eq '^[1-9][0-9]*$' || return 6

    _pn_current_sha=$(patchnest_hash_prefix "$BOOT_TARGET" "$BOUND_PATCHED_SIZE") || return 7
    [ "$_pn_current_sha" = "$BOUND_PATCHED_SHA" ] || {
        >&2 echo "! Current boot bytes no longer match committed PatchNest transaction"
        >&2 echo "! Refusing stale/external-reflash rollback"
        return 7
    }
    return 0
}

write_restore_receipt() {
    _pn_when=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
    mkdir -p "$PNDIR" || return 1
    umask 077
    _pn_tmp="${RESTORE_RECEIPT}.tmp.$$"
    cat > "$_pn_tmp" <<EOF
{
  "schema": 1,
  "boot_target": "$(patchnest_json_escape "$BOOT_TARGET")",
  "device_binding_sha256": "$BOUND_DEVICE_SHA",
  "restored_backup_sha256": "$BOUND_BACKUP_SHA",
  "restored_backup_size": $BOUND_BACKUP_SIZE,
  "verified_readback": true,
  "restored_at": "$_pn_when"
}
EOF
    chmod 0600 "$_pn_tmp" || { rm -f "$_pn_tmp"; return 1; }
    mv -f "$_pn_tmp" "$RESTORE_RECEIPT" || { rm -f "$_pn_tmp"; return 1; }
    patchnest_state_file_is_secure "$RESTORE_RECEIPT"
}

resolve_bound_backup || exit $?

if [ "$MODE" = "check" ]; then
    echo "- rollback transaction eligible"
    echo "- target: $BOOT_TARGET"
    echo "- backup: $BOUND_BACKUP"
    echo "- backup_sha256: $BOUND_BACKUP_SHA"
    exit 0
fi

echo "- restore: transaction-bound backup: $BOUND_BACKUP"
echo "- restore: target: $BOOT_TARGET"
flash_image "$BOUND_BACKUP" "$BOOT_TARGET"
_pn_rc=$?
if [ "$_pn_rc" -ne 0 ]; then
    >&2 echo "! restore write/readback failed: $_pn_rc"
    patchnest_mark_recovery_required "bound_restore_failed:${_pn_rc}" || true
    exit 8
fi

# The low-level writer already compared exact bytes. Persist the receipt before
# revoking rollback authorization so post-reboot validation can prove the boot
# target equals the exact backup that was restored.
write_restore_receipt || {
    >&2 echo "! Restore verified, but restore receipt could not be committed"
    patchnest_mark_recovery_required "restore_receipt_failed" || true
    exit 9
}

patchnest_remove_rollback_binding || {
    >&2 echo "! Restore verified, but rollback binding could not be cleared"
    patchnest_mark_recovery_required "restore_binding_cleanup_failed" || true
    exit 10
}
patchnest_clear_pending_transaction || true
patchnest_clear_recovery_required || true
echo "0" > "$PNDIR/boot_count" 2>/dev/null
touch "$AUTORECOVERY_MARKER" 2>/dev/null || true

echo "- restore: exact transaction-bound rollback verified"
exit 0
