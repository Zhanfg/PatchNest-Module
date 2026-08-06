#!/system/bin/sh
# PatchNest KPM ZIP installer.
# Usage: install_kpm.sh <path_to_zip>

set -u
umask 077

MODDIR=${0%/*}
PNDIR=/data/adb/patchnest
KPM_DIR="$PNDIR/kpm"
KPM_ZIP_DIR="$PNDIR/kpm_zips"
KPM_EVENT_DIR="$PNDIR/kpm_events"
KPM_SOURCE_DIR="$PNDIR/kpm_src"
LOG="$PNDIR/service.log"
PATH="$MODDIR/bin:$PATH"
ZIP_FILE=${1:-}
TMPDIR=""
LOCK_DIR="$PNDIR/.kpm-install.lock"

log() {
    mkdir -p "$PNDIR" 2>/dev/null || true
    printf '[%s] install_kpm: %s\n' "$(date)" "$1" >>"$LOG" 2>/dev/null || true
    printf '%s\n' "- $1"
}

fail() {
    printf '%s\n' "! $*" >&2
    exit 1
}

cleanup() {
    [ -z "$TMPDIR" ] || rm -rf "$TMPDIR"
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

get_prop() {
    _file=$1
    _key=$2
    grep -F "${_key}=" "$_file" 2>/dev/null | head -n 1 | cut -d= -f2-
}

atomic_copy() {
    _source=$1
    _destination=$2
    _mode=$3
    _temporary="${_destination}.incoming.$$"
    rm -f "$_temporary"
    cp "$_source" "$_temporary" || return 1
    [ -s "$_temporary" ] || { rm -f "$_temporary"; return 1; }
    chmod "$_mode" "$_temporary" 2>/dev/null || true
    mv "$_temporary" "$_destination"
}

validate_zip_source() {
    [ -n "$ZIP_FILE" ] && [ -f "$ZIP_FILE" ] || fail "Usage: install_kpm.sh <path_to_zip>"
    _resolved=$(readlink -f "$ZIP_FILE" 2>/dev/null || true)
    [ -n "$_resolved" ] && [ -f "$_resolved" ] || fail "Cannot resolve ZIP path"
    case "$_resolved" in
        /data/local/tmp/*|/data/adb/patchnest/*|/storage/emulated/0/Download/*|/sdcard/Download/*)
            ZIP_FILE=$_resolved
            ;;
        *)
            fail "ZIP must be under /data/local/tmp, PatchNest state, or Download"
            ;;
    esac
    [ -s "$ZIP_FILE" ] || fail "ZIP is empty"
}

preflight_zip_entries() {
    command -v unzip >/dev/null 2>&1 || fail "unzip is unavailable"
    _list="$TMPDIR/entries.txt"
    unzip -Z1 "$ZIP_FILE" >"$_list" 2>/dev/null || fail "Cannot list ZIP entries"
    [ -s "$_list" ] || fail "ZIP has no entries"

    _count=0
    while IFS= read -r _entry; do
        _count=$((_count + 1))
        [ "$_count" -le 128 ] || fail "ZIP contains more than 128 entries"
        case "$_entry" in
            ""|/*|../*|*/../*|*/..|*\\*|*':'*)
                fail "Unsafe ZIP entry: $_entry"
                ;;
        esac
        # Reject control characters and entries longer than 240 bytes.
        _clean=$(printf '%s' "$_entry" | tr -d '\000-\037\177')
        [ "$_clean" = "$_entry" ] || fail "ZIP entry contains control characters"
        [ "${#_entry}" -le 240 ] || fail "ZIP entry name is too long"
    done <"$_list"
}

validate_module_id() {
    _id=$1
    [ -n "$_id" ] && [ "${#_id}" -le 64 ] || return 1
    case "$_id" in
        .|..|*[!A-Za-z0-9_.-]*) return 1 ;;
    esac
    return 0
}

validate_kpm_binary() {
    _binary=$1
    [ -s "$_binary" ] || return 1
    command -v kptools >/dev/null 2>&1 || return 1
    kptools -l -M "$_binary" >/dev/null 2>&1
}

validate_zip_source
mkdir -p "$PNDIR" || fail "Cannot create PatchNest state directory"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "Another KPM installation is already running"
fi
TMPDIR=$(mktemp -d /data/local/tmp/patchnest-kpm.XXXXXX) || fail "Cannot create extraction directory"

preflight_zip_entries
mkdir -p "$TMPDIR/root"
unzip -o "$ZIP_FILE" -d "$TMPDIR/root" >/dev/null 2>&1 || fail "Failed to extract ZIP"

