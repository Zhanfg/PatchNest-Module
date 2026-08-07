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
PATH="$MODDIR/bin:${PATH:-}"
ZIP_FILE=${1:-}
TMPDIR=""
STAGE_DIR=""
PREVIOUS_DIR=""
MAX_ZIP_BYTES=$((64 * 1024 * 1024))
MAX_EXTRACTED_BYTES=$((32 * 1024 * 1024))
COMMIT_STARTED=false
COMMIT_WRITING=false
COMMIT_COMPLETE=false
HAD_EXISTING=false
DEST_KPM=""
DEST_SIG=""
DEST_ZIP=""
DEST_ZIP_DIGEST=""
DEST_PROP=""
DEST_EVENTS=""
DEST_ARGS=""
DEST_AUTOLOAD=""

# shellcheck disable=SC1091
. "$MODDIR/kpm_install_recovery.sh" 2>/dev/null || {
    echo "! Cannot load durable KPM install recovery helper" >&2
    exit 1
}

log() {
    mkdir -p "$PNDIR" 2>/dev/null || true
    printf '[%s] install_kpm: %s\n' "$(date)" "$1" >>"$LOG" 2>/dev/null || true
    printf '%s\n' "- $1"
}

fail() {
    printf '%s\n' "! $*" >&2
    exit 1
}

restore_previous_file() {
    _previous=$1
    _destination=$2
    [ -e "$_previous" ] || return 0
    rm -f "$_destination" 2>/dev/null || true
    mv "$_previous" "$_destination" 2>/dev/null || return 1
}

rollback_install() {
    [ "$COMMIT_STARTED" = "true" ] || return 0
    [ "$COMMIT_COMPLETE" = "false" ] || return 0
    [ -n "$PREVIOUS_DIR" ] && [ -d "$PREVIOUS_DIR" ] || return 0

    if [ "$COMMIT_WRITING" = "true" ]; then
        rm -f \
            "$DEST_KPM" "$DEST_SIG" "$DEST_ZIP" "$DEST_ZIP_DIGEST" \
            "$DEST_PROP" "$DEST_EVENTS" "$DEST_ARGS" "$DEST_AUTOLOAD" \
            2>/dev/null || true
    fi

    _rollback_failed=false
    restore_previous_file "$PREVIOUS_DIR/kpm" "$DEST_KPM" || _rollback_failed=true
    restore_previous_file "$PREVIOUS_DIR/sig" "$DEST_SIG" || _rollback_failed=true
    restore_previous_file "$PREVIOUS_DIR/zip" "$DEST_ZIP" || _rollback_failed=true
    restore_previous_file "$PREVIOUS_DIR/zip-digest" "$DEST_ZIP_DIGEST" || _rollback_failed=true
    restore_previous_file "$PREVIOUS_DIR/prop" "$DEST_PROP" || _rollback_failed=true
    restore_previous_file "$PREVIOUS_DIR/events" "$DEST_EVENTS" || _rollback_failed=true
    restore_previous_file "$PREVIOUS_DIR/args" "$DEST_ARGS" || _rollback_failed=true
    restore_previous_file "$PREVIOUS_DIR/autoload" "$DEST_AUTOLOAD" || _rollback_failed=true
    if [ "$_rollback_failed" = "true" ]; then
        printf '%s\n' "! KPM install rollback was incomplete; inspect $PREVIOUS_DIR" >&2
        return 1
    fi
    log "Persistent KPM state rolled back after failed install"
    return 0
}

cleanup() {
    rollback_install || true
    [ -z "$TMPDIR" ] || rm -rf "$TMPDIR"
    [ -z "$STAGE_DIR" ] || rm -rf "$STAGE_DIR"
    patchnest_release_install_lock 2>/dev/null || true
}
trap cleanup 0 1 2 15

get_unique_prop() {
    _file=$1
    _key=$2
    _count=$(grep -c "^${_key}=" "$_file" 2>/dev/null || true)
    case "$_count" in
        0) return 1 ;;
        1) sed -n "s/^${_key}=//p" "$_file" | head -n 1; return 0 ;;
        *) return 2 ;;
    esac
}

