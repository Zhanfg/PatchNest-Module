#!/system/bin/sh
#######################################################################################
# PatchNest Boot Image Patcher
#
# Usage: boot_patch.sh <bootimage> <flash_to_device:true|false> [kptools args]
# Optional environment: KP_REBACKUP=1 requests a fresh verified backup, but a
# currently PatchNest-patched image is never allowed to replace the recovery base.
#######################################################################################

MODPATH=${0%/*}
PNDIR="/data/adb/patchnest"
BACKUP_DIR="$PNDIR/backup"
KP_REBACKUP=${KP_REBACKUP:-0}
BOOTIMAGE=${1:-}
FLASH_TO_DEVICE=${2:-false}
[ "$#" -ge 2 ] && shift 2 || true

. "$MODPATH/util_functions.sh"
. "$MODPATH/flash_guard.sh"
. "$MODPATH/kptools_argv.sh"

fail() {
  echo "! $*" >&2
  exit 1
}

resolve_kpimg() {
  for _candidate in \
    "${KPIMG_PATH:-}" \
    "$MODPATH/../bin/kpimg" \
    "$PWD/kpimg" \
    "$MODPATH/kpimg"; do
    [ -n "$_candidate" ] || continue
    if [ -s "$_candidate" ]; then
      readlink -f "$_candidate" 2>/dev/null || printf '%s' "$_candidate"
      return 0
    fi
  done
  return 1
}

json_escape() {
  printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

validate_boot_image() {
  _image=$1
  _expect_patched=$2
  [ -s "$_image" ] || return 1
  _image_abs=$(readlink -f "$_image" 2>/dev/null || true)
  [ -n "$_image_abs" ] && [ -s "$_image_abs" ] || return 1
  _tmp=$(mktemp -d "${TMPDIR:-/data/local/tmp}/patchnest-validate.XXXXXX") || return 1
  if ! (cd "$_tmp" && magiskboot unpack "$_image_abs" >/dev/null 2>&1 && [ -s kernel ]); then
    rm -rf "$_tmp"
    return 1
  fi
  if [ "$_expect_patched" = "true" ]; then
    if ! (cd "$_tmp" && kptools -i kernel -l 2>/dev/null | grep -q 'patched=true'); then
      rm -rf "$_tmp"
      return 1
    fi
  fi
  rm -rf "$_tmp"
  return 0
}

root_chain_state() {
  _state=stock
  if [ -d /data/adb/ksu ] || [ -d /sys/module/ksu ]; then
    _state=ksu
  fi
  if [ -d /data/adb/magisk ]; then
    _state=magisk
  fi
  if [ -d /data/adb/ap ]; then
    _state=apatch
  fi
  printf '%s' "$_state"
}

write_backup_manifest() {
  _manifest=$1
  _backup=$2
  _target=$3
  _backup_sha=$4
  _target_name=$(partition_name_for_target "$_target")
  _kp_state=$(root_chain_state)
  _magisk_version=$(magisk --version 2>/dev/null | head -n 1 | cut -d: -f1)
  [ -n "$_magisk_version" ] || _magisk_version=null
  _ksu_version=$(ksu --version 2>/dev/null | head -n 1 | tr -d '\r\n')
  [ -n "$_ksu_version" ] || _ksu_version=null
  _kpimg_size=$(stat -c '%s' "$KPIMG" 2>/dev/null)
  [ -n "$_kpimg_size" ] || _kpimg_size=0
  _verified_boot=$(getprop ro.boot.vbmeta.device_state 2>/dev/null)
  [ -n "$_verified_boot" ] || _verified_boot=unknown
  _taken_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)

  _tmp_manifest="${_manifest}.tmp.$$"
  cat >"$_tmp_manifest" <<EOF
{
  "boot_image": "$(json_escape "$_target_name")",
  "backup_file": "$(json_escape "$(basename "$_backup")")",
  "taken_at": "$(json_escape "$_taken_at")",
  "kp_state": "$(json_escape "$_kp_state")",
  "magisk_version": "$(json_escape "$_magisk_version")",
  "ksu_version": "$(json_escape "$_ksu_version")",
  "kpimg_size": $_kpimg_size,
  "kernel_cmdline_hint": "$(json_escape "$_verified_boot")",
  "original_sha256": "$(json_escape "$_backup_sha")",
  "backup_sha256": "$(json_escape "$_backup_sha")",
  "backup_verified": true
}
EOF
  mv "$_tmp_manifest" "$_manifest"
}

backup_current_boot() {
  mkdir -p "$BACKUP_DIR" || return 1
  _stamp=$(date +%Y%m%d%H%M%S 2>/dev/null || printf 'unknown')
  _backup="$BACKUP_DIR/boot_backup_${_stamp}_$$.img"
  _manifest="${_backup%.img}.json"

  echo "- Capturing boot backup: $_backup"
  if ! cp "$BOOTIMAGE" "$_backup" || [ ! -s "$_backup" ]; then
    rm -f "$_backup" "$_manifest"
    return 1
  fi
  if ! validate_boot_image "$_backup" false; then
    rm -f "$_backup" "$_manifest"
    return 1
  fi
  _sha=$(image_stream_sha256 "$_backup") || {
    rm -f "$_backup" "$_manifest"
    return 1
  }
  printf '%s' "$_sha" | grep -Eq '^[0-9a-f]{64}$' || {
    rm -f "$_backup" "$_manifest"
    return 1
  }
  write_backup_manifest "$_manifest" "$_backup" "$BOOTIMAGE" "$_sha" || {
    rm -f "$_backup" "$_manifest"
    return 1
  }
  echo "- Verified backup SHA256: $_sha"
  return 0
}

validate_embedded_kpms() {
  _previous=__start__
  for _argument in "$@"; do
    if [ "$_previous" = "-M" ]; then
      [ -s "$_argument" ] || {
        echo "! Embedded KPM missing or empty: $_argument" >&2
        return 1
      }
      if ! kptools -l -M "$_argument" >/dev/null 2>&1; then
        echo "! Embedded KPM cannot be verified by kptools: $_argument" >&2
        return 1
      fi
      echo "- Verified embedded KPM: $_argument"
    fi
    _previous=$_argument
  done
  [ "$_previous" != "-M" ] || {
    echo "! -M requires a KPM path" >&2
    return 1
  }
  return 0
}

[ -n "$BOOTIMAGE" ] && [ -e "$BOOTIMAGE" ] || fail "Boot image does not exist: $BOOTIMAGE"
case "$FLASH_TO_DEVICE" in
  true|false) ;;
  *) fail "flash_to_device must be true or false" ;;
esac
command -v magiskboot >/dev/null 2>&1 || fail "Command magiskboot not found"
command -v kptools >/dev/null 2>&1 || fail "Command kptools not found"
KPIMG=$(resolve_kpimg) || fail "kpimg missing or empty"

if [ "$FLASH_TO_DEVICE" = "true" ]; then
  assert_kernel_boot_target "$BOOTIMAGE" || exit 1
fi

magiskboot cleanup >/dev/null 2>&1 || true
rm -f kernel kernel.ori new-boot.img ori.img

echo "- Unpacking boot image"
if ! magiskboot unpack "$BOOTIMAGE" >/dev/null 2>&1; then
  fail "Unpack failed"
fi
[ -s kernel ] || fail "Unpack produced no non-empty kernel"

if kptools -i kernel -f 2>/dev/null | grep -q 'CONFIG_KPM=y'; then
  fail "Built-in KPM detected; PatchNest injection is not supported"
fi
if ! kptools -i kernel -f 2>/dev/null | grep -q 'CONFIG_KALLSYMS_ALL=y'; then
  fail "Kernel lacks CONFIG_KALLSYMS_ALL=y"
fi

_currently_patched=false
if kptools -i kernel -l 2>/dev/null | grep -q 'patched=true'; then
  _currently_patched=true
fi

if [ "$_currently_patched" = "false" ]; then
  backup_current_boot || fail "Could not create and verify boot backup"
elif [ "$KP_REBACKUP" = "1" ]; then
  fail "Refusing to replace recovery backup with an already patched boot image"
else
  echo "- Existing PatchNest patch detected; preserving previous verified backup"
fi

validate_embedded_kpms "$@" || exit 1

mv kernel kernel.ori || fail "Could not preserve original kernel payload"
echo "- Patching kernel"
# Do not enable shell tracing here: kptools arguments may include a superkey.
if ! run_patchnest_kptools_patch "$@"; then
  rm -f kernel
  mv kernel.ori kernel 2>/dev/null || true
  fail "Kernel patch failed"
fi
[ -s kernel ] || fail "Kernel patch produced no output"
if ! kptools -i kernel -l 2>/dev/null | grep -q 'patched=true'; then
  fail "Patched kernel does not report patched=true"
fi

echo "- Repacking boot image"
if ! magiskboot repack "$BOOTIMAGE" >/dev/null 2>&1; then
  fail "Repack failed"
fi
[ -s new-boot.img ] || fail "Repack produced no non-empty new-boot.img"

if ! validate_boot_image new-boot.img true; then
  save_image_to_storage new-boot.img
  fail "Patched boot image failed independent unpack verification"
fi
_patched_sha=$(image_stream_sha256 new-boot.img 2>/dev/null || true)
echo "- Patched image SHA256: ${_patched_sha:-unavailable}"

if [ "$FLASH_TO_DEVICE" = "true" ]; then
  echo "- Flashing new boot image"
  flash_image new-boot.img "$BOOTIMAGE"
  _flash_rc=$?
  if [ "$_flash_rc" -ne 0 ]; then
    save_image_to_storage new-boot.img
    fail "Flash or readback verification failed ($_flash_rc)"
  fi
  echo "- Successfully flashed and verified"
else
  save_image_to_storage new-boot.img || fail "Could not save patched image"
  echo "- Successfully patched; image saved without flashing"
fi

magiskboot cleanup >/dev/null 2>&1 || true
rm -f kernel kernel.ori new-boot.img ori.img
exit 0
