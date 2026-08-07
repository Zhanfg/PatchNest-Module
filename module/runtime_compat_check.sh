#!/system/bin/sh
# PatchNest read-only Android runtime compatibility probe.
# Usage: runtime_compat_check.sh [--stdout|--write|--strict]
# It never changes block-device flags and never writes to a boot partition.

set -u
umask 077

MODE=stdout
case "${1:-}" in
  ''|--stdout) MODE=stdout ;;
  --write) MODE=write ;;
  --strict) MODE=strict ;;
  -h|--help)
    cat <<'USAGE'
Usage: runtime_compat_check.sh [--stdout|--write|--strict]
  --stdout  print report only (default)
  --write   print and persist report under PatchNest diagnostics
  --strict  persist report and fail when a required check fails
USAGE
    exit 0
    ;;
  *) echo "! Unknown argument: $1" >&2; exit 2 ;;
esac

MODDIR=${PATCHNEST_MODDIR_OVERRIDE:-${0%/*}}
STATE_DIR=${PATCHNEST_STATE_DIR:-/data/adb/patchnest}
SYSTEM_SHELL=${PATCHNEST_SYSTEM_SHELL:-/system/bin/sh}
EXPECT_ARCH=${PATCHNEST_COMPAT_EXPECT_ARCH:-arm64}
SKIP_ANDROID_TARGET=${PATCHNEST_COMPAT_SKIP_ANDROID_TARGET:-0}
SKIP_BINARIES=${PATCHNEST_COMPAT_SKIP_BINARIES:-0}
DIAG_DIR="$STATE_DIR/diagnostics"
REPORT_TMP=""
REPORT_FILE=""
WORK=""
REQUIRED_FAILURES=0
CHECK_COUNT=0

cleanup() {
  [ -z "$WORK" ] || rm -rf "$WORK" 2>/dev/null || true
  [ -z "$REPORT_TMP" ] || rm -f "$REPORT_TMP" 2>/dev/null || true
}
trap cleanup 0 1 2 15

sanitize_detail() {
  printf '%s' "$*" | tr '\t\r\n' '   ' | head -c 240
}

emit() {
  _id=$1
  _status=$2
  _required=$3
  shift 3
  _detail=$(sanitize_detail "$*")
  CHECK_COUNT=$((CHECK_COUNT + 1))
  [ "$_status" != "fail" ] || [ "$_required" != "yes" ] || REQUIRED_FAILURES=$((REQUIRED_FAILURES + 1))
  printf '%s\t%s\t%s\t%s\n' "$_id" "$_status" "$_required" "$_detail" | tee -a "$REPORT_TMP"
}

has_command() { command -v "$1" >/dev/null 2>&1; }

prepare_report() {
  if [ "$MODE" = "write" ] || [ "$MODE" = "strict" ]; then
    mkdir -p "$DIAG_DIR" 2>/dev/null || return 1
    chmod 0700 "$DIAG_DIR" 2>/dev/null || true
    _stamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf 'unknown')
    REPORT_FILE="$DIAG_DIR/runtime-compat-${_stamp}-$$.tsv"
    REPORT_TMP="${REPORT_FILE}.tmp"
  else
    REPORT_TMP="${TMPDIR:-/data/local/tmp}/patchnest-runtime-compat.$$.tsv"
  fi
  : >"$REPORT_TMP" || return 1
  chmod 0600 "$REPORT_TMP" 2>/dev/null || true
  printf '%s\n' 'check_id	status	required	detail' | tee -a "$REPORT_TMP"
}

prepare_report || exit 1

if [ -x "$SYSTEM_SHELL" ]; then
  emit system_shell pass yes "$SYSTEM_SHELL is executable"
else
  emit system_shell fail yes "$SYSTEM_SHELL is missing or not executable"
fi

_arch=""
has_command getprop && _arch=$(getprop ro.product.cpu.abi 2>/dev/null || true)
[ -n "$_arch" ] || _arch=$(uname -m 2>/dev/null || true)
case "$EXPECT_ARCH:$_arch" in
  any:*) emit architecture pass yes "detected=$_arch expected=any" ;;
  arm64:arm64-v8a|arm64:aarch64|arm64:arm64) emit architecture pass yes "detected=$_arch" ;;
  *) emit architecture fail yes "detected=${_arch:-unknown} expected=$EXPECT_ARCH" ;;
esac

if [ "$SKIP_BINARIES" = "1" ]; then
  emit module_binaries warn no 'skipped by PATCHNEST_COMPAT_SKIP_BINARIES=1'
else
  _missing=""
  for _binary in kpatch kptools kpimg magiskboot kpm-verify kp-safemode; do
    [ -x "$MODDIR/bin/$_binary" ] || _missing="${_missing}${_missing:+,}$_binary"
  done
  if [ -z "$_missing" ]; then
    emit module_binaries pass yes 'kpatch,kptools,kpimg,magiskboot,kpm-verify,kp-safemode are executable'
  else
    emit module_binaries fail yes "missing or non-executable: $_missing"
  fi
fi

has_command mktemp && WORK=$(mktemp -d "${TMPDIR:-/data/local/tmp}/patchnest-compat.XXXXXX" 2>/dev/null || true)
if [ -n "$WORK" ] && [ -d "$WORK" ] && [ ! -L "$WORK" ]; then
  emit mktemp_directory pass yes "$WORK"
else
  emit mktemp_directory fail yes 'mktemp -d with XXXXXX template failed'
fi

if [ -n "$WORK" ]; then
  printf '%s' probe >"$WORK/probe.txt" 2>/dev/null || true

  if has_command stat && [ "$(stat -c '%s' "$WORK/probe.txt" 2>/dev/null || true)" = "5" ]; then
    emit stat_c pass yes 'stat -c %s works'
  else
    emit stat_c fail yes 'stat -c %s is unavailable or incompatible'
  fi

  if has_command readlink; then
    ln -s "$WORK/probe.txt" "$WORK/probe.link" 2>/dev/null || true
    _resolved=$(readlink -f "$WORK/probe.link" 2>/dev/null || true)
    [ "$_resolved" = "$WORK/probe.txt" ] \
      && emit readlink_f pass yes 'readlink -f resolves a symlink' \
      || emit readlink_f fail yes "resolved=${_resolved:-none}"
  else
    emit readlink_f fail yes 'readlink command missing'
  fi

  has_command du && du -sk "$WORK" >/dev/null 2>&1 \
    && emit du_sk pass yes 'du -sk works' \
    || emit du_sk fail yes 'du -sk is unavailable or incompatible'

  if has_command sha256sum && (cd "$WORK" && sha256sum probe.txt >probe.sha256 && sha256sum -c probe.sha256 >/dev/null 2>&1); then
    emit sha256sum_check pass yes 'sha256sum and sha256sum -c work'
  else
    emit sha256sum_check fail yes 'sha256sum or sha256sum -c failed'
  fi

  _zip="$WORK/probe.zip"
  printf '%b' '\120\113\003\004\024\000\000\000\000\000\274\020\007\135\175\016\026\332\003\000\000\000\003\000\000\000\011\000\000\000\160\162\157\142\145\056\164\170\164\157\153\012\120\113\001\002\024\003\024\000\000\000\000\000\274\020\007\135\175\016\026\332\003\000\000\000\003\000\000\000\011\000\000\000\000\000\000\000\000\000\000\000\200\001\000\000\000\000\160\162\157\142\145\056\164\170\164\120\113\005\006\000\000\000\000\001\000\001\000\067\000\000\000\052\000\000\000\000\000' >"$_zip"
  if has_command unzip && [ "$(unzip -Z1 "$_zip" 2>/dev/null)" = "probe.txt" ]; then
    emit unzip_z1 pass yes 'unzip -Z1 lists the fixture entry'
  else
    emit unzip_z1 fail yes 'unzip -Z1 is unavailable or incompatible'
  fi

  printf '0123456789abcdef' >"$WORK/dd.in"
  if has_command dd && has_command sha256sum \
     && dd if="$WORK/dd.in" of="$WORK/dd.out" bs=4 iflag=fullblock conv=notrunc,fsync >/dev/null 2>&1 \
     && [ "$(sha256sum "$WORK/dd.in" 2>/dev/null | awk '{print $1}')" = "$(sha256sum "$WORK/dd.out" 2>/dev/null | awk '{print $1}')" ]; then
    emit dd_flags pass yes 'iflag=fullblock and conv=notrunc,fsync work on a temporary file'
  else
    emit dd_flags fail yes 'required dd flags failed on a temporary file'
  fi

  if [ -f "$MODDIR/kpm_verify.sh" ]; then
    PNDIR="$WORK/state"
    LOG="$WORK/kpm-verify.log"
    TMPDIR="$WORK/tmp"
    mkdir -p "$PNDIR" "$TMPDIR"
    . "$MODDIR/kpm_verify.sh"
    if kpm_verify__require_backend && [ "$KPM_VERIFY_BACKEND" = binary ]; then
      emit ed25519_verifier pass yes 'packaged static Ed25519 verifier passed deployment-key probe'
    else
      emit ed25519_verifier fail yes 'packaged static Ed25519 verifier unavailable or invalid'
    fi
  else
    emit ed25519_verifier fail yes 'kpm_verify.sh missing'
  fi
fi

if has_command blockdev; then
  _help=$(blockdev --help 2>&1 || true)
  _missing_options=""
  for _option in --getsize64 --getbsz --getro --setrw; do
    printf '%s' "$_help" | grep -q -- "$_option" || _missing_options="${_missing_options}${_missing_options:+,}$_option"
  done
  if [ -z "$_missing_options" ]; then
    emit blockdev_options pass yes 'required options are advertised; --setrw was not executed'
  else
    emit blockdev_options fail yes "missing advertised options: $_missing_options"
  fi
else
  emit blockdev_options fail yes 'blockdev command missing'
fi

if [ "$SKIP_ANDROID_TARGET" = "1" ]; then
  emit boot_target_mapping warn no 'skipped by PATCHNEST_COMPAT_SKIP_ANDROID_TARGET=1'
elif [ -f "$MODDIR/patch/util_functions.sh" ] && [ -f "$MODDIR/patch/flash_guard.sh" ] && [ -f "$MODDIR/patch/boot_target.sh" ]; then
  BOOTMODE=true
  OUTFD=1
  MODPATH="$MODDIR/patch"
  SLOT=""
  . "$MODDIR/patch/util_functions.sh"
  . "$MODDIR/patch/flash_guard.sh"
  . "$MODDIR/patch/boot_target.sh"
  get_current_slot >/dev/null 2>&1 || true
  if find_kernel_boot_image >/dev/null 2>&1; then
    _target=$BOOTIMAGE
    _name=$(partition_name_for_target "$_target")
    _size=$(blockdev --getsize64 "$_target" 2>/dev/null || true)
    _bs=$(blockdev --getbsz "$_target" 2>/dev/null || true)
    _ro=$(blockdev --getro "$_target" 2>/dev/null || true)
    if is_supported_boot_target_name "$_name" && [ "$_size" -gt 0 ] 2>/dev/null && [ "$_bs" -gt 0 ] 2>/dev/null \
       && { [ "$_ro" = "0" ] || [ "$_ro" = "1" ]; }; then
      emit boot_target_mapping pass yes "target=$_target partition=$_name size=$_size block_size=$_bs read_only=$_ro"
    else
      emit boot_target_mapping fail yes "target=${_target:-none} partition=${_name:-unknown} size=${_size:-unknown} block_size=${_bs:-unknown} read_only=${_ro:-unknown}"
    fi
  else
    emit boot_target_mapping fail yes 'no supported kernel-bearing boot target was found'
  fi
else
  emit boot_target_mapping fail yes 'boot target helper files are missing'
fi

printf 'summary\t%s\tyes\tchecks=%s required_failures=%s\n' \
  "$([ "$REQUIRED_FAILURES" -eq 0 ] && printf pass || printf fail)" "$CHECK_COUNT" "$REQUIRED_FAILURES" | tee -a "$REPORT_TMP"

if [ "$MODE" = "write" ] || [ "$MODE" = "strict" ]; then
  mv "$REPORT_TMP" "$REPORT_FILE" || exit 1
  REPORT_TMP=""
  chmod 0600 "$REPORT_FILE" 2>/dev/null || true
  echo "- Compatibility report: $REPORT_FILE"
fi

[ "$MODE" != "strict" ] || [ "$REQUIRED_FAILURES" -eq 0 ] || exit 1
exit 0
