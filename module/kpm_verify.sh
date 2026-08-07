#!/system/bin/sh
# PatchNest Ed25519 KPM signature verification.
#
# Public API:
#   verify_kpm_sig <kpm_file> <sig_file>
#
# Android uses the packaged static `bin/kpm-verify` backend. OpenSSL exists only
# as an explicit host-test fallback through KPM_VERIFY_ALLOW_OPENSSL_FALLBACK=1.

umask 077

KPM_SIGN_PUBKEY_HEX="a6cee3371d164daf9ad2ed38ecaf1d492e7867fc6df31f810e69eaa0dd45259b"
KPM_SIGN_SPKI_PREFIX_HEX="302a300506032b6570032100"
KPM_VERIFY_PROBE_SIG="886199b494a8dcb9ddec3a48385f4ea7e3cbefcc90198c6c807fd2434125b20e32f1b8cdd817e782f7fcf80860c4a32f7c49006089a4efefb4b734bbcb30f703"

kpm_verify__log() {
    if [ -n "${LOG:-}" ] && [ -n "${PNDIR:-}" ] && [ -d "$PNDIR" ]; then
        printf '[%s] kpm_verify: %s\n' "$(date)" "$1" >>"$LOG" 2>/dev/null || true
    fi
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

kpm_verify__resolve_binary() {
    if [ -n "${KPM_VERIFY_BIN:-}" ]; then
        printf '%s\n' "$KPM_VERIFY_BIN"
        return 0
    fi
    if [ -n "${MODDIR:-}" ]; then
        printf '%s\n' "$MODDIR/bin/kpm-verify"
        return 0
    fi
    printf '%s\n' '/data/adb/modules/PatchNest/bin/kpm-verify'
}

kpm_verify__require_binary() {
    case "${KPM_VERIFY_BINARY_READY:-}" in
        yes) KPM_VERIFY_BACKEND=binary; return 0 ;;
        no) return 1 ;;
    esac

    _binary=$(kpm_verify__resolve_binary) || {
        KPM_VERIFY_BINARY_READY=no
        return 1
    }
    [ -f "$_binary" ] && [ -x "$_binary" ] && [ ! -L "$_binary" ] || {
        KPM_VERIFY_BINARY_READY=no
        return 1
    }

    _tmp=$(kpm_verify__make_temp_dir) || {
        KPM_VERIFY_BINARY_READY=no
        return 1
    }
    _message="$_tmp/probe.bin"
    _ok=false
    if printf '%s' probe >"$_message" \
       && "$_binary" "$KPM_SIGN_PUBKEY_HEX" "$KPM_VERIFY_PROBE_SIG" "$_message" \
          >/dev/null 2>&1; then
        _ok=true
    fi
    rm -rf "$_tmp" 2>/dev/null || true

    if $_ok; then
        KPM_VERIFY_BINARY_READY=yes
        KPM_VERIFY_RESOLVED_BIN=$_binary
        KPM_VERIFY_BACKEND=binary
        return 0
    fi
    KPM_VERIFY_BINARY_READY=no
    return 1
}

# Host-only OpenSSL fallback -------------------------------------------------
kpm_verify__hex_to_bin() {
    _hex=$1
    _out=$2
    case "$_hex" in ""|*[!0-9a-fA-F]*) return 1 ;; esac
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

kpm_verify__require_openssl() {
    [ "${KPM_VERIFY_ALLOW_OPENSSL_FALLBACK:-0}" = "1" ] || return 1
    case "${KPM_VERIFY_OPENSSL_READY:-}" in
        yes) KPM_VERIFY_BACKEND=openssl; return 0 ;;
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
    _ok=false
    if kpm_verify__hex_to_bin "${KPM_SIGN_SPKI_PREFIX_HEX}${KPM_SIGN_PUBKEY_HEX}" "$_pub" \
       && kpm_verify__hex_to_bin "$KPM_VERIFY_PROBE_SIG" "$_sig" \
       && printf '%s' probe >"$_message" \
       && kpm_verify__openssl_verify "$_pub" "$_sig" "$_message"; then
        _ok=true
    fi
    rm -rf "$_tmp" 2>/dev/null || true

    if $_ok; then
        KPM_VERIFY_OPENSSL_READY=yes
        KPM_VERIFY_BACKEND=openssl
        return 0
    fi
    KPM_VERIFY_OPENSSL_READY=no
    return 1
}

kpm_verify__require_backend() {
    if kpm_verify__require_binary; then
        return 0
    fi
    if kpm_verify__require_openssl; then
        return 0
    fi
    KPM_VERIFY_BACKEND=none
    return 1
}

kpm_verify__extract_signature_hex() {
    _sig_file=$1
    _sig_size=$(wc -c <"$_sig_file" 2>/dev/null)
    [ "$_sig_size" -le 4096 ] 2>/dev/null || {
        kpm_verify__log "signature file exceeds 4096 bytes"
        return 1
    }

    _sig_line=$(awk '
        NF { count += 1; value = $0 }
        END {
            if (count != 1) exit 1
            print value
        }
    ' "$_sig_file" 2>/dev/null) || {
        kpm_verify__log "signature file must contain exactly one non-empty line"
        return 1
    }
    _sig_hex=$(printf '%s' "$_sig_line" | tr -d ' \t\r\n')
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
    printf '%s\n' "$_sig_hex"
}

verify_kpm_sig() {
    _kpm=${1:-}
    _sig_file=${2:-}
    [ -n "$_kpm" ] && [ -n "$_sig_file" ] || {
        kpm_verify__log "missing arguments"
        return 1
    }
    [ -f "$_kpm" ] && [ -s "$_kpm" ] && [ ! -L "$_kpm" ] || {
        kpm_verify__log "KPM missing, empty, or symlinked: $_kpm"
        return 1
    }
    [ -f "$_sig_file" ] && [ -s "$_sig_file" ] && [ ! -L "$_sig_file" ] || {
        kpm_verify__log "signature missing, empty, or symlinked: $_sig_file"
        return 1
    }

    _sig_hex=$(kpm_verify__extract_signature_hex "$_sig_file") || return 1
    if ! kpm_verify__require_backend; then
        kpm_verify__log "packaged Ed25519 verifier unavailable; failing closed"
        return 1
    fi

    _verified=false
    case "$KPM_VERIFY_BACKEND" in
        binary)
            if "$KPM_VERIFY_RESOLVED_BIN" "$KPM_SIGN_PUBKEY_HEX" \
               "$_sig_hex" "$_kpm" >/dev/null 2>&1; then
                _verified=true
            fi
            ;;
        openssl)
            _tmp=$(kpm_verify__make_temp_dir) || return 1
            _pub="$_tmp/pub.der"
            _sig="$_tmp/sig.bin"
            if kpm_verify__hex_to_bin "${KPM_SIGN_SPKI_PREFIX_HEX}${KPM_SIGN_PUBKEY_HEX}" "$_pub" \
               && kpm_verify__hex_to_bin "$_sig_hex" "$_sig" \
               && kpm_verify__openssl_verify "$_pub" "$_sig" "$_kpm"; then
                _verified=true
            fi
            rm -rf "$_tmp" 2>/dev/null || true
            ;;
        *) return 1 ;;
    esac

    if $_verified; then
        kpm_verify__log "signature OK backend=$KPM_VERIFY_BACKEND: $(basename "$_kpm")"
        return 0
    fi
    kpm_verify__log "signature INVALID backend=$KPM_VERIFY_BACKEND: $(basename "$_kpm")"
    return 1
}
