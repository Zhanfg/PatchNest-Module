#!/usr/bin/env bash
# Offline tests for module/patch/kptools_argv.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CAPTURE="$WORK/argv.txt"
CALLED=0
KPIMG="$WORK/kpimg"
printf '%s' fixture >"$KPIMG"

# shellcheck source=/dev/null
. "$ROOT/module/patch/kptools_argv.sh"

kptools() {
    CALLED=$((CALLED + 1))
    : >"$CAPTURE"
    for argument in "$@"; do
        printf '%s\n' "$argument" >>"$CAPTURE"
    done
    return 0
}

assert_capture() {
    local expected="$1"
    local actual
    actual=$(cat "$CAPTURE")
    if [[ "$actual" != "$expected" ]]; then
        printf 'ERROR: argv mismatch\n--- expected ---\n%s\n--- actual ---\n%s\n' "$expected" "$actual" >&2
        exit 1
    fi
}

run_patchnest_kptools_patch \
    -s 'plain-secret' \
    -A '"hello world"' \
    -M '/tmp/module.kpm'
assert_capture $'-p\n-i\nkernel.ori\n-k\n'"$KPIMG"$'\n-o\nkernel\n-s\nplain-secret\n-A\nhello world\n-M\n/tmp/module.kpm'

# Only values immediately following -A are decoded. A quoted-looking superkey
# remains byte-for-byte unchanged.
run_patchnest_kptools_patch \
    -s '"quoted-secret"' \
    -A '"hello \"world\" \\ path"'
assert_capture $'-p\n-i\nkernel.ori\n-k\n'"$KPIMG"$'\n-o\nkernel\n-s\n"quoted-secret"\n-A\nhello "world" \ path'

CALLED=0
if run_patchnest_kptools_patch -A; then
    echo 'ERROR: missing -A value was accepted' >&2
    exit 1
fi
[[ "$CALLED" -eq 0 ]] || { echo 'ERROR: kptools ran after missing -A value' >&2; exit 1; }

CALLED=0
if run_patchnest_kptools_patch -A '"unterminated'; then
    echo 'ERROR: mismatched WebUI quoting was accepted' >&2
    exit 1
fi
[[ "$CALLED" -eq 0 ]] || { echo 'ERROR: kptools ran after mismatched quoting' >&2; exit 1; }

CALLED=0
control_value=$'"line\nbreak"'
if run_patchnest_kptools_patch -A "$control_value"; then
    echo 'ERROR: control-bearing -A value was accepted' >&2
    exit 1
fi
[[ "$CALLED" -eq 0 ]] || { echo 'ERROR: kptools ran after control-bearing value' >&2; exit 1; }

CALLED=0
oversized="\"$(printf '%04100d' 0)\""
if run_patchnest_kptools_patch -A "$oversized"; then
    echo 'ERROR: oversized -A value was accepted' >&2
    exit 1
fi
[[ "$CALLED" -eq 0 ]] || { echo 'ERROR: kptools ran after oversized value' >&2; exit 1; }

printf '%s\n' 'kptools argv normalization tests passed.'
