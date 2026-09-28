#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p /data/local/tmp

fail() {
    echo "KPM signature contract: FAIL: $*" >&2
    exit 1
}
command -v openssl >/dev/null 2>&1 || fail "openssl missing"
command -v xxd >/dev/null 2>&1 || fail "xxd missing"

PNDIR="$TMP/state"
LOG="$TMP/verify.log"
mkdir -p "$PNDIR"
export PNDIR LOG
# shellcheck disable=SC1090
. "$ROOT/module/kpm_verify.sh"

printf '%s' probe > "$TMP/probe.kpm"
printf '%s\n' "$KPM_VERIFY_PROBE_SIG_HEX" > "$TMP/probe.sig"

kpm_verify__require_openssl || fail "deployment Ed25519 probe vector did not verify"
verify_kpm_sig "$TMP/probe.kpm" "$TMP/probe.sig" || fail "valid deployment signature rejected"

printf '%s' 'probe!' > "$TMP/tampered.kpm"
if verify_kpm_sig "$TMP/tampered.kpm" "$TMP/probe.sig"; then
    fail "tampered payload accepted with valid signature"
fi

printf '%s\n' '00' > "$TMP/malformed.sig"
if verify_kpm_sig "$TMP/probe.kpm" "$TMP/malformed.sig"; then
    fail "malformed signature accepted"
fi

ln -s "$TMP/probe.sig" "$TMP/link.sig"
if verify_kpm_sig "$TMP/probe.kpm" "$TMP/link.sig"; then
    fail "symlink signature file accepted"
fi

grep -Fq 'signature OK' "$LOG" || fail "success was not audited"
grep -Fq 'signature INVALID' "$LOG" || fail "tamper rejection was not audited"

echo "KPM signature contract: PASS"
