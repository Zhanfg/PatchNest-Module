#!/system/bin/sh
# PatchNest Public1158 superkey lifecycle.
# This file is sourced by boot_patch.sh. It never prints the key value.

PATCHNEST_SUPERKEY_FILE="${PATCHNEST_SUPERKEY_FILE:-/data/adb/patchnest/superkey}"
PATCHNEST_EXPORT_KEY_DIR="${PATCHNEST_EXPORT_KEY_DIR:-/data/adb/patchnest/export_keys}"
PATCHNEST_SUPERKEY=''
PATCHNEST_SUPERKEY_IS_NEW=0

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

patchnest_existing_key_is_secure() {
    [ -f "$PATCHNEST_SUPERKEY_FILE" ] || return 1
    _pn_mode=$(stat -c '%a' "$PATCHNEST_SUPERKEY_FILE" 2>/dev/null) || return 1
    _pn_owner=$(stat -c '%u' "$PATCHNEST_SUPERKEY_FILE" 2>/dev/null) || return 1
    _pn_expected_owner=$(patchnest_expected_key_owner) || return 1
    [ "$_pn_mode" = "600" ] || return 1
    [ "$_pn_owner" = "$_pn_expected_owner" ] || return 1
}

patchnest_prepare_superkey() {
    _pn_workdir=$1
    PATCHNEST_SUPERKEY=''
    PATCHNEST_SUPERKEY_IS_NEW=0

    if [ -e "$PATCHNEST_SUPERKEY_FILE" ]; then
        [ -f "$PATCHNEST_SUPERKEY_FILE" ] || {
            >&2 echo "! Existing PatchNest superkey path is not a regular file"
            return 1
        }
        patchnest_existing_key_is_secure || {
            >&2 echo "! Existing PatchNest superkey must be securely owned and mode 0600"
            return 1
        }
        _pn_existing=$(head -n 1 "$PATCHNEST_SUPERKEY_FILE" 2>/dev/null | tr -d '\r\n')
        patchnest_validate_superkey "$_pn_existing" || {
            >&2 echo "! Existing PatchNest superkey file is invalid"
            return 1
        }
        PATCHNEST_SUPERKEY=$_pn_existing
        export PATCHNEST_SUPERKEY
        return 0
    fi

    command -v xxd >/dev/null 2>&1 || {
        >&2 echo "! xxd is required to generate a Public1158 superkey"
        return 1
    }
    [ -r /dev/urandom ] || {
        >&2 echo "! /dev/urandom is unavailable"
        return 1
    }

    # 24 random bytes -> 48 lowercase hexadecimal characters. This remains
    # below Public1158's 0x40-byte key limit while providing 192 random bits.
    _pn_generated=$(xxd -p -l 24 /dev/urandom 2>/dev/null | tr -d '\r\n')
    patchnest_validate_superkey "$_pn_generated" || {
        >&2 echo "! Generated superkey failed local validation"
        return 1
    }

    umask 077
    printf '%s\n' "$_pn_generated" > "$_pn_workdir/superkey.candidate" || return 1
    chmod 0600 "$_pn_workdir/superkey.candidate" || return 1
    [ "$(stat -c '%a' "$_pn_workdir/superkey.candidate" 2>/dev/null)" = "600" ] || return 1
    PATCHNEST_SUPERKEY=$_pn_generated
    PATCHNEST_SUPERKEY_IS_NEW=1
    export PATCHNEST_SUPERKEY
}

patchnest_superkey_sha256() {
    [ -n "$PATCHNEST_SUPERKEY" ] || return 1
    printf '%s' "$PATCHNEST_SUPERKEY" | sha256sum | awk '{print $1}'
}

patchnest_drop_binding_after_key_failure() {
    [ "${1:-0}" -eq 0 ] || patchnest_remove_rollback_binding
}

patchnest_commit_superkey() {
    [ -n "$PATCHNEST_SUPERKEY" ] || return 1

    # Existing credentials are already the committed identity of the current
    # installation. Verify them, but never rewrite the file as part of a new
    # flash transaction.
    if [ "$PATCHNEST_SUPERKEY_IS_NEW" -eq 0 ]; then
        patchnest_existing_key_is_secure || return 1
        _pn_existing=$(head -n 1 "$PATCHNEST_SUPERKEY_FILE" 2>/dev/null | tr -d '\r\n')
        [ "$_pn_existing" = "$PATCHNEST_SUPERKEY" ] || return 1

        if [ "${FLASH_TO_DEVICE:-false}" = "true" ]; then
            command -v patchnest_commit_rollback_binding >/dev/null 2>&1 || return 1
            patchnest_commit_rollback_binding || return 1
        fi
        return 0
    fi

    # New credentials are committed only after the boot write passed readback.
    # Bind rollback first; any later key failure removes the binding and causes
    # boot_patch.sh to restore the verified pre-write image.
    _pn_binding_committed=0
    if [ "${FLASH_TO_DEVICE:-false}" = "true" ]; then
        command -v patchnest_commit_rollback_binding >/dev/null 2>&1 || return 1
        patchnest_commit_rollback_binding || return 1
        _pn_binding_committed=1
    fi

    _pn_dir=${PATCHNEST_SUPERKEY_FILE%/*}
    mkdir -p "$_pn_dir" || {
        patchnest_drop_binding_after_key_failure "$_pn_binding_committed"
        return 1
    }

    umask 077
    _pn_tmp="${PATCHNEST_SUPERKEY_FILE}.tmp.$$"
    printf '%s\n' "$PATCHNEST_SUPERKEY" > "$_pn_tmp" || {
        patchnest_drop_binding_after_key_failure "$_pn_binding_committed"
        return 1
    }
    chmod 0600 "$_pn_tmp" || {
        rm -f "$_pn_tmp"
        patchnest_drop_binding_after_key_failure "$_pn_binding_committed"
        return 1
    }
    [ "$(stat -c '%a' "$_pn_tmp" 2>/dev/null)" = "600" ] || {
        rm -f "$_pn_tmp"
        patchnest_drop_binding_after_key_failure "$_pn_binding_committed"
        return 1
    }

    # Single irreversible key-file transition. mv preserves the already checked
    # 0600 mode, so there is no post-mv chmod that could create a half-state.
    mv -f "$_pn_tmp" "$PATCHNEST_SUPERKEY_FILE" || {
        rm -f "$_pn_tmp"
        patchnest_drop_binding_after_key_failure "$_pn_binding_committed"
        return 1
    }

    # Verification after rename performs no mutation. If it fails, remove the
    # newly created credential and rollback authorization before the caller
    # restores the verified boot backup.
    if ! patchnest_existing_key_is_secure; then
        rm -f "$PATCHNEST_SUPERKEY_FILE"
        patchnest_drop_binding_after_key_failure "$_pn_binding_committed"
        return 1
    fi
    _pn_committed=$(head -n 1 "$PATCHNEST_SUPERKEY_FILE" 2>/dev/null | tr -d '\r\n')
    if [ "$_pn_committed" != "$PATCHNEST_SUPERKEY" ]; then
        rm -f "$PATCHNEST_SUPERKEY_FILE"
        patchnest_drop_binding_after_key_failure "$_pn_binding_committed"
        return 1
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
    printf '%s\n' "$PATCHNEST_SUPERKEY" > "$_pn_out" || return 1
    chmod 0600 "$_pn_out" || return 1
    printf '%s\n' "$_pn_out"
}
