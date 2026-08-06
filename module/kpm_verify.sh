#!/system/bin/sh
# PatchNest Ed25519 KPM signature verification.
#
# Public API:
#   verify_kpm_sig <kpm_file> <sig_file>
#
# Signature format: first non-empty line is exactly 128 hexadecimal characters
# representing a raw 64-byte Ed25519 signature.

umask 077

# Raw 32-byte Ed25519 public key. This is still the development deployment key;
# release-key provenance and signing custody remain separate release blockers.
KPM_SIGN_PUBKEY_HEX="a6cee3371d164daf9ad2ed38ecaf1d492e7867fc6df31f810e69eaa0dd45259b"
# RFC 8410 SubjectPublicKeyInfo prefix for an Ed25519 raw public key:
# SEQUENCE { SEQUENCE { OID 1.3.101.112 }, BIT STRING <32 bytes> }
KPM_SIGN_SPKI_PREFIX_HEX="302a300506032b6570032100"

kpm_verify__log() {
    if [ -n "${LOG:-}" ] && [ -n "${PNDIR:-}" ] && [ -d "$PNDIR" ]; then
        printf '[%s] kpm_verify: %s\n' "$(date)" "$1" >>"$LOG" 2>/dev/null || true
    fi
}

kpm_verify__hex_to_bin() {
    _hex=$1
    _out=$2
    case "$_hex" in
        ""|*[!0-9a-fA-F]*) return 1 ;;
    esac
    [ $(( ${#_hex} % 2 )) -eq 0 ] || return 1

    _index=1
    _format=""
    while [ "$_index" -le "${#_hex}" ]; do
        _pair=$(printf '%s' "$_hex" | cut -c"$_index"-$((_index + 1)))
        _format="${_format}\\x${_pair}"
        _index=$((_index + 2))
    done
    if ! printf '%b' "$_format" >"$_out" 2>/dev/null; then
        rm -f "$_out"
        return 1
    fi
    _expected=$(( ${#_hex} / 2 ))
    _actual=$(wc -c <"$_out" 2>/dev/null)
    [ "$_actual" = "$_expected" ] || {
        rm -f "$_out"
        return 1
    }
    return 0
}

kpm_verify__make_temp_dir() {
    command -v mktemp >/dev/null 2>&1 || return 1
    _base=${TMPDIR:-/data/local/tmp}
    [ -d "$_base" ] || return 1
    _dir=$(mktemp -d "$_base/patchnest-kpm-verify.XXXXXX" 2>/dev/null) || return 1
    [ -d "$_dir" ] && [ ! -L "$_dir" ] || {
        rm -rf "$_dir" 2>/dev/null || true
        return 1
    }
    printf '%s\n' "$_dir"
}

kpm_verify__openssl_verify() {
    _public_der=$1
    _signature_bin=$2
    _message=$3
    openssl pkeyutl \
        -verify \
        -pubin \
        -keyform DER \
        -inkey "$_public_der" \
        -rawin \
        -in "$_message" \
        -sigfile "$_signature_bin" \
        >/dev/null 2>&1
}

# Probe the exact deployment key and command form once per shell process. The
# probe vector is public and contains no secret material.
kpm_verify__require_openssl() {
    case "${KPM_VERIFY_OPENSSL_READY:-}" in
        yes) return 0 ;;
        no) return 1 ;;
    esac
    command -v openssl >/dev/null 2>&1 || {
        KPM_VERIFY_OPENSSL_READY=no
        return 1
    }

    _tmp=$(kpm_verify__make_temp_dir) || {
        KPM_VERIFY_OPENSSL_READY=no
        return 1
    }
    _pub="$_tmp/pub.der"
    _sig="$_tmp/sig.bin"
    _message="$_tmp/message.bin"
    _probe_sig="886199b494a8dcb9ddec3a48385f4ea7e3cbefcc90198c6c807fd2434125b20e32f1b8cdd817e782f7fcf80860c4a32f7c49006089a4efefb4b734bbcb30f703"

    _ok=false
    if kpm_verify__hex_to_bin "${KPM_SIGN_SPKI_PREFIX_HEX}${KPM_SIGN_PUBKEY_HEX}" "$_pub" \
       && kpm_verify__hex_to_bin "$_probe_sig" "$_sig" \
       && printf '%s' probe >"$_message" \
       && kpm_verify__openssl_verify "$_pub" "$_sig" "$_message"; then
        _ok=true
    fi
    rm -rf "$_tmp" 2>/dev/null || true

    if $_ok; then
        KPM_VERIFY_OPENSSL_READY=yes
        return 0
    fi
    KPM_VERIFY_OPENSSL_READY=no
    return 1
}

verify_kpm_sig() {
    _kpm=${1:-}
    _sig_file=${2:-}
    [ -n "$_kpm" ] && [ -n "$_sig_file" ] || {
        kpm_verify__log "missing arguments"
        return 1
    }
    [ -f "$_kpm" ] && [ -s "$_kpm" ] || {
        kpm_verify__log "KPM missing or empty: $_kpm"
        return 1
    }
    [ -f "$_sig_file" ] && [ -s "$_sig_file" ] || {
        kpm_verify__log "signature missing or empty: $_sig_file"
        return 1
    }
    _sig_size=$(wc -c <"$_sig_file" 2>/dev/null)
    [ "$_sig_size" -le 4096 ] 2>/dev/null || {
        kpm_verify__log "signature file exceeds 4096 bytes"
        return 1
    }
    if ! kpm_verify__require_openssl; then
        kpm_verify__log "OpenSSL Ed25519 pkeyutl support unavailable; failing closed"
        return 1
    fi

    _sig_hex=$(awk 'NF { print; exit }' "$_sig_file" 2>/dev/null | tr -d ' \t\r\n')
    [ "${#_sig_hex}" -eq 128 ] || {
        kpm_verify__log "signature is not 64 bytes"
        return 1
    }
    case "$_sig_hex" in
        *[!0-9a-fA-F]*)
            kpm_verify__log "signature contains non-hex characters"
            return 1
            ;;
    esac

    _tmp=$(kpm_verify__make_temp_dir) || {
        kpm_verify__log "secure temporary directory unavailable"
        return 1
    }
    _pub="$_tmp/pub.der"
    _sig="$_tmp/sig.bin"
    _verified=false
    if kpm_verify__hex_to_bin "${KPM_SIGN_SPKI_PREFIX_HEX}${KPM_SIGN_PUBKEY_HEX}" "$_pub" \
       && kpm_verify__hex_to_bin "$_sig_hex" "$_sig" \
       && kpm_verify__openssl_verify "$_pub" "$_sig" "$_kpm"; then
        _verified=true
    fi
    rm -rf "$_tmp" 2>/dev/null || true

    if $_verified; then
        kpm_verify__log "signature OK: $(basename "$_kpm")"
        return 0
    fi
    kpm_verify__log "signature INVALID: $(basename "$_kpm")"
    return 1
}