read_optional_prop() {
    _file=$1
    _key=$2
    _value=$(get_unique_prop "$_file" "$_key")
    _rc=$?
    case "$_rc" in
        0) printf '%s' "$_value" ;;
        1) printf '' ;;
        2) fail "module.prop contains duplicate key: $_key" ;;
        *) fail "Cannot read module.prop key: $_key" ;;
    esac
}

validate_module_id() {
    _id=$1
    [ -n "$_id" ] && [ "${#_id}" -le 64 ] || return 1
    case "$_id" in .|..|*[!A-Za-z0-9_.-]*) return 1 ;; esac
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
        *) fail "ZIP must be in PatchNest WebUI temp, /data/local/tmp, PatchNest state, or Download" ;;
    esac
    [ -s "$ZIP_FILE" ] || fail "ZIP is empty"
    _zip_size=$(wc -c <"$ZIP_FILE" 2>/dev/null || true)
    case "$_zip_size" in ''|*[!0-9]*) fail "Cannot measure ZIP size" ;; esac
    [ "$_zip_size" -le "$MAX_ZIP_BYTES" ] || fail "ZIP exceeds 64 MiB"
}

preflight_zip_entries() {
    command -v unzip >/dev/null 2>&1 || fail "unzip is unavailable"
    _list="$TMPDIR/entries.txt"
    unzip -Z1 "$ZIP_FILE" >"$_list" 2>/dev/null || fail "Cannot list ZIP entries"
    [ -s "$_list" ] || fail "ZIP has no entries"

    _duplicate=$(LC_ALL=C sort "$_list" | uniq -d | head -n 1)
    [ -z "$_duplicate" ] || fail "ZIP contains duplicate entry: $_duplicate"

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

    _declared_total=$(unzip -l "$ZIP_FILE" 2>/dev/null | awk '
        $1 ~ /^[0-9]+$/ && NF >= 4 { total += $1 }
        END { printf "%.0f", total }
    ')
    case "$_declared_total" in ''|*[!0-9]*) fail "Cannot measure declared ZIP extraction size" ;; esac
    [ "$_declared_total" -le "$MAX_EXTRACTED_BYTES" ] || fail "Declared ZIP extraction exceeds 32 MiB"
}

stage_file() {
    _source=$1
    _name=$2
    _mode=$3
    cp "$_source" "$STAGE_DIR/$_name" || return 1
    [ -s "$STAGE_DIR/$_name" ] || return 1
    chmod "$_mode" "$STAGE_DIR/$_name" 2>/dev/null || true
}

move_existing_to_previous() {
    _source=$1
    _name=$2
    [ -e "$_source" ] || return 0
    [ -f "$_source" ] && [ ! -L "$_source" ] || fail "Existing KPM state is not a regular file: $_source"
    mv "$_source" "$PREVIOUS_DIR/$_name" || fail "Cannot preserve existing KPM state: $_source"
    HAD_EXISTING=true
}

validate_zip_source
mkdir -p "$PNDIR" || fail "Cannot create PatchNest state directory"
patchnest_acquire_install_lock
_lock_rc=$?
case "$_lock_rc" in
    0) ;;
    2) fail "Another KPM installation is already running" ;;
    *) fail "Cannot recover stale KPM installation state" ;;
esac

TMPDIR=$(mktemp -d /data/local/tmp/patchnest-kpm.XXXXXX) || fail "Cannot create extraction directory"
preflight_zip_entries
mkdir -p "$TMPDIR/root"
unzip -o "$ZIP_FILE" -d "$TMPDIR/root" >/dev/null 2>&1 || fail "Failed to extract ZIP"
if find "$TMPDIR/root" -type l -print -quit 2>/dev/null | grep -q .; then
    fail "ZIP contains symbolic links"
fi
_extracted_kib=$(du -sk "$TMPDIR/root" 2>/dev/null | awk '{print $1}')
[ -n "$_extracted_kib" ] && [ "$((_extracted_kib * 1024))" -le "$MAX_EXTRACTED_BYTES" ] \
    || fail "Extracted ZIP exceeds 32 MiB or cannot be measured"

