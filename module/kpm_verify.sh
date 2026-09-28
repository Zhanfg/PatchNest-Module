#!/bin/sh
# Ed25519 signature verification for KPM modules.
# Public API: verify_kpm_sig <kpm_file> <sig_file>

KPM_SIGN_PUBKEY_HEX="a6cee3371d164daf9ad2ed38ecaf1d492e7867fc6df31f810e69eaa0dd45259b"
# Signature over the five bytes "probe" with the deployment key above. This is
# a public verification vector only; the private key is not present here.
KPM_VERIFY_PROBE_SIG_HEX="886199b494a8dcb9ddec3a48385f4ea7e3cbefcc90198c6c807fd2434125b20e32f1b8cdd817e782f7fcf80860c4a32f7c49006089a4efefb4b734bbcb30f703"

kpm_verify__log() {
    if [ -n "${LOG:-}" ] && [ -n "${PNDIR:-}" ] && [ -d "$PNDIR" ]; then
        printf '[%s] kpm_verify: %s\n' "$(date)" "$1" >> "$LOG" 2>/dev/null || true
    fi
}

kpm_verify__hex_valid() {
    _kv_hex=$1
    _kv_len=$2
    [ "${#_kv_hex}" -eq "$_kv_len" ] || return 1
    case "$_kv_hex" in *[!0-9a-fA-F]*) return 1 ;; esac
    return 0
}

kpm_verify__make_tmpdir() {
    umask 077
    command -v mktemp >/dev/null 2>&1 || return 1
    _kv_tmp=$(mktemp -d /data/local/tmp/kpm_verify.XXXXXX 2>/dev/null) || \
        _kv_tmp=$(mktemp -d /tmp/kpm_verify.XXXXXX 2>/dev/null) || return 1
    [ -d "$_kv_tmp" ] && [ ! -L "$_kv_tmp" ] || {
        rm -rf "$_kv_tmp" 2>/dev/null || true
        return 1
    }
    printf '%s\n' "$_kv_tmp"
}

# OpenSSL expects a public-key object, not the raw 32-byte Ed25519 key. Encode
# the raw key as SubjectPublicKeyInfo DER:
#   SEQUENCE { SEQUENCE { OID 1.3.101.112 }, BIT STRING <32-byte key> }
kpm_verify__write_pubkey_der() {
    _kv_out=$1
    kpm_verify__hex_valid "$KPM_SIGN_PUBKEY_HEX" 64 || return 1
    command -v xxd >/dev/null 2>&1 || return 1
    printf '%s' "302a300506032b6570032100${KPM_SIGN_PUBKEY_HEX}" \
        | xxd -r -p > "$_kv_out" 2>/dev/null || return 1
    [ "$(wc -c < "$_kv_out" 2>/dev/null)" -eq 44 ] || return 1
}

kpm_verify__write_sig_bin() {
    _kv_hex=$1
    _kv_out=$2
    kpm_verify__hex_valid "$_kv_hex" 128 || return 1
    command -v xxd >/dev/null 2>&1 || return 1
    printf '%s' "$_kv_hex" | xxd -r -p > "$_kv_out" 2>/dev/null || return 1
    [ "$(wc -c < "$_kv_out" 2>/dev/null)" -eq 64 ] || return 1
}

kpm_verify__openssl_verify() {
    _kv_input=$1
    _kv_sig_hex=$2
    command -v openssl >/dev/null 2>&1 || return 1
    command -v xxd >/dev/null 2>&1 || return 1

    _kv_tmp=$(kpm_verify__make_tmpdir) || return 1
    _kv_pub="$_kv_tmp/pub.der"
    _kv_sig="$_kv_tmp/sig.bin"
    if ! kpm_verify__write_pubkey_der "$_kv_pub" || \
       ! kpm_verify__write_sig_bin "$_kv_sig_hex" "$_kv_sig"; then
        rm -rf "$_kv_tmp" 2>/dev/null || true
        return 1
    fi

    if openssl pkeyutl -verify \
        -pubin -keyform DER -inkey "$_kv_pub" \
        -sigfile "$_kv_sig" -rawin -in "$_kv_input" \
        >/dev/null 2>&1; then
        rm -rf "$_kv_tmp" 2>/dev/null || true
        return 0
    fi
    rm -rf "$_kv_tmp" 2>/dev/null || true
    return 1
}

# Capability check uses the actual deployment public key and its probe
# signature, so a CLI that merely exposes pkeyutl but cannot verify Ed25519 does
# not pass the gate.
kpm_verify__require_openssl() {
    _kv_tmp=$(kpm_verify__make_tmpdir) || return 1
    _kv_probe="$_kv_tmp/probe"
    printf '%s' probe > "$_kv_probe" || {
        rm -rf "$_kv_tmp" 2>/dev/null || true
        return 1
    }
    if kpm_verify__openssl_verify "$_kv_probe" "$KPM_VERIFY_PROBE_SIG_HEX"; then
        rm -rf "$_kv_tmp" 2>/dev/null || true
        return 0
    fi
    rm -rf "$_kv_tmp" 2>/dev/null || true
    return 1
}

verify_kpm_sig() {
    _kv_kpm=${1:-}
    _kv_sigfile=${2:-}
    [ -n "$_kv_kpm" ] && [ -n "$_kv_sigfile" ] || {
        kpm_verify__log "missing arguments"
        return 1
    }
    [ -f "$_kv_kpm" ] && [ ! -L "$_kv_kpm" ] || {
        kpm_verify__log "KPM file missing/not regular: $_kv_kpm"
        return 1
    }
    [ -f "$_kv_sigfile" ] && [ ! -L "$_kv_sigfile" ] || {
        kpm_verify__log "signature file missing/not regular: $_kv_sigfile"
        return 1
    }

    _kv_sig_hex=$(awk 'NF{print; exit}' "$_kv_sigfile" 2>/dev/null | tr -d ' \t\r\n')
    kpm_verify__hex_valid "$_kv_sig_hex" 128 || {
        kpm_verify__log "signature is not exactly 64 bytes of hex"
        return 1
    }

    if ! kpm_verify__require_openssl; then
        kpm_verify__log "OpenSSL Ed25519 pkeyutl verification unavailable; failing closed"
        return 1
    fi

    if kpm_verify__openssl_verify "$_kv_kpm" "$_kv_sig_hex"; then
        kpm_verify__log "signature OK: $(basename "$_kv_kpm")"
        return 0
    fi
    kpm_verify__log "signature INVALID: $(basename "$_kv_kpm")"
    return 1
}
