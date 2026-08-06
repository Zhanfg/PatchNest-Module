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
LOG="$PNDIR/service.log"
PATH="$MODDIR/bin:$PATH"
ZIP_FILE=${1:-}
TMPDIR=""
STAGE_DIR=""
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
    [ -z "$STAGE_DIR" ] || rm -rf "$STAGE_DIR"
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup 0 1 2 15

get_prop() {
    _file=$1
    _key=$2
    grep -F "${_key}=" "$_file" 2>/dev/null | head -n 1 | cut -d= -f2-
}

validate_module_id() {
    _id=$1
    [ -n "$_id" ] && [ "${#_id}" -le 64 ] || return 1
    case "$_id" in
        .|..|*[!A-Za-z0-9_.-]*) return 1 ;;
    esac
}

validate_kpm_binary() {
    [ -s "$1" ] || return 1
    command -v kptools >/dev/null 2>&1 || return 1
    kptools -l -M "$1" >/dev/null 2>&1
}

validate_zip_source() {
    [ -n "$ZIP_FILE" ] && [ -f "$ZIP_FILE" ] || fail "Usage: install_kpm.sh <path_to_zip>"
    _resolved=$(readlink -f "$ZIP_FILE" 2>/dev/null || true)
    [ -n "$_resolved" ] && [ -f "$_resolved" ] || fail "Cannot resolve ZIP path"
    case "$_resolved" in
        "$MODDIR"/tmp/*|/data/local/tmp/*|/data/adb/patchnest/*|/storage/emulated/0/Download/*|/sdcard/Download/*)
            ZIP_FILE=$_resolved
            ;;
        *)
            fail "ZIP must be in PatchNest WebUI temp, /data/local/tmp, PatchNest state, or Download"
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
            ""|/*|../*|*/../*|*/..|*\\*|*':'*) fail "Unsafe ZIP entry: $_entry" ;;
        esac
        _clean=$(printf '%s' "$_entry" | tr -d '\000-\037\177')
        [ "$_clean" = "$_entry" ] || fail "ZIP entry contains control characters"
        [ "${#_entry}" -le 240 ] || fail "ZIP entry name is too long"
    done <"$_list"
}

stage_file() {
    _source=$1
    _name=$2
    _mode=$3
    cp "$_source" "$STAGE_DIR/$_name" || return 1
    [ -s "$STAGE_DIR/$_name" ] || return 1
    chmod "$_mode" "$STAGE_DIR/$_name" 2>/dev/null || true
}

validate_zip_source
mkdir -p "$PNDIR" || fail "Cannot create PatchNest state directory"
mkdir "$LOCK_DIR" 2>/dev/null || fail "Another KPM installation is already running"
TMPDIR=$(mktemp -d /data/local/tmp/patchnest-kpm.XXXXXX) || fail "Cannot create extraction directory"
STAGE_DIR="$PNDIR/.kpm-stage.$$"
mkdir "$STAGE_DIR" || fail "Cannot create installation stage"

preflight_zip_entries
mkdir -p "$TMPDIR/root"
unzip -o "$ZIP_FILE" -d "$TMPDIR/root" >/dev/null 2>&1 || fail "Failed to extract ZIP"
if find "$TMPDIR/root" -type l -print -quit 2>/dev/null | grep -q .; then
    fail "ZIP contains symbolic links"
fi
_extracted_kib=$(du -sk "$TMPDIR/root" 2>/dev/null | awk '{print $1}')
[ -n "$_extracted_kib" ] && [ "$_extracted_kib" -le 32768 ] || fail "Extracted ZIP exceeds 32 MiB or cannot be measured"

PROP_FILE="$TMPDIR/root/module.prop"
[ -s "$PROP_FILE" ] || fail "module.prop must exist at ZIP root"
[ "$(wc -c <"$PROP_FILE")" -le 65536 ] || fail "module.prop exceeds 64 KiB"