PROP_FILE="$TMPDIR/root/module.prop"
[ -s "$PROP_FILE" ] || fail "module.prop must exist at ZIP root"
[ "$(wc -c <"$PROP_FILE")" -le 65536 ] || fail "module.prop exceeds 64 KiB"

MOD_ID=$(get_unique_prop "$PROP_FILE" id)
_id_rc=$?
case "$_id_rc" in
    0) ;;
    1) fail "module.prop is missing required key: id" ;;
    2) fail "module.prop contains duplicate key: id" ;;
    *) fail "Cannot read module.prop id" ;;
esac
MOD_NAME=$(read_optional_prop "$PROP_FILE" name)
MOD_VERSION=$(read_optional_prop "$PROP_FILE" version)
MOD_EVENT=$(read_optional_prop "$PROP_FILE" event)
MOD_ARGS=$(read_optional_prop "$PROP_FILE" args)
MOD_AUTOLOAD=$(read_optional_prop "$PROP_FILE" autoLoad)
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
[ "$SRC_COUNT" = "0" ] || fail "On-device KPM source compilation is disabled; provide one prebuilt .kpm"
[ "$KPM_COUNT" = "1" ] || fail "ZIP must contain exactly one prebuilt KPM binary"

BUILT_KPM="$TMPDIR/result.kpm"
SIGNATURE_FILE=""
SIGNATURE_VALID=false
KPM_FILE=$(find "$TMPDIR/root" -type f -name '*.kpm' | head -n 1)
validate_kpm_binary "$KPM_FILE" || fail "KPM binary failed kptools validation"
cp "$KPM_FILE" "$BUILT_KPM" || fail "Cannot stage KPM binary"
if [ -f "${KPM_FILE}.sig" ]; then
    SIGNATURE_FILE="${KPM_FILE}.sig"
elif [ -f "${KPM_FILE%.kpm}.sig" ]; then
    SIGNATURE_FILE="${KPM_FILE%.kpm}.sig"
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

STAGE_DIR="$PNDIR/.kpm-stage.$$"
PREVIOUS_DIR="$STAGE_DIR/previous"
mkdir "$STAGE_DIR" "$PREVIOUS_DIR" || fail "Cannot create installation stage"
chmod 0700 "$STAGE_DIR" "$PREVIOUS_DIR" 2>/dev/null || true
patchnest_write_install_journal "$STAGE_DIR" preparing "$MOD_ID" \
    || fail "Cannot initialize durable KPM install journal"

ZIP_NAME="${MOD_ID}.zip"
ZIP_DIGEST_NAME="${MOD_ID}.zip.sha256"
stage_file "$BUILT_KPM" module.kpm 0600 || fail "Cannot stage KPM binary"
stage_file "$ZIP_FILE" "$ZIP_NAME" 0600 || fail "Cannot stage source ZIP"
stage_file "$PROP_FILE" module.prop 0600 || fail "Cannot stage module metadata"
if [ "$SIGNATURE_VALID" = "true" ]; then
    stage_file "$SIGNATURE_FILE" module.kpm.sig 0600 || fail "Cannot stage KPM signature"
fi
(
    cd "$STAGE_DIR" || exit 1
    sha256sum "$ZIP_NAME" >"$ZIP_DIGEST_NAME"
) || fail "Cannot hash staged ZIP"
chmod 0600 "$STAGE_DIR/$ZIP_DIGEST_NAME" 2>/dev/null || true
if [ -n "$MOD_EVENT" ]; then printf '%s\n' "$MOD_EVENT" >"$STAGE_DIR/events"; chmod 0600 "$STAGE_DIR/events" 2>/dev/null || true; fi
if [ -n "$MOD_ARGS" ]; then printf '%s\n' "$MOD_ARGS" >"$STAGE_DIR/args"; chmod 0600 "$STAGE_DIR/args" 2>/dev/null || true; fi

