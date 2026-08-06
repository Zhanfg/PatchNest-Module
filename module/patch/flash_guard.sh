#!/system/bin/sh
# PatchNest fail-closed flash helpers.
# Source after util_functions.sh to override direct boot flashing and image save.

image_stream_size() {
  case "$1" in
    *.gz) gzip -dc "$1" 2>/dev/null | wc -c | tr -d ' ' ;;
    *) stat -c '%s' "$1" 2>/dev/null ;;
  esac
}

image_stream_sha256() {
  command -v sha256sum >/dev/null 2>&1 || return 1
  case "$1" in
    *.gz) gzip -dc "$1" 2>/dev/null | sha256sum | awk '{print $1}' ;;
    *) sha256sum "$1" 2>/dev/null | awk '{print $1}' ;;
  esac
}

is_supported_boot_target_name() {
  case "$1" in
    boot|boot_a|boot_b|boot-[ab]|kern-a|kern-b|kern_a|kern_b|android_boot|kernel|bootimg|lnx) return 0 ;;
    *) return 1 ;;
  esac
}

is_forbidden_boot_target_name() {
  case "$1" in
    vendor_boot|vendor_boot_a|vendor_boot_b|init_boot|init_boot_a|init_boot_b) return 0 ;;
    *) return 1 ;;
  esac
}

partition_name_for_target() {
  _target=$1
  _direct_name=$(basename "$_target")
  if is_supported_boot_target_name "$_direct_name" || is_forbidden_boot_target_name "$_direct_name"; then
    printf '%s' "$_direct_name"
    return 0
  fi

  _resolved=$(readlink -f "$_target" 2>/dev/null || printf '%s' "$_target")
  _device_name=$(basename "$_resolved")
  _uevent="/sys/class/block/${_device_name}/uevent"
  if [ -f "$_uevent" ]; then
    _partname=$(sed -n 's/^PARTNAME=//p' "$_uevent" 2>/dev/null | head -n 1)
    if [ -n "$_partname" ]; then
      printf '%s' "$_partname"
      return 0
    fi
  fi

  for _dir in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/platform/*/by-name; do
    [ -d "$_dir" ] || continue
    for _link in "$_dir"/*; do
      [ -e "$_link" ] || continue
      _link_resolved=$(readlink -f "$_link" 2>/dev/null || true)
      if [ "$_link_resolved" = "$_resolved" ]; then
        basename "$_link"
        return 0
      fi
    done
  done

  printf '%s' "$_device_name"
}

assert_kernel_boot_target() {
  _target=$1
  [ -n "$_target" ] || { echo "! Empty boot target" >&2; return 1; }
  [ -e "$_target" ] || { echo "! Boot target does not exist: $_target" >&2; return 1; }

  _partition_name=$(partition_name_for_target "$_target")
  if is_forbidden_boot_target_name "$_partition_name"; then
    echo "! Refusing non-kernel partition target: $_partition_name" >&2
    return 1
  fi
  if [ -b "$_target" ] || [ -c "$_target" ]; then
    if ! is_supported_boot_target_name "$_partition_name"; then
      echo "! Refusing unknown direct-flash partition: $_partition_name" >&2
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
    | head -c "$_size" | sha256sum | awk '{print $1}')
  [ -n "$_actual" ] && [ "$_actual" = "$_expected" ]
}

flash_image() {
  _source=$1
  _target=$2
  _temporary=""
  [ -s "$_source" ] || { echo "! Flash source missing or empty: $_source" >&2; return 3; }
  assert_kernel_boot_target "$_target" || return 4

  if [ -c "$_target" ]; then
    echo "! Character-device boot flashing is not verified and is disabled" >&2
    return 7
  fi
  [ -b "$_target" ] || { echo "! Direct flash target is not a block device: $_target" >&2; return 4; }

  _raw_source=$_source
  case "$_source" in
    *.gz)
      _temporary=$(mktemp "${TMPDIR:-/data/local/tmp}/patchnest-image.XXXXXX") || return 3
      if ! gzip -dc "$_source" >"$_temporary" 2>/dev/null || [ ! -s "$_temporary" ]; then
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
  [ "$_image_size" -gt 0 ] 2>/dev/null || { [ -z "$_temporary" ] || rm -f "$_temporary"; return 3; }
  [ "$_target_size" -gt 0 ] 2>/dev/null || { [ -z "$_temporary" ] || rm -f "$_temporary"; return 4; }
  [ "$_block_size" -gt 0 ] 2>/dev/null || _block_size=4096
  if [ "$_image_size" -gt "$_target_size" ]; then
    [ -z "$_temporary" ] || rm -f "$_temporary"
    echo "! Image is larger than target partition" >&2
    return 1
  fi

  blockdev --setrw "$_target" >/dev/null 2>&1 || { [ -z "$_temporary" ] || rm -f "$_temporary"; return 2; }
  _read_only=$(blockdev --getro "$_target" 2>/dev/null)
  [ "$_read_only" = "0" ] || { [ -z "$_temporary" ] || rm -f "$_temporary"; return 2; }

  if ! dd if="$_raw_source" of="$_target" bs="$_block_size" iflag=fullblock conv=notrunc,fsync 2>/dev/null; then
    [ -z "$_temporary" ] || rm -f "$_temporary"
    return 5
  fi
  sync
  if ! verify_block_image_prefix "$_raw_source" "$_target" "$_image_size" "$_block_size"; then
    [ -z "$_temporary" ] || rm -f "$_temporary"
    echo "! Flash readback verification failed: $_target" >&2
    return 6
  fi
  [ -z "$_temporary" ] || rm -f "$_temporary"
  return 0
}

save_image_to_storage() {
  _source=$1
  [ -s "$_source" ] || { echo "! Image to save is missing or empty" >&2; return 1; }
  _stamp=$(date +%Y%m%d%H%M%S 2>/dev/null || printf 'unknown')
  if [ -d /storage/emulated/0/Download ]; then
    _output="/storage/emulated/0/Download/patchnest_patched_${_stamp}_$$.img"
  else
    _output="${TMPDIR:-/data/local/tmp}/patchnest_patched_${_stamp}_$$.img"
  fi
  if ! cp "$_source" "$_output" || [ ! -s "$_output" ]; then
    rm -f "$_output"
    echo "! Failed to save image: $_output" >&2
    return 1
  fi
  _source_sha=$(image_stream_sha256 "$_source") || { rm -f "$_output"; return 1; }
  _output_sha=$(image_stream_sha256 "$_output") || { rm -f "$_output"; return 1; }
  if [ "$_source_sha" != "$_output_sha" ]; then
    rm -f "$_output"
    echo "! Saved image verification failed" >&2
    return 1
  fi
  echo "- Patched image saved and verified: $_output"
  echo "- Saved image SHA256: $_output_sha"
  return 0
}