if find "$TMPDIR/root" -type l -print -quit 2>/dev/null | grep -q .; then
    fail "ZIP contains symbolic links"
fi
_extracted_kib=$(du -sk "$TMPDIR/root" 2>/dev/null | awk '{print $1}')
[ -n "$_extracted_kib" ] || fail "Cannot measure extracted ZIP"
[ "$_extracted_kib" -le 32768 ] || fail "Extracted ZIP exceeds 32 MiB"

PROP_FILE="$TMPDIR/root/module.prop"
[ -s "$PROP_FILE" ] || fail "module.prop must exist at ZIP root"
[ "$(wc -c <"$PROP_FILE")" -le 65536 ] || fail "module.prop exceeds 64 KiB"

MOD_ID=$(get_prop "$PROP_FILE" id)
MOD_NAME=$(get_prop "$PROP_FILE" name)
MOD_VERSION=$(get_prop "$PROP_FILE" version)
MOD_AUTHOR=$(get_prop "$PROP_FILE" author)
MOD_EVENT=$(get_prop "$PROP_FILE" event)
MOD_ARGS=$(get_prop "$PROP_FILE" args)
MOD_AUTOLOAD=$(get_prop "$PROP_FILE" autoLoad)

validate_module_id "$MOD_ID" || fail "Unsafe or missing module id"
[ -n "$MOD_NAME" ] || MOD_NAME=$MOD_ID
[ -n "$MOD_VERSION" ] || MOD_VERSION=0.0.0
case "$MOD_AUTOLOAD" in
    true|false|'') ;;
    *) fail "autoLoad must be true or false" ;;
esac
[ -n "$MOD_AUTOLOAD" ] || MOD_AUTOLOAD=false

# Metadata used in paths or command arguments receives explicit bounds.
MOD_NAME=$(printf '%s' "$MOD_NAME" | tr -d '\000-\037\177' | head -c 128)
MOD_VERSION=$(printf '%s' "$MOD_VERSION" | tr -cd 'A-Za-z0-9_.+-' | head -c 64)
MOD_AUTHOR=$(printf '%s' "$MOD_AUTHOR" | tr -d '\000-\037\177' | head -c 128)
MOD_EVENT=$(printf '%s' "$MOD_EVENT" | tr -cd 'A-Za-z0-9_,.-' | head -c 512)
MOD_ARGS=$(printf '%s' "$MOD_ARGS" | tr -d '\000-\037\177' | head -c 1024)

KO_COUNT=$(find "$TMPDIR/root" -type f \( -name '*.ko' -o -name '*.o' \) | wc -l | tr -d ' ')
[ "$KO_COUNT" = "0" ] || fail "Linux .ko/.o files are not KernelPatch KPM artifacts"
KPM_COUNT=$(find "$TMPDIR/root" -type f -name '*.kpm' | wc -l | tr -d ' ')
SRC_COUNT=$(find "$TMPDIR/root" -type f -name '*.c' | wc -l | tr -d ' ')

if [ "$KPM_COUNT" -gt 0 ] && [ "$SRC_COUNT" -gt 0 ]; then
    fail "ZIP must contain either one binary KPM or source, not both"
fi

BUILT_KPM="$TMPDIR/result.kpm"
SIGNATURE_VALID=false
SIGNATURE_FILE=""

if [ "$KPM_COUNT" = "1" ]; then
    KPM_FILE=$(find "$TMPDIR/root" -type f -name '*.kpm' | head -n 1)
    validate_kpm_binary "$KPM_FILE" || fail "KPM binary failed kptools validation"
    cp "$KPM_FILE" "$BUILT_KPM" || fail "Cannot stage KPM binary"

    _candidate_sig="${KPM_FILE}.sig"
    if [ -f "$_candidate_sig" ]; then
        SIGNATURE_FILE=$_candidate_sig
    else
        _stem=${KPM_FILE%.kpm}
        [ ! -f "${_stem}.sig" ] || SIGNATURE_FILE="${_stem}.sig"
    fi
elif [ "$KPM_COUNT" -gt 1 ]; then
    fail "ZIP contains multiple KPM binaries"
elif [ "$SRC_COUNT" -gt 0 ]; then
    COMPILE_SCRIPT="$MODDIR/compile_kpm.sh"
    [ -x "$COMPILE_SCRIPT" ] || fail "Source KPM compiler is unavailable"
    "$COMPILE_SCRIPT" "$TMPDIR/root" "$BUILT_KPM" "$MODDIR" \
        || fail "Source KPM compilation failed"
    validate_kpm_binary "$BUILT_KPM" || fail "Compiled KPM failed kptools validation"
