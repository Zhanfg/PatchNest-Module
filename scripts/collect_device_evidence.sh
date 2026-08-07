#!/system/bin/sh
# PatchNest read-only device evidence collector.
#
# This script never flashes, mounts, remounts, patches, unpatches, deletes, or
# changes a block device. It writes only to the selected output directory.
# Full boot-partition hashing is opt-in because it can take time and requires
# permission to read the active block device.

set -u
umask 077

HASH_BOOT=false
OUTPUT_DIR=""
MODULE_DIR=${PATCHNEST_MODULE_DIR:-/data/adb/modules/PatchNest}

usage() {
  cat <<'USAGE'
Usage: collect_device_evidence.sh [--hash-boot] [--output DIR]

  --hash-boot   Read and SHA-256 hash the active boot block device.
  --output DIR  Store evidence in DIR instead of Download/PatchNest_Evidence_*.
  -h, --help    Show this help.

The collector is read-only with respect to Android system and block devices.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hash-boot) HASH_BOOT=true; shift ;;
    --output)
      [ "$#" -ge 2 ] || { echo "missing value for --output" >&2; exit 2; }
      OUTPUT_DIR=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

TIMESTAMP=$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'unknown_time')
if [ -z "$OUTPUT_DIR" ]; then
  if [ -d /storage/emulated/0/Download ]; then
    OUTPUT_DIR="/storage/emulated/0/Download/PatchNest_Evidence_$TIMESTAMP"
  else
    OUTPUT_DIR="${TMPDIR:-/data/local/tmp}/PatchNest_Evidence_$TIMESTAMP"
  fi
fi

mkdir -p "$OUTPUT_DIR" || { echo "cannot create output directory: $OUTPUT_DIR" >&2; exit 1; }
chmod 0700 "$OUTPUT_DIR" 2>/dev/null || true

log() { printf '%s\n' "$*"; }

# Execute each diagnostic command in a subshell. The earlier brace group used
# `exit` in the collector's own shell and stopped collection after uname.txt.
write_command() {
  _name=$1
  shift
  (
    printf '$'
    for _arg in "$@"; do printf ' %s' "$_arg"; done
    printf '\n'
    "$@"
    _rc=$?
    printf '\n[exit=%s]\n' "$_rc"
    exit "$_rc"
  ) >"$OUTPUT_DIR/$_name" 2>&1 || true
}

safe_getprop() {
  getprop 2>/dev/null | grep -E '^\[(ro\.(build|product|boot|hardware|kernel)|ro\.vendor\.(build|product)|ro\.system\.(build|product)|sys\.boot_completed|vendor\.boot)\.' || true
}

resolve_slot_suffix() {
  _slot=$(getprop ro.boot.slot_suffix 2>/dev/null)
  if [ -z "$_slot" ]; then
    _slot=$(getprop ro.boot.slot 2>/dev/null)
    [ -z "$_slot" ] || _slot="_$_slot"
  fi
  case "$_slot" in _a|_b) printf '%s' "$_slot" ;; *) printf '' ;; esac
}

