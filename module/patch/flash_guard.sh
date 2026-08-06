#!/system/bin/sh
# PatchNest fail-closed flash helpers.
#
# Source this file after util_functions.sh. It intentionally overrides
# flash_image() only for PatchNest's boot patch/unpatch paths.

image_stream_size() {
  _source=$1
  case "$_source" in
    *.gz)
      gzip -dc "$_source" 2>/dev/null | wc -c | tr -d ' '
      ;;
    *)
      stat -c '%s' "$_source" 2>/dev/null
      ;;
  esac
}

image_stream_sha256() {
  _source=$1
  command -v sha256sum >/dev/null 2>&1 || return 1
  case "$_source" in
    *.gz)
      gzip -dc "$_source" 2>/dev/null | sha256sum | awk '{print $1}'
      ;;
    *)
      sha256sum "$_source" 2>/dev/null | awk '{print $1}'
      ;;
  esac
}

materialize_image() {
  _source=$1
  _destination=$2
  case "$_source" in
    *.gz)
      gzip -dc "$_source" >"$_destination" 2>/dev/null
      ;;
    *)
      cp "$_source" "$_destination"
      ;;
  esac
}

is_supported_boot_target_name() {
  case "$1" in
    boot|boot_a|boot_b|boot-[ab]|kern-a|kern-b|kern_a|kern_b|android_boot|kernel|bootimg|lnx)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

assert_kernel_boot_target() {
  _target=$1
  [ -n "$_target" ] || {
    echo "! Empty boot target" >&2
    return 1
  }
  [ -e "$_target" ] || {
    echo "! Boot target does not exist: $_target" >&2
    return 1
  }

  _resolved=$(readlink -f "$_target" 2>/dev/null || printf '%s' "$_target")
  _name=$(basename "$_resolved")
  case "$_name" in
    vendor_boot|vendor_boot_a|vendor_boot_b|init_boot|init_boot_a|init_boot_b)
      echo "! Refusing non-kernel partition target: $_name" >&2
      return 1
      ;;
  esac

  if [ -b "$_target" ] || [ -c "$_target" ]; then
    if ! is_supported_boot_target_name "$_name"; then
      echo "! Refusing unknown direct-flash partition: $_name" >&2
      return 1
    fi
  fi
  return 0
}

verify_block_image_prefix() {
  _source=$1
  _target=$2
  _size=$3
  _block_size=$4

  command -v sha256sum >/dev/null 2>&1 || return 1
  command -v head >/dev/null 2>&1 || return 1
  [ "$_size" -gt 0 ] 2>/dev/null || return 1
  [ "$_block_size" -gt 0 ] 2>/dev/null || _block_size=4096

  _blocks=$(((_size + _block_size - 1) / _block_size))
  _expected=$(image_stream_sha256 "$_source") || return 1
  [ -n "$_expected" ] || return 1

  _actual=$(dd if="$_target" bs="$_block_size" count="$_blocks" iflag=fullblock 2>/dev/null \
    | head -c "$_size" \
    | sha256sum \
    | awk '{print $1}')
  [ -n "$_actual" ] || return 1
  [ "$_actual" = "$_expected" ]
}

flash_image() {
  _source=$1
  _target=$2
  _temporary=""

  [ -s "$_source" ] || {
    echo "! Flash source missing or empty: $_source" >&2
    return 3
  }
  assert_kernel_boot_target "$_target" || return 4

  if [ -c "$_target" ]; then
    # NAND character-device writes cannot use the exact block-prefix readback
    # verifier below. Do not claim a verified flash when no equivalent proof
    # exists. A separate device-specific recovery procedure is required.
    echo "! Character-device boot flashing is not verified and is disabled" >&2
    return 7
  fi
  [ -b "$_target" ] || {
    echo "! Direct flash target is not a block device: $_target" >&2
    return 4
  }

  _raw_source=$_source
  case "$_source" in
    *.gz)
      _temporary=$(mktemp "${TMPDIR:-/data/local/tmp}/patchnest-image.XXXXXX") || return 3
      if ! materialize_image "$_source" "$_temporary" || [ ! -s "$_temporary" ]; then
        rm -f "$_temporary"
        echo "! Failed to decompress flash source" >&2
        return 3
      fi
      _raw_source=$_temporary
      ;;
  esac

  _image_size=$(stat -c '%s' "$_raw_source" 2>/dev/null)
  _target_size=$(blockdev --getsize64 "$_target" 2>/dev/null)
  _block_size=$(blockdev --getbsz "$_target" 2>/dev/null)
  [ "$_image_size" -gt 0 ] 2>/dev/null || {
    rm -f "$_temporary"
    return 3
  }
  [ "$_target_size" -gt 0 ] 2>/dev/null || {
    rm -f "$_temporary"
    return 4
  }
  [ "$_block_size" -gt 0 ] 2>/dev/null || _block_size=4096
  if [ "$_image_size" -gt "$_target_size" ]; then
    rm -f "$_temporary"
    echo "! Image is larger than target partition" >&2
    return 1
  fi

  blockdev --setrw "$_target" >/dev/null 2>&1 || {
    rm -f "$_temporary"
    return 2
  }
  _read_only=$(blockdev --getro "$_target" 2>/dev/null)
  [ "$_read_only" = "0" ] || {
    rm -f "$_temporary"
    return 2
  }

  if ! dd if="$_raw_source" of="$_target" bs="$_block_size" iflag=fullblock conv=notrunc,fsync 2>/dev/null; then
    rm -f "$_temporary"
    return 5
  fi
  sync

  if ! verify_block_image_prefix "$_raw_source" "$_target" "$_image_size" "$_block_size"; then
    rm -f "$_temporary"
    echo "! Flash readback verification failed: $_target" >&2
    return 6
  fi

  rm -f "$_temporary"
  return 0
}