mkdir -p "$KPM_DIR" "$KPM_ZIP_DIR" "$KPM_EVENT_DIR" || fail "Cannot create KPM directories"
chmod 0700 "$KPM_DIR" "$KPM_ZIP_DIR" "$KPM_EVENT_DIR" 2>/dev/null || true
DEST_KPM="$KPM_DIR/${MOD_ID}.kpm"
DEST_SIG="$KPM_DIR/${MOD_ID}.kpm.sig"
DEST_ZIP="$KPM_ZIP_DIR/$ZIP_NAME"
DEST_ZIP_DIGEST="$KPM_ZIP_DIR/$ZIP_DIGEST_NAME"
DEST_PROP="$KPM_ZIP_DIR/${MOD_ID}.prop"
DEST_EVENTS="$KPM_EVENT_DIR/${MOD_ID}.events"
DEST_ARGS="$KPM_EVENT_DIR/${MOD_ID}.args"
DEST_AUTOLOAD="$KPM_EVENT_DIR/${MOD_ID}.autoload"

COMMIT_STARTED=true
patchnest_write_install_journal "$STAGE_DIR" backup "$MOD_ID" \
    || fail "Cannot enter durable KPM backup phase"
move_existing_to_previous "$DEST_KPM" kpm
move_existing_to_previous "$DEST_SIG" sig
move_existing_to_previous "$DEST_ZIP" zip
move_existing_to_previous "$DEST_ZIP_DIGEST" zip-digest
move_existing_to_previous "$DEST_PROP" prop
move_existing_to_previous "$DEST_EVENTS" events
move_existing_to_previous "$DEST_ARGS" args
move_existing_to_previous "$DEST_AUTOLOAD" autoload
patchnest_write_install_journal "$STAGE_DIR" writing "$MOD_ID" \
    || fail "Cannot enter durable KPM write phase"
COMMIT_WRITING=true

mv "$STAGE_DIR/$ZIP_NAME" "$DEST_ZIP" || fail "Cannot install source ZIP"
mv "$STAGE_DIR/$ZIP_DIGEST_NAME" "$DEST_ZIP_DIGEST" || fail "Cannot install ZIP digest"
(
    cd "$KPM_ZIP_DIR" || exit 1
    sha256sum -c "$ZIP_DIGEST_NAME" >/dev/null 2>&1
) || fail "Installed ZIP does not match its retained digest"
mv "$STAGE_DIR/module.prop" "$DEST_PROP" || fail "Cannot install metadata"
if [ -f "$STAGE_DIR/events" ]; then mv "$STAGE_DIR/events" "$DEST_EVENTS" || fail "Cannot install event config"; fi
if [ -f "$STAGE_DIR/args" ]; then mv "$STAGE_DIR/args" "$DEST_ARGS" || fail "Cannot install argument config"; fi
if [ "$SIGNATURE_VALID" = "true" ]; then mv "$STAGE_DIR/module.kpm.sig" "$DEST_SIG" || fail "Cannot install signature"; fi
mv "$STAGE_DIR/module.kpm" "$DEST_KPM" || fail "Cannot install KPM binary"

if [ "$MOD_AUTOLOAD" = "true" ]; then
    if [ "$HAD_EXISTING" = "true" ]; then
        : >"$DEST_AUTOLOAD" || fail "Cannot create update autoload marker"
        chmod 0600 "$DEST_AUTOLOAD" 2>/dev/null || true
        log "Signed KPM update installed; reboot required before loading: $MOD_ID"
    else
        if [ -n "$MOD_ARGS" ]; then
            kpatch kpm load "$DEST_KPM" -- "$MOD_ARGS"
        else
            kpatch kpm load "$DEST_KPM"
        fi
        if [ "$?" -eq 0 ]; then
            : >"$DEST_AUTOLOAD" || fail "Cannot create autoload marker"
            chmod 0600 "$DEST_AUTOLOAD" 2>/dev/null || true
            log "Signed KPM installed and loaded: $MOD_NAME ($MOD_ID) $MOD_VERSION"
        else
            fail "KPM immediate load failed; persistent state will be rolled back"
        fi
    fi
elif [ "$autoload_requested" = "true" ] && [ "$SIGNATURE_VALID" != "true" ]; then
    log "KPM installed but not loaded because no valid signature was supplied"
else
    log "KPM installed with autoload disabled: $MOD_NAME ($MOD_ID) $MOD_VERSION"
fi

patchnest_write_install_journal "$STAGE_DIR" complete "$MOD_ID" \
    || fail "Cannot finalize durable KPM install journal"
COMMIT_COMPLETE=true
exit 0