resolve_boot_block() {
  _slot=$1
  for _name in "boot$_slot" boot boot_a boot_b; do
    [ -n "$_name" ] || continue
    for _candidate in \
      "/dev/block/by-name/$_name" \
      "/dev/block/bootdevice/by-name/$_name" \
      "/dev/block/platform"/*/by-name/"$_name"; do
      [ -e "$_candidate" ] || continue
      readlink -f "$_candidate" 2>/dev/null || printf '%s\n' "$_candidate"
      return 0
    done
  done
  return 1
}

log "PatchNest evidence collector"
log "Output: $OUTPUT_DIR"
log "Module: $MODULE_DIR"
log "Full boot hash: $HASH_BOOT"

{
  echo "schema_version=2"
  echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  echo "collector_pid=$$"
  echo "uid=$(id -u 2>/dev/null || true)"
  echo "hash_boot=$HASH_BOOT"
  echo "module_dir=$MODULE_DIR"
} >"$OUTPUT_DIR/collector-info.txt"

write_command uname.txt uname -a
write_command id.txt id
write_command mounts.txt cat /proc/mounts
write_command cmdline.txt cat /proc/cmdline
write_command bootconfig.txt cat /proc/bootconfig
write_command verified-boot.txt sh -c 'getprop | grep -Ei "verifiedboot|vbmeta|verity|boot\.flash|slot" || true'
write_command block-by-name.txt sh -c 'for d in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/platform/*/by-name; do [ -d "$d" ] || continue; echo "## $d"; ls -la "$d"; done'
write_command patchnest-processes.txt sh -c 'ps -A 2>/dev/null | grep -Ei "patchnest|kernelpatch|kpatch|kpm" || true'
write_command patchnest-dmesg.txt sh -c 'dmesg 2>/dev/null | grep -Ei "patchnest|kernelpatch|kpatch|kpm" | tail -n 2000 || true'
write_command patchnest-logcat.txt sh -c 'logcat -d -v threadtime 2>/dev/null | grep -Ei "patchnest|kernelpatch|kpatch|kpm" | tail -n 3000 || true'

safe_getprop >"$OUTPUT_DIR/properties-filtered.txt" 2>&1

# Attach the strict compatibility result without allowing a failed probe to
# stop evidence collection. The probe is read-only and its private state is
# redirected inside the evidence directory.
COMPAT_PROBE="$MODULE_DIR/runtime_compat_check.sh"
COMPAT_STATE="$OUTPUT_DIR/runtime-compat-state"
if [ -f "$COMPAT_PROBE" ] && [ ! -L "$COMPAT_PROBE" ]; then
  mkdir -p "$COMPAT_STATE"
  PATCHNEST_MODDIR_OVERRIDE="$MODULE_DIR" \
  PATCHNEST_STATE_DIR="$COMPAT_STATE" \
    sh "$COMPAT_PROBE" --strict >"$OUTPUT_DIR/runtime-compat-console.txt" 2>&1
  COMPAT_RC=$?
  printf 'probe=%s\nexit=%s\n' "$COMPAT_PROBE" "$COMPAT_RC" >"$OUTPUT_DIR/runtime-compat-status.txt"
else
  printf 'probe=%s\nexit=127\nreason=missing_or_symlink\n' "$COMPAT_PROBE" >"$OUTPUT_DIR/runtime-compat-status.txt"
fi

SLOT_SUFFIX=$(resolve_slot_suffix)
BOOT_BLOCK=$(resolve_boot_block "$SLOT_SUFFIX" 2>/dev/null || true)
{
  echo "slot_suffix=$SLOT_SUFFIX"
  echo "boot_block=$BOOT_BLOCK"
  if [ -n "$BOOT_BLOCK" ] && [ -e "$BOOT_BLOCK" ]; then
    ls -l "$BOOT_BLOCK" 2>&1 || true
    blockdev --getsize64 "$BOOT_BLOCK" 2>&1 | sed 's/^/size_bytes=/' || true
    blockdev --getro "$BOOT_BLOCK" 2>&1 | sed 's/^/read_only=/' || true
  fi
} >"$OUTPUT_DIR/boot-target.txt"

for _module_dir in "$MODULE_DIR" /data/adb/modules_update/PatchNest /data/adb/patchnest; do
  [ -e "$_module_dir" ] || continue
  _label=$(printf '%s' "$_module_dir" | tr '/' '_')
  {
    echo "path=$_module_dir"
    ls -la "$_module_dir" 2>&1 || true
    find "$_module_dir" -maxdepth 2 -type f \( -name '*.json' -o -name '*.prop' -o -name 'boot_count' -o -name 'disable' \) -print 2>/dev/null || true
  } >"$OUTPUT_DIR/module${_label}.txt"
done

BACKUP_ROOT=""
for _candidate_root in /data/adb/patchnest/backup /data/adb/patchnest/backups; do
  if [ -d "$_candidate_root" ]; then BACKUP_ROOT=$_candidate_root; break; fi
done
if [ -n "$BACKUP_ROOT" ]; then
  echo "backup_root=$BACKUP_ROOT" >"$OUTPUT_DIR/backup-root.txt"
  mkdir -p "$OUTPUT_DIR/backup-manifests"
  find "$BACKUP_ROOT" -maxdepth 1 -type f -name 'boot_backup_*.json' -print 2>/dev/null \
    | sort \
    | while IFS= read -r _manifest; do
        _base=$(basename "$_manifest")
        cp "$_manifest" "$OUTPUT_DIR/backup-manifests/$_base" 2>/dev/null || true
      done
  find "$BACKUP_ROOT" -maxdepth 1 -type f -name 'boot_backup_*.img' -exec ls -l {} \; 2>/dev/null \
    >"$OUTPUT_DIR/backup-images-list.txt" || true
else
  echo "backup_root=not_found" >"$OUTPUT_DIR/backup-root.txt"
fi

if $HASH_BOOT; then
  if [ -z "$BOOT_BLOCK" ] || [ ! -e "$BOOT_BLOCK" ]; then
    echo "boot block not found" >"$OUTPUT_DIR/boot-sha256.txt"
  elif ! command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum unavailable" >"$OUTPUT_DIR/boot-sha256.txt"
  else
    log "Hashing active boot block read-only: $BOOT_BLOCK"
    sha256sum "$BOOT_BLOCK" >"$OUTPUT_DIR/boot-sha256.txt" 2>&1 || true
  fi
else
  echo "not requested; rerun with --hash-boot" >"$OUTPUT_DIR/boot-sha256.txt"
fi

{
  echo "No boot image bytes were copied."
  echo "No block device was written, mounted, remounted, patched, or erased."
  echo "The runtime probe did not execute blockdev --setrw."
  echo "Review property and log files before sharing; device identifiers may be present."
} >"$OUTPUT_DIR/SHARING_NOTICE.txt"

if command -v tar >/dev/null 2>&1; then
  ARCHIVE="${OUTPUT_DIR}.tar.gz"
  PARENT=$(dirname "$OUTPUT_DIR")
  BASE=$(basename "$OUTPUT_DIR")
  tar -C "$PARENT" -czf "$ARCHIVE" "$BASE" 2>/dev/null && log "Archive: $ARCHIVE"
fi

log "Evidence collection complete."
