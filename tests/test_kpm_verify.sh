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

verify_kpm_sig "$WORK/probe.kpm" "$WORK/probe.kpm.sig" \
    || { echo 'ERROR: valid deployment-key probe signature was rejected' >&2; exit 1; }

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

grep -q 'signature OK' "$LOG" || {
    echo 'ERROR: successful verification was not logged' >&2
    exit 1
}
grep -q 'signature INVALID' "$LOG" || {
    echo 'ERROR: invalid verification was not logged' >&2
    exit 1
}

printf '%s\n' 'KPM Ed25519 verification vectors passed.'
