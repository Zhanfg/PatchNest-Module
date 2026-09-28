#!/system/bin/sh
# PatchNest Public1158 superkey lifecycle.
# This file never prints the key value.

PATCHNEST_SUPERKEY_FILE="${PATCHNEST_SUPERKEY_FILE:-/data/adb/patchnest/superkey}"
PATCHNEST_SUPERKEY_PENDING_FILE="${PATCHNEST_SUPERKEY_PENDING_FILE:-/data/adb/patchnest/superkey.pending}"
PATCHNEST_EXPORT_KEY_DIR="${PATCHNEST_EXPORT_KEY_DIR:-/data/adb/patchnest/export_keys}"
PATCHNEST_SUPERKEY=''
PATCHNEST_SUPERKEY_IS_NEW=0
PATCHNEST_SUPERKEY_CANDIDATE=''

patchnest_validate_superkey() {
    _pn_key=$1
    _pn_len=${#_pn_key}
    [ "$_pn_len" -ge 32 ] || return 1
    [ "$_pn_len" -le 63 ] || return 1
    printf '%s' "$_pn_key" | grep -Eq '^[0-9a-fA-F]+$'
}

patchnest_expected_key_owner() {
    if [ "${PATCHNEST_TRANSACTION_TEST:-0}" = "1" ]; then
        id -u
    else
        printf '%s\n' 0
    fi
}

patchnest_key_file_is_secure() {
    _pn_key_file=$1
    [ -f "$_pn_key_file" ] || return 1
    [ ! -L "$_pn_key_file" ] || return 1
    _pn_mode=$(stat -c '%a' "$_pn_key_file" 2>/dev/null) || return 1
    _pn_owner=$(stat -c '%u' "$_pn_key_file" 2>/dev/null) || return 1
    _pn_expected_owner=$(patchnest_expected_key_owner) || return 1
    [ "$_pn_mode" = "600" ] || return 1
    [ "$_pn_owner" = "$_pn_expected_owner" ] || return 1
}

patchnest_read_key_file() {
    _pn_key_file=$1
    patchnest_key_file_is_secure "$_pn_key_file" || return 1
    _pn_read=$(head -n 1 "$_pn_key_file" 2>/dev/null | tr -d '\r\n')
    patchnest_validate_superkey "$_pn_read" || return 1
    printf '%s\n' "$_pn_read"
}

patchnest_write_pending_key() {
    _pn_value=$1
    patchnest_validate_superkey "$_pn_value" || return 1
    [ ! -e "$PATCHNEST_SUPERKEY_FILE" ] || return 1
    _pn_dir=${PATCHNEST_SUPERKEY_PENDING_FILE%/*}
    mkdir -p "$_pn_dir" || return 1
    umask 077
    _pn_tmp="${PATCHNEST_SUPERKEY_PENDING_FILE}.tmp.$$"
    printf '%s\n' "$_pn_value" > "$_pn_tmp" || return 1
    chmod 0600 "$_pn_tmp" || { rm -f "$_pn_tmp"; return 1; }
    mv -f "$_pn_tmp" "$PATCHNEST_SUPERKEY_PENDING_FILE" || { rm -f "$_pn_tmp"; return 1; }
    _pn_check=$(patchnest_read_key_file "$PATCHNEST_SUPERKEY_PENDING_FILE") || return 1
    [ "$_pn_check" = "$_pn_value" ]
}

patchnest_prepare_superkey() {
    _pn_workdir=$1
    PATCHNEST_SUPERKEY=''
    PATCHNEST_SUPERKEY_IS_NEW=0
    PATCHNEST_SUPERKEY_CANDIDATE=''

    if [ -e "$PATCHNEST_SUPERKEY_FILE" ]; then
        _pn_existing=$(patchnest_read_key_file "$PATCHNEST_SUPERKEY_FILE") || {
            >&2 echo "! Existing PatchNest superkey must be secure root-owned mode 0600"
            return 1
        }
        # An active key plus unresolved pending state is not a normal starting
        # point for another destructive operation. The patch path checks the
        # transaction marker before calling us; refuse an orphan pending key too.
        [ ! -e "$PATCHNEST_SUPERKEY_PENDING_FILE" ] || {
            >&2 echo "! Pending PatchNest credential exists; recovery review required"
            return 1
        }
        PATCHNEST_SUPERKEY=$_pn_existing
        export PATCHNEST_SUPERKEY
        return 0
    fi

    # Never silently reuse an orphan pending key as a new patch credential.
    [ ! -e "$PATCHNEST_SUPERKEY_PENDING_FILE" ] || {
        >&2 echo "! Pending PatchNest credential exists without committed key"
        return 1
    }

    command -v xxd >/dev/null 2>&1 || return 1
    [ -r /dev/urandom ] || return 1
    _pn_generated=$(xxd -p -l 24 /dev/urandom 2>/dev/null | tr -d '\r\n')
    patchnest_validate_superkey "$_pn_generated" || return 1

    PATCHNEST_SUPERKEY_CANDIDATE="$_pn_workdir/superkey.candidate"
    umask 077
    printf '%s\n' "$_pn_generated" > "$PATCHNEST_SUPERKEY_CANDIDATE" || return 1
    chmod 0600 "$PATCHNEST_SUPERKEY_CANDIDATE" || return 1
    _pn_candidate=$(patchnest_read_key_file "$PATCHNEST_SUPERKEY_CANDIDATE") || return 1
    [ "$_pn_candidate" = "$_pn_generated" ] || return 1

    PATCHNEST_SUPERKEY=$_pn_generated
    PATCHNEST_SUPERKEY_IS_NEW=1
    export PATCHNEST_SUPERKEY
}

patchnest_stage_superkey_for_flash() {
    [ -n "$PATCHNEST_SUPERKEY" ] || return 1
    [ "$PATCHNEST_SUPERKEY_IS_NEW" -eq 1 ] || return 0
    [ -n "$PATCHNEST_SUPERKEY_CANDIDATE" ] || return 1
    _pn_candidate=$(patchnest_read_key_file "$PATCHNEST_SUPERKEY_CANDIDATE") || return 1
    [ "$_pn_candidate" = "$PATCHNEST_SUPERKEY" ] || return 1
    [ ! -e "$PATCHNEST_SUPERKEY_PENDING_FILE" ] || return 1
    patchnest_write_pending_key "$PATCHNEST_SUPERKEY"
}

patchnest_discard_pending_key() {
    [ "$PATCHNEST_SUPERKEY_IS_NEW" -eq 1 ] || return 0
    rm -f "$PATCHNEST_SUPERKEY_PENDING_FILE"
    [ ! -e "$PATCHNEST_SUPERKEY_PENDING_FILE" ]
}

patchnest_superkey_sha256() {
    [ -n "$PATCHNEST_SUPERKEY" ] || return 1
    _pn_sha=$(printf '%s' "$PATCHNEST_SUPERKEY" | sha256sum | awk '{print $1}')
    printf '%s' "$_pn_sha" | grep -Eq '^[0-9a-f]{64}$' || return 1
    printf '%s\n' "$_pn_sha"
}

patchnest_revert_new_key_to_pending() {
    [ "$PATCHNEST_SUPERKEY_IS_NEW" -eq 1 ] || return 0
    if [ -f "$PATCHNEST_SUPERKEY_FILE" ] && [ ! -e "$PATCHNEST_SUPERKEY_PENDING_FILE" ]; then
        mv -f "$PATCHNEST_SUPERKEY_FILE" "$PATCHNEST_SUPERKEY_PENDING_FILE" 2>/dev/null || true
    fi
}

patchnest_commit_superkey() {
    [ -n "$PATCHNEST_SUPERKEY" ] || return 1

    if [ "$PATCHNEST_SUPERKEY_IS_NEW" -eq 0 ]; then
        _pn_existing=$(patchnest_read_key_file "$PATCHNEST_SUPERKEY_FILE") || return 1
        [ "$_pn_existing" = "$PATCHNEST_SUPERKEY" ] || return 1
        if [ "${FLASH_TO_DEVICE:-false}" = "true" ]; then
            command -v patchnest_commit_rollback_binding >/dev/null 2>&1 || return 1
            patchnest_commit_rollback_binding || return 1
        fi
        return 0
    fi

    if [ "${FLASH_TO_DEVICE:-false}" = "true" ]; then
        _pn_pending=$(patchnest_read_key_file "$PATCHNEST_SUPERKEY_PENDING_FILE") || return 1
        [ "$_pn_pending" = "$PATCHNEST_SUPERKEY" ] || return 1
        [ ! -e "$PATCHNEST_SUPERKEY_FILE" ] || return 1

        mv -f "$PATCHNEST_SUPERKEY_PENDING_FILE" "$PATCHNEST_SUPERKEY_FILE" || return 1
        _pn_committed=$(patchnest_read_key_file "$PATCHNEST_SUPERKEY_FILE") || {
            patchnest_revert_new_key_to_pending
            return 1
        }
        [ "$_pn_committed" = "$PATCHNEST_SUPERKEY" ] || {
            patchnest_revert_new_key_to_pending
            return 1
        }

        command -v patchnest_commit_rollback_binding >/dev/null 2>&1 || {
            patchnest_revert_new_key_to_pending
            return 1
        }
        patchnest_commit_rollback_binding || {
            patchnest_revert_new_key_to_pending
            return 1
        }
        return 0
    fi

    return 0
}

patchnest_store_export_key() {
    _pn_image=$1
    [ -f "$_pn_image" ] || return 1
    [ -n "$PATCHNEST_SUPERKEY" ] || return 1
    _pn_image_sha=$(sha256sum "$_pn_image" 2>/dev/null | awk '{print $1}')
    printf '%s' "$_pn_image_sha" | grep -Eq '^[0-9a-f]{64}$' || return 1
    mkdir -p "$PATCHNEST_EXPORT_KEY_DIR" || return 1
    umask 077
    _pn_out="$PATCHNEST_EXPORT_KEY_DIR/${_pn_image_sha}.superkey"
    _pn_tmp="${_pn_out}.tmp.$$"
    printf '%s\n' "$PATCHNEST_SUPERKEY" > "$_pn_tmp" || return 1
    chmod 0600 "$_pn_tmp" || { rm -f "$_pn_tmp"; return 1; }
    mv -f "$_pn_tmp" "$_pn_out" || { rm -f "$_pn_tmp"; return 1; }
    printf '%s\n' "$_pn_out"
}