else
    fail "ZIP contains no .kpm or KPM source"
fi

# A supplied signature must be valid. An unsigned module may be retained for
# manual review but cannot be autoloaded or loaded immediately by this script.
if [ -n "$SIGNATURE_FILE" ]; then
    . "$MODDIR/kpm_verify.sh" 2>/dev/null || fail "Cannot load signature verifier"
    verify_kpm_sig "$BUILT_KPM" "$SIGNATURE_FILE" \
        || fail "KPM signature verification failed"
    SIGNATURE_VALID=true
fi

mkdir -p "$KPM_DIR" "$KPM_ZIP_DIR" "$KPM_EVENT_DIR" "$KPM_SOURCE_DIR"
chmod 0700 "$KPM_DIR" "$KPM_ZIP_DIR" "$KPM_EVENT_DIR" "$KPM_SOURCE_DIR" 2>/dev/null || true

DEST_KPM="$KPM_DIR/${MOD_ID}.kpm"
DEST_SIG="$KPM_DIR/${MOD_ID}.kpm.sig"
DEST_ZIP="$KPM_ZIP_DIR/${MOD_ID}.zip"
DEST_PROP="$KPM_ZIP_DIR/${MOD_ID}.prop"
DEST_SHA="$KPM_ZIP_DIR/${MOD_ID}.zip.sha256"

autoload_requested=$MOD_AUTOLOAD
if [ "$SIGNATURE_VALID" != "true" ]; then
    MOD_AUTOLOAD=false
    log "Unsigned KPM stored with autoload disabled: $MOD_ID"
fi

atomic_copy "$BUILT_KPM" "$DEST_KPM" 0600 || fail "Cannot install KPM binary"
if [ "$SIGNATURE_VALID" = "true" ]; then
    atomic_copy "$SIGNATURE_FILE" "$DEST_SIG" 0600 || fail "Cannot install KPM signature"
else
    rm -f "$DEST_SIG"
fi
atomic_copy "$ZIP_FILE" "$DEST_ZIP" 0600 || fail "Cannot preserve source ZIP"
atomic_copy "$PROP_FILE" "$DEST_PROP" 0600 || fail "Cannot preserve module metadata"
sha256sum "$DEST_ZIP" >"${DEST_SHA}.incoming.$$" 2>/dev/null || fail "Cannot hash installed ZIP"
mv "${DEST_SHA}.incoming.$$" "$DEST_SHA" || fail "Cannot finalize ZIP digest"
chmod 0600 "$DEST_SHA" 2>/dev/null || true

rm -f \
    "$KPM_EVENT_DIR/${MOD_ID}.events" \
    "$KPM_EVENT_DIR/${MOD_ID}.args" \
    "$KPM_EVENT_DIR/${MOD_ID}.autoload"
if [ -n "$MOD_EVENT" ]; then
    printf '%s\n' "$MOD_EVENT" >"$KPM_EVENT_DIR/${MOD_ID}.events"
    chmod 0600 "$KPM_EVENT_DIR/${MOD_ID}.events" 2>/dev/null || true
fi
if [ -n "$MOD_ARGS" ]; then
    printf '%s\n' "$MOD_ARGS" >"$KPM_EVENT_DIR/${MOD_ID}.args"
    chmod 0600 "$KPM_EVENT_DIR/${MOD_ID}.args" 2>/dev/null || true
fi

if [ "$MOD_AUTOLOAD" = "true" ]; then
    if [ -n "$MOD_ARGS" ]; then
        kpatch kpm load "$DEST_KPM" -- "$MOD_ARGS"
    else
        kpatch kpm load "$DEST_KPM"
    fi
    if [ "$?" -eq 0 ]; then
        : >"$KPM_EVENT_DIR/${MOD_ID}.autoload"
        chmod 0600 "$KPM_EVENT_DIR/${MOD_ID}.autoload" 2>/dev/null || true
        log "Signed KPM installed and loaded: $MOD_NAME ($MOD_ID) $MOD_VERSION"
    else
        log "KPM installed but immediate load failed; autoload remains disabled: $MOD_ID"
        exit 1
    fi
else
    if [ "$autoload_requested" = "true" ] && [ "$SIGNATURE_VALID" != "true" ]; then
        log "KPM installed but not loaded because no valid signature was supplied"
    else
        log "KPM installed with autoload disabled: $MOD_NAME ($MOD_ID) $MOD_VERSION"
    fi
fi

exit 0
