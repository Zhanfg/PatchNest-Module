#!/system/bin/sh
# PatchNest KPM ZIP installer
# Usage: install_kpm.sh <path_to_zip>

set -u

MODDIR=${0%/*}
PNDIR="/data/adb/patchnest"
KPM_DIR="$PNDIR/kpm"
KPM_ZIP_DIR="$PNDIR/kpm_zips"
KPM_EVENT_DIR="$PNDIR/kpm_events"
LOG="$PNDIR/service.log"
PATH="$MODDIR/bin:$PATH"
ZIP_FILE=${1:-}

log() {
    printf '[%s] install_kpm: %s\n' "$(date)" "$1" >> "$LOG" 2>/dev/null || true
    printf '%s\n' "- $1"
}

fail() {
    printf '%s\n' "! $1" >&2
    log "ERROR: $1"
    exit "${2:-1}"
}

get_prop() {
    _pn_file=$1
    _pn_key=$2
    grep "^${_pn_key}=" "$_pn_file" 2>/dev/null | head -1 | cut -d'=' -f2-
}

ensure_real_dir() {
    _pn_dir=$1
    [ ! -L "$_pn_dir" ] || return 1
    mkdir -p "$_pn_dir" || return 1
    [ -d "$_pn_dir" ] && [ ! -L "$_pn_dir" ]
}

validate_archive_entries() {
    _pn_zip=$1
    _pn_list=$2
    unzip -Z1 "$_pn_zip" > "$_pn_list" 2>/dev/null || return 1
    [ -s "$_pn_list" ] || return 1
    while IFS= read -r _pn_entry || [ -n "$_pn_entry" ]; do
        [ -n "$_pn_entry" ] || return 1
        case "$_pn_entry" in
            /*|\\*|[A-Za-z]:*|../*|*/../*|*/..|..|./*|*\\*)
                printf '%s\n' "! Unsafe ZIP entry: $_pn_entry" >&2
                return 1
                ;;
        esac
    done < "$_pn_list"
    return 0
}

validate_kpm_binary() {
    _pn_file=$1
    [ -f "$_pn_file" ] && [ ! -L "$_pn_file" ] && [ -s "$_pn_file" ] || return 1
    command -v xxd >/dev/null 2>&1 || return 1
    [ -x "$MODDIR/bin/kptools" ] || return 1

    _pn_hdr=$(xxd -p -l 20 "$_pn_file" 2>/dev/null | tr -d '\r\n')
    # ELF64, little-endian, AArch64 (e_machine=0x00b7 at offset 18).
    [ "$(printf '%s' "$_pn_hdr" | cut -c1-12)" = "7f454c460201" ] || return 1
    [ "$(printf '%s' "$_pn_hdr" | cut -c37-40)" = "b700" ] || return 1

    _pn_meta=$(PATH="$MODDIR/bin:$PATH" kptools -l -M "$_pn_file" 2>/dev/null) || return 1
    _pn_name=$(printf '%s\n' "$_pn_meta" | sed -n 's/^name=//p' | head -n 1)
    [ -n "$_pn_name" ] || return 1
    return 0
}

[ -n "$ZIP_FILE" ] || fail "Usage: install_kpm.sh <path_to_zip>" 2
[ -f "$ZIP_FILE" ] && [ ! -L "$ZIP_FILE" ] || fail "KPM ZIP is missing, not regular, or is a symlink: $ZIP_FILE" 2

# FR-014 must remain a clean boot lifecycle test. Diagnostic KPM testing uses
# device_validation.sh kpm-cycle with its own explicit unlock instead of the
# normal persistent installer/autoload path.
if [ -f "$MODDIR/FR014_DEVICE_CANDIDATE" ]; then
    fail "Persistent KPM installation is disabled on the FR-014 device candidate" 3
fi

ensure_real_dir "$PNDIR" || fail "Unsafe PatchNest state directory: $PNDIR"
chmod 0700 "$PNDIR" 2>/dev/null || true
for _pn_dir in "$KPM_DIR" "$KPM_ZIP_DIR" "$KPM_EVENT_DIR"; do
    ensure_real_dir "$_pn_dir" || fail "Unsafe KPM state directory: $_pn_dir"
done

TMPDIR=$(mktemp -d /data/local/tmp/kpm_install.XXXXXX) || fail "Cannot create private KPM workspace"
cleanup() { [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"; }
trap cleanup EXIT HUP INT TERM
chmod 0700 "$TMPDIR" 2>/dev/null || true
ENTRY_LIST="$TMPDIR/archive.entries"

validate_archive_entries "$ZIP_FILE" "$ENTRY_LIST" || fail "KPM ZIP contains unsafe/invalid archive entries"

printf '%s\n' "- Extracting $ZIP_FILE..."
unzip -qq -o "$ZIP_FILE" -d "$TMPDIR/extracted" || fail "Failed to extract KPM ZIP"
EXTRACTED="$TMPDIR/extracted"
[ -d "$EXTRACTED" ] || fail "KPM extraction produced no directory"
if find "$EXTRACTED" -type l -print -quit 2>/dev/null | grep -q .; then
    fail "KPM ZIP contains symlink entries"
fi

PROP="$EXTRACTED/module.prop"
[ -f "$PROP" ] && [ ! -L "$PROP" ] || fail "KPM ZIP has no safe root module.prop"

MOD_ID=$(get_prop "$PROP" id)
MOD_NAME=$(get_prop "$PROP" name)
MOD_VERSION=$(get_prop "$PROP" version)
MOD_AUTHOR=$(get_prop "$PROP" author)
MOD_EVENT=$(get_prop "$PROP" event)
MOD_ARGS=$(get_prop "$PROP" args)
MOD_AUTOLOAD=$(get_prop "$PROP" autoLoad)

MOD_ID=${MOD_ID:-unknown}
if [ "$MOD_ID" = unknown ]; then
    MOD_ID=$(basename "$ZIP_FILE" .zip | tr ' ' '_')
fi
MOD_ID=$(printf '%s' "$MOD_ID" | tr -cd 'A-Za-z0-9_.-')
MOD_NAME=$(printf '%s' "${MOD_NAME:-$MOD_ID}" | tr -cd 'A-Za-z0-9 _.-')
MOD_VERSION=$(printf '%s' "${MOD_VERSION:-0.0.0}" | tr -cd 'A-Za-z0-9_.+-')
MOD_AUTHOR=$(printf '%s' "${MOD_AUTHOR:-}" | tr -cd 'A-Za-z0-9_@. -')
MOD_EVENT=$(printf '%s' "${MOD_EVENT:-}" | tr -cd 'A-Za-z0-9_,-')
MOD_ARGS=$(printf '%s' "${MOD_ARGS:-}" | tr -cd 'A-Za-z0-9_=,.+:/@% -')
case "${MOD_AUTOLOAD:-true}" in
    true) MOD_AUTOLOAD=true ;;
    false) MOD_AUTOLOAD=false ;;
    *) fail "Invalid autoLoad value; expected true or false" 2 ;;
esac

[ -n "$MOD_ID" ] && [ "${#MOD_ID}" -le 64 ] && [ "$MOD_ID" != . ] && [ "$MOD_ID" != .. ] \
    || fail "Unsafe or empty KPM id: '$MOD_ID'" 2

# Exactly one binary module OR one-or-more C sources. Mixed packages and
# multi-binary ambiguity are rejected rather than choosing an arbitrary file.
BINARY_LIST="$TMPDIR/binaries.list"
SOURCE_LIST="$TMPDIR/sources.list"
find "$EXTRACTED" -type f \( -name '*.kpm' -o -name '*.ko' -o -name '*.o' \) \
    ! -name '._*' ! -name '.DS_Store' -print > "$BINARY_LIST"
find "$EXTRACTED" -type f -name '*.c' ! -name '._*' ! -name '.DS_Store' -print > "$SOURCE_LIST"
BINARY_COUNT=$(awk 'END{print NR+0}' "$BINARY_LIST")
SOURCE_COUNT=$(awk 'END{print NR+0}' "$SOURCE_LIST")

if [ "$BINARY_COUNT" -gt 0 ] && [ "$SOURCE_COUNT" -gt 0 ]; then
    fail "KPM ZIP mixes binary and source modules; package is ambiguous"
fi
if [ "$BINARY_COUNT" -gt 1 ]; then
    fail "KPM ZIP contains multiple binary module candidates"
fi
if [ "$BINARY_COUNT" -eq 0 ] && [ "$SOURCE_COUNT" -eq 0 ]; then
    fail "No .kpm/.ko/.o or .c module files found"
fi

STAGED_KPM="$TMPDIR/${MOD_ID}.kpm"
if [ "$BINARY_COUNT" -eq 1 ]; then
    KPM_FILE=$(sed -n '1p' "$BINARY_LIST")
    validate_kpm_binary "$KPM_FILE" || fail "Binary module is not a valid AArch64 KPM"
    cp "$KPM_FILE" "$STAGED_KPM" || fail "Cannot stage validated KPM"
else
    COMPILE_SCRIPT="$MODDIR/compile_kpm.sh"
    [ -x "$COMPILE_SCRIPT" ] || fail "Source KPM requires an available compiler helper"
    "$COMPILE_SCRIPT" "$EXTRACTED" "$STAGED_KPM" "$MODDIR" || fail "KPM source compilation failed"
    validate_kpm_binary "$STAGED_KPM" || fail "Compiled module failed AArch64/KPM validation"
fi
chmod 0600 "$STAGED_KPM" 2>/dev/null || true

log "Installing validated KPM: $MOD_NAME ($MOD_ID) v$MOD_VERSION"
DEST_KPM="$KPM_DIR/${MOD_ID}.kpm"
DEST_TMP="$KPM_DIR/.${MOD_ID}.kpm.tmp.$$"
cp "$STAGED_KPM" "$DEST_TMP" || fail "Cannot stage KPM in persistent directory"
chmod 0600 "$DEST_TMP" 2>/dev/null || true
mv -f "$DEST_TMP" "$DEST_KPM" || fail "Cannot atomically commit KPM"

# Never retain a signature from an older binary revision.
rm -f "$KPM_DIR/${MOD_ID}.kpm.sig"
KPM_BASENAME=$(basename "$(sed -n '1p' "$BINARY_LIST" 2>/dev/null || true)")
if [ -n "$KPM_BASENAME" ]; then
    _kpm_stem=$(printf '%s' "$KPM_BASENAME" | sed -E 's/\.(kpm|ko|o)$//')
    for _sig in "$EXTRACTED/${_kpm_stem}.kpm.sig" \
                "$EXTRACTED/${_kpm_stem}.sig" \
                "$EXTRACTED/$(basename "$KPM_BASENAME" .kpm).kpm.sig" \
                "$EXTRACTED/$(basename "$KPM_BASENAME" .kpm).sig"; do
        if [ -f "$_sig" ] && [ ! -L "$_sig" ]; then
            cp "$_sig" "$KPM_DIR/${MOD_ID}.kpm.sig" || fail "Cannot install KPM signature"
            chmod 0600 "$KPM_DIR/${MOD_ID}.kpm.sig" 2>/dev/null || true
            break
        fi
    done
fi

ZIP_TMP="$KPM_ZIP_DIR/.${MOD_ID}.zip.tmp.$$"
cp "$ZIP_FILE" "$ZIP_TMP" || fail "Cannot stage original KPM ZIP"
chmod 0600 "$ZIP_TMP" 2>/dev/null || true
mv -f "$ZIP_TMP" "$KPM_ZIP_DIR/${MOD_ID}.zip" || fail "Cannot commit original KPM ZIP"
cp "$PROP" "$KPM_ZIP_DIR/${MOD_ID}.prop" || fail "Cannot install KPM metadata"
chmod 0600 "$KPM_ZIP_DIR/${MOD_ID}.prop" 2>/dev/null || true

if [ -n "$MOD_EVENT" ]; then
    printf '%s\n' "$MOD_EVENT" > "$KPM_EVENT_DIR/${MOD_ID}.events" || fail "Cannot write KPM event metadata"
else
    rm -f "$KPM_EVENT_DIR/${MOD_ID}.events"
fi
if [ -n "$MOD_ARGS" ]; then
    printf '%s\n' "$MOD_ARGS" > "$KPM_EVENT_DIR/${MOD_ID}.args" || fail "Cannot write KPM args"
else
    rm -f "$KPM_EVENT_DIR/${MOD_ID}.args"
fi

if [ "$MOD_AUTOLOAD" = true ]; then
    touch "$KPM_EVENT_DIR/${MOD_ID}.autoload" || fail "Cannot enable KPM autoload"
else
    rm -f "$KPM_EVENT_DIR/${MOD_ID}.autoload"
fi
chmod 0600 "$KPM_EVENT_DIR/${MOD_ID}."* 2>/dev/null || true

if [ "$MOD_AUTOLOAD" = true ]; then
    printf '%s\n' "- Loading module..."
    if [ -n "$MOD_ARGS" ]; then
        kpatch kpm load "$DEST_KPM" "$MOD_ARGS" 2>&1
    else
        kpatch kpm load "$DEST_KPM" 2>&1
    fi
    if [ $? -eq 0 ]; then
        log "Module $MOD_ID loaded successfully"
        printf '%s\n' "- Successfully installed and loaded: $MOD_NAME v$MOD_VERSION"
    else
        log "Module $MOD_ID load failed; persistent autoload remains enabled for next healthy boot"
        printf '%s\n' "- Installed but load failed; will retry on next healthy boot: $MOD_NAME v$MOD_VERSION"
    fi
else
    log "Module $MOD_ID installed with autoload disabled"
    printf '%s\n' "- Installed with auto-load disabled: $MOD_NAME v$MOD_VERSION"
fi

exit 0
