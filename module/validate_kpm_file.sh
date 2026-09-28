#!/system/bin/sh
# Validate one direct KPM file before any userspace path may call kpatch kpm load.
# Usage: validate_kpm_file.sh <file>

set -u

MODDIR=${0%/*}
PNDIR="/data/adb/patchnest"
PATH="$MODDIR/bin:$PATH"
KPM_FILE=${1:-}

fail() {
    printf '%s\n' "! $1" >&2
    exit "${2:-1}"
}

[ -n "$KPM_FILE" ] || fail "Usage: validate_kpm_file.sh <file>" 2
[ -f "$KPM_FILE" ] && [ ! -L "$KPM_FILE" ] && [ -s "$KPM_FILE" ] \
    || fail "KPM file is missing, empty, non-regular, or a symlink" 2

# Physical FR-014 candidate keeps normal persistent/direct KPM paths disabled.
# The only allowed direct load is the controlled device_validation.sh kpm-cycle
# phase. The context/unlock only exempts the candidate-mode ban;
# ELF/metadata/signature admission below still runs in full.
if [ -f "$MODDIR/FR014_DEVICE_CANDIDATE" ] && \
   [ "${PATCHNEST_KPM_CONTEXT:-}" != "KPM_CYCLE" ] && \
   [ "${PATCHNEST_DEVICE_TEST_UNLOCK:-}" != "KPM_CYCLE" ]; then
    fail "Direct KPM loading is disabled on the FR-014 device candidate" 3
fi

command -v xxd >/dev/null 2>&1 || fail "xxd is required for KPM ELF validation"
[ -x "$MODDIR/bin/kptools" ] || fail "kptools is unavailable"

_hdr=$(xxd -p -l 20 "$KPM_FILE" 2>/dev/null | tr -d '\r\n')
[ "$(printf '%s' "$_hdr" | cut -c1-12)" = "7f454c460201" ] \
    || fail "KPM is not ELF64 little-endian"
[ "$(printf '%s' "$_hdr" | cut -c37-40)" = "b700" ] \
    || fail "KPM is not AArch64"

_meta=$(kptools -l -M "$KPM_FILE" 2>/dev/null) || fail "kptools rejected KPM metadata"
_name=$(printf '%s\n' "$_meta" | sed -n 's/^name=//p' | head -n 1)
[ -n "$_name" ] || fail "KPM metadata has no module name"

POLICY=warn
if [ -f "$PNDIR/config" ]; then
    _raw=$(grep -E '^[[:space:]]*(export[[:space:]]+)?KPM_SIGNATURE_POLICY[[:space:]]*=' \
        "$PNDIR/config" 2>/dev/null | tail -1 | sed -E 's/^[^=]*=//' | tr -d '"\r\n' | tr 'A-Z' 'a-z')
    case "$_raw" in
        off) POLICY=off ;;
        warn) POLICY=warn ;;
        strict) POLICY=strict ;;
        0|false) POLICY=off ;;
        1|true|yes|on) POLICY=strict ;;
    esac
fi

SIG_FILE="${KPM_FILE}.sig"
if [ "$POLICY" != "off" ]; then
    if [ -f "$SIG_FILE" ] && [ ! -L "$SIG_FILE" ]; then
        # shellcheck disable=SC1091
        . "$MODDIR/kpm_verify.sh" || fail "KPM signature verifier unavailable"
        verify_kpm_sig "$KPM_FILE" "$SIG_FILE" || fail "KPM signature verification failed"
    elif [ "$POLICY" = "strict" ]; then
        fail "Unsigned direct KPM rejected by strict signature policy"
    else
        printf '%s\n' "- WARNING: unsigned direct KPM accepted by warn policy: $(basename "$KPM_FILE")" >&2
    fi
fi

printf '%s\n' "KPM_VALIDATED name=$_name policy=$POLICY"
exit 0
