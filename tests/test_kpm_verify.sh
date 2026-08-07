#!/usr/bin/env bash
# Offline regression test for module/kpm_verify.sh.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
export PNDIR="$WORK/state"
export LOG="$WORK/verify.log"
mkdir -p "$PNDIR"

# shellcheck source=/dev/null
. "$ROOT/module/kpm_verify.sh"

PROBE_SIG=886199b494a8dcb9ddec3a48385f4ea7e3cbefcc90198c6c807fd2434125b20e32f1b8cdd817e782f7fcf80860c4a32f7c49006089a4efefb4b734bbcb30f703
printf '%s' probe >"$WORK/probe.kpm"
printf '%s\n' "$PROBE_SIG" >"$WORK/probe.kpm.sig"

# Android defaults fail closed when the packaged verifier is absent. System
# OpenSSL is not an implicit runtime dependency.
unset KPM_VERIFY_BIN KPM_VERIFY_ALLOW_OPENSSL_FALLBACK
unset KPM_VERIFY_BINARY_READY KPM_VERIFY_OPENSSL_READY KPM_VERIFY_BACKEND KPM_VERIFY_RESOLVED_BIN
if verify_kpm_sig "$WORK/probe.kpm" "$WORK/probe.kpm.sig"; then
    echo 'ERROR: verification succeeded without a packaged backend' >&2
    exit 1
fi

# Host tests may explicitly enable the OpenSSL fallback.
export KPM_VERIFY_ALLOW_OPENSSL_FALLBACK=1
unset KPM_VERIFY_BINARY_READY KPM_VERIFY_OPENSSL_READY KPM_VERIFY_BACKEND KPM_VERIFY_RESOLVED_BIN
verify_kpm_sig "$WORK/probe.kpm" "$WORK/probe.kpm.sig" \
    || { echo 'ERROR: valid deployment-key probe signature was rejected' >&2; exit 1; }
[[ "$KPM_VERIFY_BACKEND" == openssl ]]

printf '%s' tampered >"$WORK/probe.kpm"
if verify_kpm_sig "$WORK/probe.kpm" "$WORK/probe.kpm.sig"; then
    echo 'ERROR: tampered message was accepted' >&2
    exit 1
fi

printf '%s' probe >"$WORK/probe.kpm"
printf '%s\n' "0${PROBE_SIG#?}" >"$WORK/probe.kpm.sig"
if verify_kpm_sig "$WORK/probe.kpm" "$WORK/probe.kpm.sig"; then
    echo 'ERROR: tampered signature was accepted' >&2
    exit 1
fi

printf '%05000d\n' 0 >"$WORK/oversized.sig"
if verify_kpm_sig "$WORK/probe.kpm" "$WORK/oversized.sig"; then
    echo 'ERROR: oversized signature file was accepted' >&2
    exit 1
fi

printf '%s\n' not-hex >"$WORK/malformed.sig"
if verify_kpm_sig "$WORK/probe.kpm" "$WORK/malformed.sig"; then
    echo 'ERROR: malformed signature was accepted' >&2
    exit 1
fi

printf '%s\n%s\n' "$PROBE_SIG" "$PROBE_SIG" >"$WORK/ambiguous.sig"
if verify_kpm_sig "$WORK/probe.kpm" "$WORK/ambiguous.sig"; then
    echo 'ERROR: multi-line signature file was accepted' >&2
    exit 1
fi

# Model the packaged binary and verify that it is preferred over OpenSSL.
FAKE_VERIFY="$WORK/kpm-verify"
cat >"$FAKE_VERIFY" <<'VERIFY'
#!/bin/sh
expected_key=a6cee3371d164daf9ad2ed38ecaf1d492e7867fc6df31f810e69eaa0dd45259b
expected_sig=886199b494a8dcb9ddec3a48385f4ea7e3cbefcc90198c6c807fd2434125b20e32f1b8cdd817e782f7fcf80860c4a32f7c49006089a4efefb4b734bbcb30f703
[ "$#" -eq 3 ] || exit 2
[ "$1" = "$expected_key" ] || exit 2
[ "$2" = "$expected_sig" ] || exit 1
[ -f "$3" ] && [ "$(cat "$3")" = probe ] || exit 1
exit 0
VERIFY
chmod 0755 "$FAKE_VERIFY"

printf '%s' probe >"$WORK/probe.kpm"
printf '%s\n' "$PROBE_SIG" >"$WORK/probe.kpm.sig"
export KPM_VERIFY_BIN="$FAKE_VERIFY"
unset KPM_VERIFY_ALLOW_OPENSSL_FALLBACK
unset KPM_VERIFY_BINARY_READY KPM_VERIFY_OPENSSL_READY KPM_VERIFY_BACKEND KPM_VERIFY_RESOLVED_BIN
verify_kpm_sig "$WORK/probe.kpm" "$WORK/probe.kpm.sig" \
    || { echo 'ERROR: packaged verifier model rejected the valid vector' >&2; exit 1; }
[[ "$KPM_VERIFY_BACKEND" == binary ]]

grep -q 'signature OK backend=openssl' "$LOG" || {
    echo 'ERROR: OpenSSL host fallback success was not logged' >&2
    exit 1
}
grep -q 'signature OK backend=binary' "$LOG" || {
    echo 'ERROR: packaged backend success was not logged' >&2
    exit 1
}
grep -q 'signature INVALID backend=openssl' "$LOG" || {
    echo 'ERROR: invalid verification was not logged' >&2
    exit 1
}
grep -q 'signature file must contain exactly one non-empty line' "$LOG" || {
    echo 'ERROR: ambiguous signature rejection was not logged' >&2
    exit 1
}

ln -s "$WORK/probe.kpm" "$WORK/probe-link.kpm"
if verify_kpm_sig "$WORK/probe-link.kpm" "$WORK/probe.kpm.sig"; then
    echo 'ERROR: symlinked KPM was accepted' >&2
    exit 1
fi
ln -s "$WORK/probe.kpm.sig" "$WORK/probe-link.sig"
if verify_kpm_sig "$WORK/probe.kpm" "$WORK/probe-link.sig"; then
    echo 'ERROR: symlinked signature was accepted' >&2
    exit 1
fi

printf '%s\n' 'KPM Ed25519 verification vectors passed.'
