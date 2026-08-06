#!/system/bin/sh
#######################################################################################
# PatchNest Boot Image Unpatcher
# Based on APatch boot_unpatch.sh, with PatchNest fail-closed recovery checks.
#######################################################################################

MODPATH=${0%/*}
PNDIR="/data/adb/patchnest"
BACKUP_DIR="$PNDIR/backup"
AUTORECOVERY_MARKER="$PNDIR/autorecovery_active"
BOOTIMAGE=${1:-}

# Load upstream helpers, then override direct flashing with the PatchNest guard.
. "$MODPATH/util_functions.sh"
. "$MODPATH/flash_guard.sh"

manifest_string() {
  _manifest=$1
  _key=$2
  grep -o "\"${_key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$_manifest" 2>/dev/null \
    | head -n 1 \
    | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/'
}

manifest_bool() {
  _manifest=$1
  _key=$2
  grep -o "\"${_key}\"[[:space:]]*:[[:space:]]*[a-z]*" "$_manifest" 2>/dev/null \
    | head -n 1 \
    | sed -E 's/.*:[[:space:]]*([a-z]*).*/\1/'
}

validate_boot_image() {
  _image=$1
  [ -s "$_image" ] || return 1
  _validate_tmp=$(mktemp -d "${TMPDIR:-/data/local/tmp}/patchnest-unpack.XXXXXX") || return 1
  if ! (cd "$_validate_tmp" && magiskboot unpack "$_image" >/dev/null 2>&1 && [ -s kernel ]); then
    rm -rf "$_validate_tmp"
    return 1
  fi
  rm -rf "$_validate_tmp"
  return 0
}

select_verified_backup() {
  _target=$1
  _target_real=$(readlink -f "$_target" 2>/dev/null || printf '%s' "$_target")
  _target_name=$(basename "$_target_real")

  [ -d "$BACKUP_DIR" ] || return 1
  for _candidate in $(ls -1t "$BACKUP_DIR"/boot_backup_*.img 2>/dev/null); do
    [ -s "$_candidate" ] || continue
    _manifest="${_candidate%.img}.json"
    [ -f "$_manifest" ] || continue

    _verified=$(manifest_bool "$_manifest" backup_verified)
    [ "$_verified" = "true" ] || continue

    _recorded_target=$(manifest_string "$_manifest" boot_image)
    [ "$_recorded_target" = "$_target_name" ] || continue

    _recorded_sha=$(manifest_string "$_manifest" backup_sha256)
    printf '%s' "$_recorded_sha" | grep -Eq '^[0-9a-f]{64}$' || continue
    _actual_sha=$(image_stream_sha256 "$_candidate" 2>/dev/null)
    [ "$_actual_sha" = "$_recorded_sha" ] || continue

    validate_boot_image "$_candidate" || continue
    printf '%s\n' "$_candidate"
    return 0
  done
  return 1
}

# Bootloop recovery entry point. This function remains callable by a future
# early-boot recovery executor, but it never chooses a legacy, manifest-less,
# target-mismatched, digest-mismatched, or unpack-invalid image.
auto_unpatch() {
  [ -n "$BOOTIMAGE" ] && [ -e "$BOOTIMAGE" ] || {
    echo "! auto_unpatch: BOOTIMAGE not set or missing ($BOOTIMAGE)" >&2
    return 1
  }
  assert_kernel_boot_target "$BOOTIMAGE" || return 2

  _backup=$(select_verified_backup "$BOOTIMAGE") || {
    echo "! auto_unpatch: no verified backup matches the active target" >&2
    return 3
  }

  echo "- auto_unpatch: verified backup: $_backup"
  if ! flash_image "$_backup" "$BOOTIMAGE"; then
    _rc=$?
    echo "! auto_unpatch: flash/readback verification failed ($_rc)" >&2
    return 4
  fi

  echo "0" >"$PNDIR/boot_count" 2>/dev/null || true
  echo "- auto_unpatch: flash successful and verified"
  return 0
}

[ -n "$BOOTIMAGE" ] && [ -e "$BOOTIMAGE" ] || {
  echo "! Target image does not exist: $BOOTIMAGE" >&2
  exit 1
}
assert_kernel_boot_target "$BOOTIMAGE" || exit 1

command -v magiskboot >/dev/null 2>&1 || {
  echo "! Command magiskboot not found" >&2
  exit 1
}
command -v kptools >/dev/null 2>&1 || {
  echo "! Command kptools not found" >&2
  exit 1
}

# Never reuse artifacts left by an interrupted previous operation.
rm -f kernel kernel.ori new-boot.img

echo "- Target image: $BOOTIMAGE"
echo "- Unpacking boot image"
if ! magiskboot unpack "$BOOTIMAGE" >/dev/null 2>&1; then
  echo "! Unpack error" >&2
  exit 1
fi
if [ ! -s kernel ]; then
  echo "! Unpack produced no non-empty kernel payload" >&2
  exit 1
fi

if ! kptools -i kernel -l 2>/dev/null | grep -q 'patched=true'; then
  echo "- Kernel is not PatchNest-patched; no unpatch required"
  magiskboot cleanup >/dev/null 2>&1 || true
  rm -f kernel kernel.ori new-boot.img
  exit 0
fi

mv kernel kernel.ori || {
  echo "! Failed to preserve patched kernel" >&2
  exit 1
}
echo "- Unpatching kernel"
if ! kptools -u --image kernel.ori --out kernel; then
  echo "! Unpatch error" >&2
  rm -f kernel
  mv kernel.ori kernel 2>/dev/null || true
  exit 1
fi
if [ ! -s kernel ]; then
  echo "! Unpatch produced no non-empty kernel" >&2
  exit 1
fi

# Require kptools to report that the generated kernel is no longer patched.
if kptools -i kernel -l 2>/dev/null | grep -q 'patched=true'; then
  echo "! Generated kernel still reports patched=true" >&2
  exit 1
fi

echo "- Repacking boot image"
if ! magiskboot repack "$BOOTIMAGE" >/dev/null 2>&1; then
  echo "! Repack error" >&2
  exit 1
fi
if [ ! -s new-boot.img ]; then
  echo "! Repack produced no non-empty new-boot.img" >&2
  exit 1
fi

# Re-open the exact image that will be written. This catches malformed output,
# missing kernel payloads, and stale/corrupt files before any block write.
echo "- Validating unpatched boot image"
if ! validate_boot_image new-boot.img; then
  echo "! Unpatched boot image validation failed" >&2
  save_image_to_storage new-boot.img
  exit 1
fi

echo "- Flashing boot image"
flash_image new-boot.img "$BOOTIMAGE"
flash_rc=$?
if [ "$flash_rc" -ne 0 ]; then
  echo "! Flash or readback verification error: $flash_rc" >&2
  save_image_to_storage new-boot.img
  exit 1
fi

echo "- Flash successful and verified"
magiskboot cleanup >/dev/null 2>&1 || true
rm -f kernel kernel.ori new-boot.img
exit 0
