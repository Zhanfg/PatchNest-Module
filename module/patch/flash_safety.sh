#!/system/bin/sh
# PatchNest flash-path safety overrides.
# Source this AFTER util_functions.sh. It deliberately replaces only the
# high-risk helpers used by PatchNest boot patch/unpatch flows.

# Transaction binding helpers are kept separate from the low-level writer but
# are loaded here so every reviewed patch/unpatch path receives the same device
# identity and rollback semantics.
if [ -n "${MODPATH:-}" ] && [ -f "$MODPATH/transaction_safety.sh" ]; then
  # shellcheck disable=SC1091
  . "$MODPATH/transaction_safety.sh"
fi

# No eval: supported Magisk/APatch config keys are assigned explicitly.
getvar() {
  _pn_key=$1
  _pn_proppath='/data/.magisk /cache/.magisk'
  [ -n "${MAGISKTMP:-}" ] && _pn_proppath="$MAGISKTMP/.magisk/config $_pn_proppath"
  _pn_value=$(grep_prop "$_pn_key" $_pn_proppath)

  case "$_pn_key" in
    KEEPVERITY) KEEPVERITY=$_pn_value ;;
    KEEPFORCEENCRYPT) KEEPFORCEENCRYPT=$_pn_value ;;
    RECOVERYMODE) RECOVERYMODE=$_pn_value ;;
    *) abort "! getvar: unsupported key '$_pn_key'" ;;
  esac
}

# Resolve only a real boot partition. vendor_boot/init_boot are not generic
# substitutes and are intentionally excluded until they have their own patch
# implementation and validation matrix.
find_boot_image() {
  BOOTIMAGE=''

  if [ -n "${SLOT:-}" ]; then
    case "$SLOT" in
      _a|_b) ;;
      *) abort "! Invalid active slot suffix: '$SLOT'" ;;
    esac
    BOOTIMAGE=$(find_block "boot$SLOT" "kern$SLOT" "kern-$SLOT" 2>/dev/null)
    [ -n "$BOOTIMAGE" ] || abort "! Cannot resolve boot partition for active slot $SLOT"
    echo "BOOTIMAGE=$BOOTIMAGE"
    return 0
  fi

  # If the device exposes slot-suffixed boot partitions but slot identity was
  # not resolved, guessing _a/_b is unsafe. Refuse instead.
  _pn_boot_a=$(find_block boot_a kern_a kern-a 2>/dev/null || true)
  _pn_boot_b=$(find_block boot_b kern_b kern-b 2>/dev/null || true)
  if [ -n "$_pn_boot_a" ] || [ -n "$_pn_boot_b" ]; then
    abort "! A/B boot partitions detected but active slot is unresolved"
  fi

  BOOTIMAGE=$(find_block boot android_boot kernel bootimg lnx 2>/dev/null || true)
  if [ -z "$BOOTIMAGE" ]; then
    BOOTIMAGE=$(grep -v '#' /etc/*fstab* 2>/dev/null \
      | grep -E '/boot(img)?[^a-zA-Z]' \
      | grep -oE '/dev/[a-zA-Z0-9_./-]*' \
      | head -n 1)
  fi

  [ -n "$BOOTIMAGE" ] || abort "! Cannot resolve a supported boot partition"
  echo "BOOTIMAGE=$BOOTIMAGE"
}

_pn_payload_prepare() {
  _pn_source=$1
  PN_FLASH_PAYLOAD=$_pn_source
  PN_FLASH_TEMP=''

  case "$_pn_source" in
    *.gz)
      PN_FLASH_TEMP=$(mktemp /data/local/tmp/patchnest_flash.XXXXXX.img) || return 1
      if ! gzip -dc "$_pn_source" > "$PN_FLASH_TEMP"; then
        rm -f "$PN_FLASH_TEMP"
        PN_FLASH_TEMP=''
        return 1
      fi
      PN_FLASH_PAYLOAD=$PN_FLASH_TEMP
      ;;
  esac
  return 0
}

_pn_payload_cleanup() {
  [ -z "${PN_FLASH_TEMP:-}" ] || rm -f "$PN_FLASH_TEMP"
  PN_FLASH_TEMP=''
}

# Fail-closed writer for the general block-device release baseline:
# - normalize compressed input first;
# - verify source fits the partition;
# - write + fsync;
# - hash exactly the written byte range back from the target;
# - reject char/NAND devices until a device-specific readback strategy exists.
flash_image() {
  _pn_source=$1
  _pn_target=$2

  command -v sha256sum >/dev/null 2>&1 || return 3
  _pn_payload_prepare "$_pn_source" || return 4

  _pn_size=$(stat -c '%s' "$PN_FLASH_PAYLOAD" 2>/dev/null)
  _pn_expected=$(sha256sum "$PN_FLASH_PAYLOAD" 2>/dev/null | awk '{print $1}')
  if [ -z "$_pn_size" ] || [ "$_pn_size" -le 0 ] || \
     ! printf '%s' "$_pn_expected" | grep -Eq '^[0-9a-f]{64}$'; then
    _pn_payload_cleanup
    return 4
  fi

  if [ -b "$_pn_target" ]; then
    _pn_capacity=$(blockdev --getsize64 "$_pn_target" 2>/dev/null)
    [ -n "$_pn_capacity" ] && [ "$_pn_size" -le "$_pn_capacity" ] || {
      _pn_payload_cleanup
      return 1
    }

    blockdev --setrw "$_pn_target" 2>/dev/null || {
      _pn_payload_cleanup
      return 2
    }
    [ "$(blockdev --getro "$_pn_target" 2>/dev/null)" != "1" ] || {
      _pn_payload_cleanup
      return 2
    }

    if ! dd if="$PN_FLASH_PAYLOAD" of="$_pn_target" bs=1048576 conv=notrunc,fsync 2>/dev/null; then
      _pn_payload_cleanup
      return 5
    fi
    sync

    _pn_blocks=$(((_pn_size + 1048575) / 1048576))
    _pn_actual=$(dd if="$_pn_target" bs=1048576 count="$_pn_blocks" 2>/dev/null \
      | head -c "$_pn_size" \
      | sha256sum \
      | awk '{print $1}')
    if [ "$_pn_actual" != "$_pn_expected" ]; then
      >&2 echo "! Flash readback verification failed"
      >&2 echo "! expected=$_pn_expected actual=${_pn_actual:-unavailable}"
      _pn_payload_cleanup
      return 6
    fi
  elif [ -c "$_pn_target" ]; then
    >&2 echo "! Character/NAND flashing is not in the reviewed release baseline"
    _pn_payload_cleanup
    return 7
  else
    # File targets are used for offline image generation/tests. Verify them too.
    if ! cat "$PN_FLASH_PAYLOAD" > "$_pn_target"; then
      _pn_payload_cleanup
      return 5
    fi
    sync
    _pn_actual=$(sha256sum "$_pn_target" 2>/dev/null | awk '{print $1}')
    if [ "$_pn_actual" != "$_pn_expected" ]; then
      _pn_payload_cleanup
      return 6
    fi
  fi

  _pn_payload_cleanup
  return 0
}

save_image_to_storage() {
  _pn_image=$1
  _pn_stamp=$(date +%y%m%d%H%M%S)
  _pn_suffix="$$"
  _pn_out="/storage/emulated/0/Download/patchnest_patched_${_pn_stamp}_${_pn_suffix}.img"

  cp -f "$_pn_image" "$_pn_out" || return 1
  echo "- Patched image saved to $_pn_out"
}
