#!/system/bin/sh
#######################################################################################
# PatchNest current-image unpatcher
#
# Usage: boot_unpatch.sh <bootimage> [flash_to_device:true|false]
#
# This script only removes PatchNest from the selected current boot image by
# unpacking, unpatching, repacking, and validating that image. It never selects
# or flashes a stored backup. Verified backup restoration is implemented only
# by boot_restore_verified.sh.
#
# `false` generates and verifies an unpatched image without writing a block
# device. A direct block-device write requires either the short-lived one-time
# WebUI approval file or the explicit CLI environment override
# PATCHNEST_UNPATCH_APPROVED=1.
#######################################################################################

MODPATH=${0%/*}
PNDIR=/data/adb/patchnest
APPROVAL_FILE="$PNDIR/unpatch_approval"
APPROVAL_MAX_AGE=120
BOOTIMAGE=${1:-}
FLASH_TO_DEVICE=${2:-true}

. "$MODPATH/util_functions.sh"
. "$MODPATH/flash_guard.sh"
. "$MODPATH/recovery_state.sh"

validate_boot_image() {
  _image=$1
  [ -s "$_image" ] || return 1
  _image_abs=$(readlink -f "$_image" 2>/dev/null || true)
  [ -n "$_image_abs" ] && [ -s "$_image_abs" ] || return 1
  _validate_tmp=$(mktemp -d "${TMPDIR:-/data/local/tmp}/patchnest-unpack.XXXXXX") || return 1
  if ! (cd "$_validate_tmp" && magiskboot unpack "$_image_abs" >/dev/null 2>&1 && [ -s kernel ]); then
    rm -rf "$_validate_tmp"
    return 1
  fi
  rm -rf "$_validate_tmp"
  return 0
}

require_flash_approval() {
  if [ "${PATCHNEST_UNPATCH_APPROVED:-0}" = "1" ]; then
    echo "- Explicit CLI unpatch approval accepted"
    return 0
  fi

  [ -f "$APPROVAL_FILE" ] && [ ! -L "$APPROVAL_FILE" ] || {
    echo "! Missing one-time unpatch approval; operation was not confirmed" >&2
    return 1
  }

  _owner=$(stat -c '%u' "$APPROVAL_FILE" 2>/dev/null || true)
  [ "$_owner" = "0" ] || {
    echo "! Unpatch approval is not owned by root" >&2
    rm -f "$APPROVAL_FILE" 2>/dev/null || true
    return 1
  }

  _size=$(wc -c <"$APPROVAL_FILE" 2>/dev/null || true)
  case "$_size" in ''|*[!0-9]*) _size=999999 ;; esac
  [ "$_size" -le 256 ] || {
    echo "! Unpatch approval file is malformed" >&2
    rm -f "$APPROVAL_FILE" 2>/dev/null || true
    return 1
  }

  [ "$(grep -c '^operation=' "$APPROVAL_FILE" 2>/dev/null)" = "1" ] \
    && grep -qx 'operation=current-image-unpatch' "$APPROVAL_FILE" 2>/dev/null \
    || {
      echo "! Unpatch approval operation does not match" >&2
      rm -f "$APPROVAL_FILE" 2>/dev/null || true
      return 1
    }

  [ "$(grep -c '^approved_at=' "$APPROVAL_FILE" 2>/dev/null)" = "1" ] || {
    echo "! Unpatch approval timestamp is missing or duplicated" >&2
    rm -f "$APPROVAL_FILE" 2>/dev/null || true
    return 1
  }
  _approved_at=$(sed -n 's/^approved_at=//p' "$APPROVAL_FILE" 2>/dev/null | head -n 1)
  case "$_approved_at" in
    ''|*[!0-9]*)
      echo "! Unpatch approval timestamp is invalid" >&2
      rm -f "$APPROVAL_FILE" 2>/dev/null || true
      return 1
      ;;
  esac

  _now=$(date +%s 2>/dev/null || true)
  case "$_now" in
    ''|*[!0-9]*)
      echo "! Current time is unavailable; cannot validate approval" >&2
      rm -f "$APPROVAL_FILE" 2>/dev/null || true
      return 1
      ;;
  esac
  _age=$((_now - _approved_at))
  if [ "$_age" -lt 0 ] || [ "$_age" -gt "$APPROVAL_MAX_AGE" ]; then
    echo "! Unpatch approval expired or has a future timestamp" >&2
    rm -f "$APPROVAL_FILE" 2>/dev/null || true
    return 1
  fi

  # Consume before unpacking so the same user confirmation cannot authorize a
  # retry or a second target. A new write always requires a new confirmation.
  rm -f "$APPROVAL_FILE" || {
    echo "! Could not consume one-time unpatch approval" >&2
    return 1
  }
  echo "- One-time current-image unpatch approval accepted"
  return 0
}

[ -n "$BOOTIMAGE" ] && [ -e "$BOOTIMAGE" ] || {
  echo "! Target image does not exist: $BOOTIMAGE" >&2
  exit 1
}
case "$FLASH_TO_DEVICE" in
  true|false) ;;
  *) echo "! flash_to_device must be true or false" >&2; exit 2 ;;
esac
if [ "$FLASH_TO_DEVICE" = "true" ]; then
  assert_kernel_boot_target "$BOOTIMAGE" || exit 1
  require_flash_approval || exit 1
fi

command -v magiskboot >/dev/null 2>&1 || { echo "! Command magiskboot not found" >&2; exit 1; }
command -v kptools >/dev/null 2>&1 || { echo "! Command kptools not found" >&2; exit 1; }

# Never reuse artifacts left by an interrupted previous operation.
magiskboot cleanup >/dev/null 2>&1 || true
rm -f kernel kernel.ori new-boot.img

echo "- Target image: $BOOTIMAGE"
echo "- Unpacking current boot image"
if ! magiskboot unpack "$BOOTIMAGE" >/dev/null 2>&1; then
  echo "! Unpack error" >&2
  exit 1
fi
[ -s kernel ] || { echo "! Unpack produced no non-empty kernel payload" >&2; exit 1; }

if ! kptools -i kernel -l 2>/dev/null | grep -q 'patched=true'; then
  echo "- Kernel is not PatchNest-patched; no unpatch required"
  magiskboot cleanup >/dev/null 2>&1 || true
  rm -f kernel kernel.ori new-boot.img
  exit 0
fi

mv kernel kernel.ori || { echo "! Failed to preserve patched kernel" >&2; exit 1; }
echo "- Removing PatchNest from current kernel"
if ! kptools -u --image kernel.ori --out kernel; then
  echo "! Unpatch error" >&2
  rm -f kernel
  mv kernel.ori kernel 2>/dev/null || true
  exit 1
fi
[ -s kernel ] || { echo "! Unpatch produced no non-empty kernel" >&2; exit 1; }

if kptools -i kernel -l 2>/dev/null | grep -q 'patched=true'; then
  echo "! Generated kernel still reports patched=true" >&2
  exit 1
fi

echo "- Repacking current boot image"
if ! magiskboot repack "$BOOTIMAGE" >/dev/null 2>&1; then
  echo "! Repack error" >&2
  exit 1
fi
[ -s new-boot.img ] || { echo "! Repack produced no non-empty new-boot.img" >&2; exit 1; }

echo "- Validating generated current-image replacement"
if ! validate_boot_image new-boot.img; then
  echo "! Unpatched boot image validation failed" >&2
  save_image_to_storage new-boot.img
  exit 1
fi
_unpatched_sha=$(image_stream_sha256 new-boot.img 2>/dev/null || true)
_target_name=$(partition_name_for_target "$BOOTIMAGE")

echo "- Unpatched image SHA256: ${_unpatched_sha:-unavailable}"
if [ "$FLASH_TO_DEVICE" = "true" ]; then
  echo "- Flashing generated current-image replacement"
  flash_image new-boot.img "$BOOTIMAGE"
  flash_rc=$?
  if [ "$flash_rc" -ne 0 ]; then
    echo "! Flash or readback verification error: $flash_rc" >&2
    save_image_to_storage new-boot.img
    exit 1
  fi
  if patchnest_suspend_recovery_monitoring current-image-unpatched "$_target_name" "$_unpatched_sha"; then
    echo "- Recovery monitoring suspended until PatchNest is installed again"
  else
    echo "! Current boot image was unpatched, but recovery monitoring state could not be suspended" >&2
  fi
  echo "- Current boot image unpatched and read back successfully"
else
  if ! save_image_to_storage new-boot.img; then
    echo "! Could not save verified unpatched image" >&2
    exit 1
  fi
  echo "- Successfully unpatched current image; output saved without flashing"
fi

magiskboot cleanup >/dev/null 2>&1 || true
rm -f kernel kernel.ori new-boot.img
exit 0