MOD_ID=$(get_prop "$PROP_FILE" id)
MOD_NAME=$(get_prop "$PROP_FILE" name)
MOD_VERSION=$(get_prop "$PROP_FILE" version)
MOD_EVENT=$(get_prop "$PROP_FILE" event)
MOD_ARGS=$(get_prop "$PROP_FILE" args)
MOD_AUTOLOAD=$(get_prop "$PROP_FILE" autoLoad)
validate_module_id "$MOD_ID" || fail "Unsafe or missing module id"
[ -n "$MOD_NAME" ] || MOD_NAME=$MOD_ID
[ -n "$MOD_VERSION" ] || MOD_VERSION=0.0.0
case "$MOD_AUTOLOAD" in true|false|'') ;; *) fail "autoLoad must be true or false" ;; esac
[ -n "$MOD_AUTOLOAD" ] || MOD_AUTOLOAD=false
MOD_NAME=$(printf '%s' "$MOD_NAME" | tr -d '\000-\037\177' | head -c 128)
MOD_VERSION=$(printf '%s' "$MOD_VERSION" | tr -cd 'A-Za-z0-9_.+-' | head -c 64)
MOD_EVENT=$(printf '%s' "$MOD_EVENT" | tr -cd 'A-Za-z0-9_,.-' | head -c 512)
MOD_ARGS=$(printf '%s' "$MOD_ARGS" | tr -d '\000-\037\177' | head -c 1024)

KO_COUNT=$(find "$TMPDIR/root" -type f \( -name '*.ko' -o -name '*.o' \) | wc -l | tr -d ' ')
KPM_COUNT=$(find "$TMPDIR/root" -type f -name '*.kpm' | wc -l | tr -d ' ')
SRC_COUNT=$(find "$TMPDIR/root" -type f -name '*.c' | wc -l | tr -d ' ')
[ "$KO_COUNT" = "0" ] || fail "Linux .ko/.o files are not KernelPatch KPM artifacts"
[ "$KPM_COUNT" -le 1 ] || fail "ZIP contains multiple KPM binaries"
if [ "$KPM_COUNT" -gt 0 ] && [ "$SRC_COUNT" -gt 0 ]; then
    fail "ZIP must contain either one binary KPM or source, not both"
fi

BUILT_KPM="$TMPDIR/result.kpm"
SIGNATURE_FILE=""
SIGNATURE_VALID=false
if [ "$KPM_COUNT" = "1" ]; then
    KPM_FILE=$(find "$TMPDIR/root" -type f -name '*.kpm' | head -n 1)
    validate_kpm_binary "$KPM_FILE" || fail "KPM binary failed kptools validation"
    cp "$KPM_FILE" "$BUILT_KPM" || fail "Cannot stage KPM binary"
    if [ -f "${KPM_FILE}.sig" ]; then
        SIGNATURE_FILE="${KPM_FILE}.sig"
    elif [ -f "${KPM_FILE%.kpm}.sig" ]; then
        SIGNATURE_FILE="${KPM_FILE%.kpm}.sig"
    fi
elif [ "$SRC_COUNT" -gt 0 ]; then
    [ -x "$MODDIR/compile_kpm.sh" ] || fail "Source KPM compiler is unavailable"
    "$MODDIR/compile_kpm.sh" "$TMPDIR/root" "$BUILT_KPM" "$MODDIR" || fail "Source KPM compilation failed"
    validate_kpm_binary "$BUILT_KPM" || fail "Compiled KPM failed kptools validation"
else
    fail "ZIP contains no .kpm or KPM source"
fi

if [ -n "$SIGNATURE_FILE" ]; then
    . "$MODDIR/kpm_verify.sh" 2>/dev/null || fail "Cannot load signature verifier"
    verify_kpm_sig "$BUILT_KPM" "$SIGNATURE_FILE" || fail "KPM signature verification failed"
    SIGNATURE_VALID=true
