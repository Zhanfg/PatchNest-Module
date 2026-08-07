#!/system/bin/sh
#######################################################################################
# PatchNest verified boot-backup restore
#
# Usage:
#   boot_restore_verified.sh <boot-target> <backup.img> [flash_to_device:false|true]
#
# The default is `false`: validate the exact target-bound backup and print the
# restore plan without writing a block device. A real write additionally
# requires PATCHNEST_RESTORE_APPROVED=1. This script never auto-selects the
# newest backup.
#######################################################################################

set -u
umask 077

MODPATH=${0%/*}
PNDIR=/data/adb/patchnest
BACKUP_DIR="$PNDIR/backup"
BOOTIMAGE=${1:-}
BACKUPIMAGE=${2:-}
FLASH_TO_DEVICE=${3:-false}

. "$MODPATH/util_functions.sh"
. "$MODPATH/flash_guard.sh"

fail() {
  echo "! $*" >&2
  exit 1
}

manifest_string() {
  _manifest=$1
  _key=$2
  _matches=$(grep -o "\"${_key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$_manifest" 2>/dev/null || true)
  [ "$(printf '%s\n' "$_matches" | sed '/^$/d' | wc -l)" = "1" ] || return 1
  printf '%s\n' "$_matches" | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/'
}

manifest_bool() {
  _manifest=$1
  _key=$2
  _matches=$(grep -o "\"${_key}\"[[:space:]]*:[[:space:]]*\(true\|false\)" "$_manifest" 2>/dev/null || true)
  [ "$(printf '%s\n' "$_matches" | sed '/^$/d' | wc -l)" = "1" ] || return 1
  printf '%s\n' "$_matches" | sed -E 's/.*:[[:space:]]*(true|false).*/\1/'
}

validate_boot_image() {
  _image=$1
  [ -s "$_image" ] && [ -f "$_image" ] && [ ! -L "$_image" ] || return 1
  _image_abs=$(readlink -f "$_image" 2>/dev/null || true)
  [ -n "$_image_abs" ] && [ -s "$_image_abs" ] || return 1
  _tmp=$(mktemp -d "${TMPDIR:-/data/local/tmp}/patchnest-restore-check.XXXXXX") || return 1
  if ! (cd "$_tmp" && magiskboot unpack "$_image_abs" >/dev/null 2>&1 && [ -s kernel ]); then
    rm -rf "$_tmp"
    return 1
  fi
  rm -rf "$_tmp"
  return 0
}

[ -n "$BOOTIMAGE" ] && [ -e "$BOOTIMAGE" ] || fail "Boot target does not exist: $BOOTIMAGE"
[ -n "$BACKUPIMAGE" ] && [ -e "$BACKUPIMAGE" ] || fail "Backup image does not exist: $BACKUPIMAGE"
case "$FLASH_TO_DEVICE" in
  true|false) ;;
  *) fail "flash_to_device must be true or false" ;;
esac

assert_kernel_boot_target "$BOOTIMAGE" || fail "Restore target is not a supported kernel boot partition"
command -v magiskboot >/dev/null 2>&1 || fail "Command magiskboot not found"
command -v sha256sum >/dev/null 2>&1 || fail "Command sha256sum not found"

_backup_root=$(readlink -f "$BACKUP_DIR" 2>/dev/null || true)
_backup_real=$(readlink -f "$BACKUPIMAGE" 2>/dev/null || true)
[ -n "$_backup_root" ] && [ -d "$_backup_root" ] || fail "Backup directory is unavailable"
case "$_backup_real" in
  "$_backup_root"/boot_backup_*.img) ;;
  *) fail "Backup must be an exact boot_backup_*.img inside $BACKUP_DIR" ;;
esac
[ -f "$_backup_real" ] && [ ! -L "$BACKUPIMAGE" ] || fail "Backup must be a regular non-symlink file"

_manifest="${_backup_real%.img}.json"
[ -f "$_manifest" ] && [ ! -L "$_manifest" ] || fail "Matching backup manifest is missing"
[ "$(manifest_bool "$_manifest" backup_verified 2>/dev/null)" = "true" ] \
  || fail "Manifest does not contain one backup_verified=true value"

_target_name=$(partition_name_for_target "$BOOTIMAGE")
_recorded_target=$(manifest_string "$_manifest" boot_image 2>/dev/null) \
  || fail "Manifest boot_image is missing or duplicated"
[ "$_recorded_target" = "$_target_name" ] \
  || fail "Backup target mismatch: manifest=$_recorded_target current=$_target_name"

_recorded_file=$(manifest_string "$_manifest" backup_file 2>/dev/null) \
  || fail "Manifest backup_file is missing or duplicated"
[ "$_recorded_file" = "$(basename "$_backup_real")" ] \
  || fail "Manifest backup_file does not match the selected image"

_recorded_sha=$(manifest_string "$_manifest" backup_sha256 2>/dev/null) \
  || fail "Manifest backup_sha256 is missing or duplicated"
printf '%s' "$_recorded_sha" | grep -Eq '^[0-9a-f]{64}$' \
  || fail "Manifest backup SHA-256 is invalid"
_actual_sha=$(image_stream_sha256 "$_backup_real" 2>/dev/null) \
  || fail "Could not hash selected backup"
[ "$_actual_sha" = "$_recorded_sha" ] || fail "Selected backup SHA-256 does not match its manifest"

validate_boot_image "$_backup_real" || fail "Selected backup cannot be unpacked into a kernel-bearing boot image"

_size=$(wc -c <"$_backup_real" 2>/dev/null || true)
echo "- Verified restore target: $BOOTIMAGE ($_target_name)"
echo "- Verified backup: $_backup_real"
echo "- Backup size: ${_size:-unknown}"
echo "- Backup SHA256: $_actual_sha"
echo "- No automatic backup selection was used"

if [ "$FLASH_TO_DEVICE" = "false" ]; then
  echo "- Validation complete; no block device was written"
  exit 0
fi

[ "${PATCHNEST_RESTORE_APPROVED:-0}" = "1" ] \
  || fail "Restore write requires explicit PATCHNEST_RESTORE_APPROVED=1"

echo "- Flashing exact verified backup"
flash_image "$_backup_real" "$BOOTIMAGE"
_rc=$?
[ "$_rc" -eq 0 ] || fail "Restore flash/readback verification failed ($_rc)"

printf '%s\n' 0 >"$PNDIR/boot_count" 2>/dev/null || true
rm -f "$PNDIR/autorecovery_active" "$PNDIR/auto_unpatch_requested" 2>/dev/null || true
echo "- Verified backup restored and read back successfully"
exit 0
