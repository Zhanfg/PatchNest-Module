#!/system/bin/sh
#######################################################################################
# PatchNest Boot Image Patcher
# Transactional/fail-closed patch path derived from the APatch patching flow.
#######################################################################################
#
# Usage:
#   boot_patch.sh <bootimage> <true|false> [ARGS_PASS_TO_KPTOOLS]
#
# The second argument controls whether the generated image is flashed to the target.
# When false, the validated patched image is copied to Download only.
#######################################################################################

MODPATH=${0%/*}
MODULE_DIR=${MODPATH%/patch}
PNDIR="/data/adb/patchnest"
BACKUP_DIR="$PNDIR/backup"
INVOCATION_CWD=$(pwd)

# shellcheck disable=SC1091
. "$MODPATH/util_functions.sh"
# shellcheck disable=SC1091
. "$MODPATH/flash_safety.sh"

BOOTIMAGE=${1:-}
FLASH_TO_DEVICE=${2:-}
[ "$#" -ge 2 ] || { >&2 echo "! Usage: boot_patch.sh <bootimage> <true|false> [kptools args]"; exit 2; }
shift 2

case "$FLASH_TO_DEVICE" in
  true|false) ;;
  *) >&2 echo "! flash flag must be exactly true or false"; exit 2 ;;
esac

[ -n "$BOOTIMAGE" ] || { >&2 echo "! boot image is required"; exit 2; }
[ -e "$BOOTIMAGE" ] || { >&2 echo "! $BOOTIMAGE does not exist"; exit 1; }
BOOT_TARGET=$(readlink -f "$BOOTIMAGE" 2>/dev/null || printf '%s' "$BOOTIMAGE")

command -v magiskboot >/dev/null 2>&1 || { >&2 echo "! Command magiskboot not found"; exit 1; }
command -v kptools >/dev/null 2>&1 || { >&2 echo "! Command kptools not found"; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { >&2 echo "! Command sha256sum not found"; exit 1; }
command -v xxd >/dev/null 2>&1 || { >&2 echo "! Command xxd not found"; exit 1; }

KPIMG_SOURCE="$MODULE_DIR/bin/kpimg"
[ -s "$KPIMG_SOURCE" ] || {
  # Compatibility with older callers that staged kpimg in their cwd.
  KPIMG_SOURCE="$INVOCATION_CWD/kpimg"
}
[ -s "$KPIMG_SOURCE" ] || { >&2 echo "! kpimg missing or empty"; exit 1; }

WORKDIR=$(mktemp -d /data/local/tmp/patchnest_patch.XXXXXX) || {
  >&2 echo "! Cannot create private patch workspace"
  exit 1
}
VALIDATE_DIR=''
BACKUP_CANDIDATE=''
MANIFEST_CANDIDATE=''
BACKUP_COMMITTED=0

cleanup() {
  [ -z "$VALIDATE_DIR" ] || rm -rf "$VALIDATE_DIR"
  rm -rf "$WORKDIR"
  if [ "$BACKUP_COMMITTED" -ne 1 ]; then
    [ -z "$BACKUP_CANDIDATE" ] || rm -f "$BACKUP_CANDIDATE"
    [ -z "$MANIFEST_CANDIDATE" ] || rm -f "$MANIFEST_CANDIDATE"
  fi
}
trap cleanup EXIT HUP INT TERM

json_escape() {
  printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

hash_path() {
  _pn_hash=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
  printf '%s' "$_pn_hash" | grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s\n' "$_pn_hash"
}

validate_boot_image() {
  _pn_image=$1
  VALIDATE_DIR=$(mktemp -d /data/local/tmp/patchnest_validate.XXXXXX) || return 1
  if ! (cd "$VALIDATE_DIR" && magiskboot unpack "$_pn_image" >/dev/null 2>&1); then
    rm -rf "$VALIDATE_DIR"
    VALIDATE_DIR=''
    return 1
  fi
  [ -s "$VALIDATE_DIR/kernel" ] || {
    rm -rf "$VALIDATE_DIR"
    VALIDATE_DIR=''
    return 1
  }
  rm -rf "$VALIDATE_DIR"
  VALIDATE_DIR=''
  return 0
}

write_verified_backup() {
  mkdir -p "$BACKUP_DIR" || return 1

  _pn_stamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%S)
  BACKUP_CANDIDATE=$(mktemp "$BACKUP_DIR/boot_backup_${_pn_stamp}_XXXXXX.img") || return 1
  MANIFEST_CANDIDATE="${BACKUP_CANDIDATE%.img}.json"

  echo "- Capturing rollback image from $BOOT_TARGET"
  if ! cat "$BOOT_TARGET" > "$BACKUP_CANDIDATE"; then
    >&2 echo "! Failed to capture boot backup"
    return 1
  fi
  sync
  [ -s "$BACKUP_CANDIDATE" ] || { >&2 echo "! Captured backup is empty"; return 1; }

  if ! validate_boot_image "$BACKUP_CANDIDATE"; then
    >&2 echo "! Backup validation failed; refusing to patch"
    return 1
  fi

  _pn_target_sha=$(hash_path "$BOOT_TARGET") || {
    >&2 echo "! Cannot hash current boot target"
    return 1
  }
  _pn_backup_sha=$(hash_path "$BACKUP_CANDIDATE") || {
    >&2 echo "! Cannot hash captured backup"
    return 1
  }
  [ "$_pn_target_sha" = "$_pn_backup_sha" ] || {
    >&2 echo "! Backup digest differs from current target"
    >&2 echo "! target=$_pn_target_sha backup=$_pn_backup_sha"
    return 1
  }

  _pn_backup_size=$(wc -c < "$BACKUP_CANDIDATE" 2>/dev/null | tr -d ' ')
  printf '%s' "$_pn_backup_size" | grep -Eq '^[1-9][0-9]*$' || return 1

  _pn_kp_state="stock"
  if kptools -i "$WORKDIR/kernel" -l 2>/dev/null | grep -q 'patched=true'; then
    _pn_kp_state="patched"
  fi

  _pn_magisk="null"
  if command -v magisk >/dev/null 2>&1; then
    _pn_magisk=$(magisk --version 2>/dev/null | head -n 1 | cut -d: -f1)
    [ -n "$_pn_magisk" ] || _pn_magisk="null"
  fi

  _pn_ksu="null"
  if command -v ksu >/dev/null 2>&1; then
    _pn_ksu=$(ksu --version 2>/dev/null | head -n 1 | tr -d '\r\n')
    [ -n "$_pn_ksu" ] || _pn_ksu="null"
  fi

  _pn_taken_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
  _pn_kpimg_sha=$(hash_path "$WORKDIR/kpimg") || return 1

  cat > "$MANIFEST_CANDIDATE.tmp" <<EOF
{
  "schema": 2,
  "boot_image": "$(json_escape "$(basename "$BOOT_TARGET")")",
  "boot_target": "$(json_escape "$BOOT_TARGET")",
  "taken_at": "$(json_escape "$_pn_taken_at")",
  "kp_state": "$(json_escape "$_pn_kp_state")",
  "magisk_version": "$(json_escape "$_pn_magisk")",
  "ksu_version": "$(json_escape "$_pn_ksu")",
  "original_sha256": "$_pn_target_sha",
  "backup_sha256": "$_pn_backup_sha",
  "backup_size": $_pn_backup_size,
  "kpimg_sha256": "$_pn_kpimg_sha",
  "backup_verified": true
}
EOF
  mv "$MANIFEST_CANDIDATE.tmp" "$MANIFEST_CANDIDATE" || return 1
  BACKUP_COMMITTED=1
  echo "- Verified rollback backup: $BACKUP_CANDIDATE"
  echo "- Backup digest: $_pn_backup_sha"
  return 0
}

validate_embedded_kpms() {
  _pn_prev=''
  for _pn_arg in "$@"; do
    if [ "$_pn_prev" = "-M" ]; then
      _pn_kpm=$_pn_arg
      case "$_pn_kpm" in
        /*) ;;
        *) >&2 echo "! Embedded KPM path must be absolute: $_pn_kpm"; return 1 ;;
      esac
      [ -f "$_pn_kpm" ] || { >&2 echo "! Embedded KPM not found: $_pn_kpm"; return 1; }

      _pn_magic=$(xxd -l 4 -p "$_pn_kpm" 2>/dev/null)
      [ "$_pn_magic" = "7f454c46" ] || {
        >&2 echo "! Embedded KPM is not ELF: $_pn_kpm"
        return 1
      }

      _pn_machine=$(xxd -s 18 -l 2 -e "$_pn_kpm" 2>/dev/null | awk '{print $2}')
      [ "$_pn_machine" = "000000b7" ] || {
        >&2 echo "! Embedded KPM is not AArch64: $_pn_kpm"
        return 1
      }

      _pn_meta=$(kptools -l -M "$_pn_kpm" 2>/dev/null) || {
        >&2 echo "! kptools cannot validate embedded KPM: $_pn_kpm"
        return 1
      }
      _pn_name=$(printf '%s\n' "$_pn_meta" | sed -n 's/^name=//p' | head -n 1)
      [ -n "$_pn_name" ] || {
        >&2 echo "! Embedded KPM metadata has no name: $_pn_kpm"
        return 1
      }
      echo "  - verified embedded KPM: $_pn_name"
    fi
    _pn_prev=$_pn_arg
  done
  [ "$_pn_prev" != "-M" ] || { >&2 echo "! -M requires a KPM file"; return 1; }
  return 0
}

write_flash_receipt() {
  _pn_image=$1
  _pn_sha=$(hash_path "$_pn_image") || return 1
  _pn_size=$(wc -c < "$_pn_image" 2>/dev/null | tr -d ' ')
  _pn_time=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
  mkdir -p "$PNDIR" || return 1
  cat > "$PNDIR/last_flash.json.tmp" <<EOF
{
  "boot_target": "$(json_escape "$BOOT_TARGET")",
  "written_sha256": "$_pn_sha",
  "written_size": $_pn_size,
  "verified_readback": true,
  "flashed_at": "$(json_escape "$_pn_time")"
}
EOF
  mv "$PNDIR/last_flash.json.tmp" "$PNDIR/last_flash.json"
}

cd "$WORKDIR" || exit 1
cp "$KPIMG_SOURCE" "$WORKDIR/kpimg" || { >&2 echo "! Failed to stage kpimg"; exit 1; }
[ -s "$WORKDIR/kpimg" ] || { >&2 echo "! Staged kpimg is empty"; exit 1; }

echo "- Unpacking current boot image into private workspace"
if ! magiskboot unpack "$BOOT_TARGET" >/dev/null 2>&1; then
  >&2 echo "! Unpack failed"
  exit 1
fi
[ -s kernel ] || { >&2 echo "! Unpack produced no kernel"; exit 1; }

if kptools -i kernel -f 2>/dev/null | grep -q 'CONFIG_KPM=y'; then
  >&2 echo "! Built-in KPM detected (CONFIG_KPM=y); PatchNest patching is unsupported"
  exit 1
fi
if ! kptools -i kernel -f 2>/dev/null | grep -q 'CONFIG_KALLSYMS_ALL=y'; then
  >&2 echo "! CONFIG_KALLSYMS_ALL is required"
  exit 1
fi

echo "- Validating embedded KPM arguments"
validate_embedded_kpms "$@" || exit 1

# A destructive device write always receives a fresh, target-bound rollback
# snapshot. This avoids stale/newest-by-time recovery ambiguity entirely.
if [ "$FLASH_TO_DEVICE" = "true" ]; then
  write_verified_backup || exit 1
fi

mv kernel kernel.ori

echo "- Patching kernel"
if ! kptools -p -i kernel.ori -k kpimg -o kernel "$@"; then
  >&2 echo "! Kernel patch failed"
  exit 1
fi
[ -s kernel ] || { >&2 echo "! kptools produced an empty kernel"; exit 1; }

echo "- Repacking boot image"
if ! magiskboot repack "$BOOT_TARGET" >/dev/null 2>&1; then
  >&2 echo "! Repack failed"
  exit 1
fi
[ -s new-boot.img ] || { >&2 echo "! Repack produced no new-boot.img"; exit 1; }

# Validate the complete repacked boot image before either flashing or exporting it.
echo "- Validating repacked boot image"
if ! validate_boot_image "$WORKDIR/new-boot.img"; then
  >&2 echo "! Repacked boot image failed validation"
  exit 1
fi

if [ "$FLASH_TO_DEVICE" = "true" ]; then
  echo "- Flashing with mandatory SHA-256 readback verification"
  flash_image "$WORKDIR/new-boot.img" "$BOOT_TARGET"
  _pn_rc=$?
  if [ "$_pn_rc" -ne 0 ]; then
    >&2 echo "! Flash/readback verification failed: $_pn_rc"
    save_image_to_storage "$WORKDIR/new-boot.img" || true
    exit 1
  fi
  if ! write_flash_receipt "$WORKDIR/new-boot.img"; then
    >&2 echo "! Flash succeeded but receipt creation failed"
    exit 1
  fi
  echo "- Successfully flashed and verified"
else
  save_image_to_storage "$WORKDIR/new-boot.img" || exit 1
  echo "- Successfully patched and validated"
fi

exit 0