fi

autoload_requested=$MOD_AUTOLOAD
if [ "$SIGNATURE_VALID" != "true" ]; then
    MOD_AUTOLOAD=false
    log "Unsigned KPM prepared with autoload disabled: $MOD_ID"
fi

stage_file "$BUILT_KPM" module.kpm 0600 || fail "Cannot stage KPM binary"
stage_file "$ZIP_FILE" source.zip 0600 || fail "Cannot stage source ZIP"
stage_file "$PROP_FILE" module.prop 0600 || fail "Cannot stage module metadata"
if [ "$SIGNATURE_VALID" = "true" ]; then
    stage_file "$SIGNATURE_FILE" module.kpm.sig 0600 || fail "Cannot stage KPM signature"
fi
sha256sum "$STAGE_DIR/source.zip" >"$STAGE_DIR/source.zip.sha256" 2>/dev/null || fail "Cannot hash staged ZIP"
chmod 0600 "$STAGE_DIR/source.zip.sha256" 2>/dev/null || true
if [ -n "$MOD_EVENT" ]; then printf '%s\n' "$MOD_EVENT" >"$STAGE_DIR/events"; chmod 0600 "$STAGE_DIR/events" 2>/dev/null || true; fi
if [ -n "$MOD_ARGS" ]; then printf '%s\n' "$MOD_ARGS" >"$STAGE_DIR/args"; chmod 0600 "$STAGE_DIR/args" 2>/dev/null || true; fi

mkdir -p "$KPM_DIR" "$KPM_ZIP_DIR" "$KPM_EVENT_DIR" || fail "Cannot create KPM directories"
chmod 0700 "$KPM_DIR" "$KPM_ZIP_DIR" "$KPM_EVENT_DIR" 2>/dev/null || true
DEST_KPM="$KPM_DIR/${MOD_ID}.kpm"
DEST_SIG="$KPM_DIR/${MOD_ID}.kpm.sig"
rm -f "$KPM_EVENT_DIR/${MOD_ID}.autoload"

# Commit metadata first and binary last. All sources were fully prepared under
# the same /data filesystem, so these renames do not depend on network or ZIP IO.
mv "$STAGE_DIR/source.zip" "$KPM_ZIP_DIR/${MOD_ID}.zip" || fail "Cannot install source ZIP"
mv "$STAGE_DIR/source.zip.sha256" "$KPM_ZIP_DIR/${MOD_ID}.zip.sha256" || fail "Cannot install ZIP digest"
mv "$STAGE_DIR/module.prop" "$KPM_ZIP_DIR/${MOD_ID}.prop" || fail "Cannot install metadata"
if [ -f "$STAGE_DIR/events" ]; then mv "$STAGE_DIR/events" "$KPM_EVENT_DIR/${MOD_ID}.events" || fail "Cannot install event config"; else rm -f "$KPM_EVENT_DIR/${MOD_ID}.events"; fi
if [ -f "$STAGE_DIR/args" ]; then mv "$STAGE_DIR/args" "$KPM_EVENT_DIR/${MOD_ID}.args" || fail "Cannot install argument config"; else rm -f "$KPM_EVENT_DIR/${MOD_ID}.args"; fi
if [ "$SIGNATURE_VALID" = "true" ]; then mv "$STAGE_DIR/module.kpm.sig" "$DEST_SIG" || fail "Cannot install signature"; else rm -f "$DEST_SIG"; fi
mv "$STAGE_DIR/module.kpm" "$DEST_KPM" || fail "Cannot install KPM binary"

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
elif [ "$autoload_requested" = "true" ] && [ "$SIGNATURE_VALID" != "true" ]; then
    log "KPM installed but not loaded because no valid signature was supplied"
else
    log "KPM installed with autoload disabled: $MOD_NAME ($MOD_ID) $MOD_VERSION"
fi

exit 0
