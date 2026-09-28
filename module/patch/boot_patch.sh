#!/system/bin/sh
#######################################################################################
# PatchNest Boot Image Patcher
# Transactional/fail-closed patch path derived from the APatch patching flow.
#######################################################################################
# Usage: boot_patch.sh <bootimage> <true|false> [ARGS_PASS_TO_KPTOOLS]
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
# shellcheck disable=SC1091
. "$MODPATH/superkey_safety.sh"
# shellcheck disable=SC1091
. "$MODPATH/transactional_flash.sh"

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

# Never establish a new baseline while a previous destructive transaction is
# unresolved. This is intentionally checked before backup capture or key work.
if patchnest_has_unfinished_transaction; then
  >&2 echo "! An unfinished PatchNest flash transaction exists"
  >&2 echo "! Resolve recovery state before patching again"
  exit 1
fi

KPIMG_SOURCE="$MODULE_DIR/bin/kpimg"
[ -s "$KPIMG_SOURCE" ] || KPIMG_SOURCE="$INVOCATION_CWD/kpimg"
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
  cat "$BOOT_TARGET" > "$BACKUP_CANDIDATE" || return 1
  sync
  [ -s "$BACKUP_CANDIDATE" ] || return 1
  validate_boot_image "$BACKUP_CANDIDATE" || {
    >&2 echo "! Backup validation failed; refusing to patch"
    return 1
  }

  _pn_target_sha=$(hash_path "$BOOT_TARGET") || return 1
  _pn_backup_sha=$(hash_path "$BACKUP_CANDIDATE") || return 1
  [ "$_pn_target_sha" = "$_pn_backup_sha" ] || {
    >&2 echo "! Backup digest differs from current target"
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
  _pn_superkey_sha=$(patchnest_superkey_sha256) || return 1

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
  "superkey_sha256": "$_pn_superkey_sha",
  "backup_verified": true
}
EOF
  mv "$MANIFEST_CANDIDATE.tmp" "$MANIFEST_CANDIDATE" || return 1
  BACKUP_COMMITTED=1
  echo "- Verified rollback backup: $BACKUP_CANDIDATE"
  echo "- Backup digest: $_pn_backup_sha"
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
      [ "$(xxd -l 4 -p "$_pn_kpm" 2>/dev/null)" = "7f454c46" ] || {
        >&2 echo "! Embedded KPM is not ELF: $_pn_kpm"; return 1;
      }
      _pn_machine=$(xxd -s 18 -l 2 -e "$_pn_kpm" 2>/dev/null | awk '{print $2}')
      [ "$_pn_machine" = "000000b7" ] || {
        >&2 echo "! Embedded KPM is not AArch64: $_pn_kpm"; return 1;
      }
      _pn_meta=$(kptools -l -M "$_pn_kpm" 2>/dev/null) || {
        >&2 echo "! kptools cannot validate embedded KPM: $_pn_kpm"; return 1;
      }
      _pn_name=$(printf '%s\n' "$_pn_meta" | sed -n 's/^name=//p' | head -n 1)
      [ -n "$_pn_name" ] || {
        >&2 echo "! Embedded KPM metadata has no name: $_pn_kpm"; return 1;
      }
      echo "  - verified embedded KPM: $_pn_name"
    fi
    _pn_prev=$_pn_arg
  done
  [ "$_pn_prev" != "-M" ] || { >&2 echo "! -M requires a KPM file"; return 1; }
}

write_flash_receipt() {
  _pn_image=$1
  _pn_sha=$(hash_path "$_pn_image") || return 1
  _pn_size=$(wc -c < "$_pn_image" 2>/dev/null | tr -d ' ')
  _pn_time=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
  _pn_key_sha=$(patchnest_superkey_sha256) || return 1
  mkdir -p "$PNDIR" || return 1
  umask 077
  cat > "$PNDIR/last_flash.json.tmp" <<EOF
{
  "boot_target": "$(json_escape "$BOOT_TARGET")",
  "written_sha256": "$_pn_sha",
  "written_size": $_pn_size,
  "superkey_sha256": "$_pn_key_sha",
  "verified_readback": true,
  "flashed_at": "$(json_escape "$_pn_time")"
}
EOF
  chmod 0600 "$PNDIR/last_flash.json.tmp" || return 1
  mv "$PNDIR/last_flash.json.tmp" "$PNDIR/last_flash.json"
}

