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
    # Keep the persisted format intentionally narrow. kptools accepts arbitrary
    # strings, but a hex-only key avoids shell/log/parser ambiguity everywhere.
    printf '%s' "$_pn_key" | grep -Eq '^[0-9a-fA-F]+$'
}

patchnest_prepare_superkey() {
    _pn_workdir=$1
    PATCHNEST_SUPERKEY=''
    PATCHNEST_SUPERKEY_IS_NEW=0

    if [ -f "$PATCHNEST_SUPERKEY_FILE" ]; then
        _pn_existing=$(head -n 1 "$PATCHNEST_SUPERKEY_FILE" 2>/dev/null | tr -d '\r\n')
        if patchnest_validate_superkey "$_pn_existing"; then
            PATCHNEST_SUPERKEY=$_pn_existing
            export PATCHNEST_SUPERKEY
            return 0
        fi
        >&2 echo "! Existing PatchNest superkey file is invalid; refusing to overwrite it implicitly"
        return 1
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
    PATCHNEST_SUPERKEY=$_pn_generated
    PATCHNEST_SUPERKEY_IS_NEW=1
    export PATCHNEST_SUPERKEY
}

patchnest_superkey_sha256() {
    [ -n "$PATCHNEST_SUPERKEY" ] || return 1
    printf '%s' "$PATCHNEST_SUPERKEY" | sha256sum | awk '{print $1}'
}

patchnest_commit_superkey() {
    [ -n "$PATCHNEST_SUPERKEY" ] || return 1
    _pn_dir=${PATCHNEST_SUPERKEY_FILE%/*}
    mkdir -p "$_pn_dir" || return 1
    umask 077
    _pn_tmp="${PATCHNEST_SUPERKEY_FILE}.tmp.$$"
    printf '%s\n' "$PATCHNEST_SUPERKEY" > "$_pn_tmp" || return 1
    chmod 0600 "$_pn_tmp" || { rm -f "$_pn_tmp"; return 1; }
    mv -f "$_pn_tmp" "$PATCHNEST_SUPERKEY_FILE" || return 1
    chmod 0600 "$PATCHNEST_SUPERKEY_FILE" || return 1
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