cd "$WORKDIR" || exit 1
cp "$KPIMG_SOURCE" "$WORKDIR/kpimg" || { >&2 echo "! Failed to stage kpimg"; exit 1; }
[ -s "$WORKDIR/kpimg" ] || { >&2 echo "! Staged kpimg is empty"; exit 1; }

# Key generation remains private to this operation until every image/KPM check
# has passed. A persistent pending key is created only immediately before the
# first destructive target write.
patchnest_prepare_superkey "$WORKDIR" || exit 1

echo "- Unpacking current boot image into private workspace"
magiskboot unpack "$BOOT_TARGET" >/dev/null 2>&1 || { >&2 echo "! Unpack failed"; exit 1; }
[ -s kernel ] || { >&2 echo "! Unpack produced no kernel"; exit 1; }

if kptools -i kernel -f 2>/dev/null | grep -q 'CONFIG_KPM=y'; then
  >&2 echo "! Built-in KPM detected (CONFIG_KPM=y); PatchNest patching is unsupported"
  exit 1
fi
if ! kptools -i kernel -f 2>/dev/null | grep -q 'CONFIG_KALLSYMS_ALL=y'; then
  >&2 echo "! CONFIG_KALLSYMS_ALL is required"
  exit 1
fi

validate_embedded_kpms "$@" || exit 1

if [ "$FLASH_TO_DEVICE" = "true" ]; then
  write_verified_backup || exit 1
fi

mv kernel kernel.ori
echo "- Patching kernel"
kptools -p -i kernel.ori -k kpimg -s "$PATCHNEST_SUPERKEY" -o kernel "$@" || {
  >&2 echo "! Kernel patch failed"; exit 1;
}
[ -s kernel ] || { >&2 echo "! kptools produced an empty kernel"; exit 1; }

echo "- Repacking boot image"
magiskboot repack "$BOOT_TARGET" >/dev/null 2>&1 || { >&2 echo "! Repack failed"; exit 1; }
[ -s new-boot.img ] || { >&2 echo "! Repack produced no new-boot.img"; exit 1; }
validate_boot_image "$WORKDIR/new-boot.img" || {
  >&2 echo "! Repacked boot image failed validation"; exit 1;
}

if [ "$FLASH_TO_DEVICE" = "true" ]; then
  # Persist the candidate credential only now, immediately adjacent to the
  # destructive transaction. No earlier validation failure can leave it behind.
  patchnest_stage_superkey_for_flash || {
    >&2 echo "! Could not stage Public1158 credential for destructive write"
    exit 1
  }

  echo "- Flashing through destructive transaction + verified rollback guard"
  patchnest_transactional_flash "$WORKDIR/new-boot.img" "$BOOT_TARGET" "$BACKUP_CANDIDATE"
  _pn_tx_rc=$?
  if [ "$_pn_tx_rc" -ne 0 ]; then
    >&2 echo "! Patch transaction failed: $_pn_tx_rc"
    save_image_to_storage "$WORKDIR/new-boot.img" || true
    case "$_pn_tx_rc" in
      21|23) touch "$MODULE_DIR/unresolved" ;;
    esac
    exit 1
  fi

  if ! patchnest_commit_superkey; then
    >&2 echo "! Boot write verified, but credential/binding commit failed"
    if ! patchnest_rollback_after_commit_failure "$BOOT_TARGET" "$BACKUP_CANDIDATE"; then
      touch "$MODULE_DIR/unresolved"
    fi
    exit 1
  fi

  if ! write_flash_receipt "$WORKDIR/new-boot.img"; then
    >&2 echo "! Flash committed safely, but evidence receipt creation failed"
    touch "$MODULE_DIR/unresolved"
    exit 1
  fi
  echo "- Successfully flashed, read back, and committed Public1158 transaction"
else
  _pn_export_key=$(patchnest_store_export_key "$WORKDIR/new-boot.img") || {
    >&2 echo "! Could not store root-only credential record for exported image"; exit 1;
  }
  save_image_to_storage "$WORKDIR/new-boot.img" || exit 1
  echo "- Successfully patched and validated"
  echo "- Root-only credential record: $_pn_export_key"
fi

exit 0
