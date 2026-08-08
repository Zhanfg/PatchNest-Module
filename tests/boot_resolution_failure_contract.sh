#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PATCH="$TMP/patch"
mkdir -p "$PATCH"
cp "$ROOT/module/patch/util_functions.sh" "$PATCH/util_functions.sh"
cp "$ROOT/module/patch/flash_safety.sh" "$PATCH/flash_safety.sh"
printf '%s\n' KEEP > "$PATCH/recovery-helper.sentinel"

(
    MODPATH="$PATCH"
    BOOTMODE=true
    OUTFD=1
    TMPDIR="$TMP/disposable"
    mkdir -p "$TMPDIR"
    export MODPATH BOOTMODE OUTFD TMPDIR
    # shellcheck disable=SC1090
    . "$PATCH/util_functions.sh"
    # shellcheck disable=SC1090
    . "$PATCH/flash_safety.sh"

    # Force the reviewed resolver into a hard failure without touching any real
    # /dev node. A failure must be a normal non-zero result and must never call
    # the upstream installer cleanup that deletes MODPATH.
    find_block() { return 1; }
    SLOT='_invalid'
    if find_boot_image >/dev/null 2>&1; then
        echo "boot resolution failure contract: FAIL: invalid slot accepted" >&2
        exit 1
    fi
    [ -d "$PATCH" ] || { echo "boot resolution failure contract: FAIL: patch directory deleted" >&2; exit 1; }
    [ -f "$PATCH/recovery-helper.sentinel" ] || { echo "boot resolution failure contract: FAIL: recovery sentinel deleted" >&2; exit 1; }
)

# The runtime abort override must still terminate its caller but must not run
# the imported installer cleanup that recursively removes MODPATH.
set +e
(
    MODPATH="$PATCH"
    BOOTMODE=true
    OUTFD=1
    TMPDIR="$TMP/disposable-abort"
    mkdir -p "$TMPDIR"
    export MODPATH BOOTMODE OUTFD TMPDIR
    # shellcheck disable=SC1090
    . "$PATCH/util_functions.sh"
    # shellcheck disable=SC1090
    . "$PATCH/flash_safety.sh"
    abort '! synthetic runtime abort'
    exit 0
) >/dev/null 2>&1
abort_rc=$?
set -e
[ "$abort_rc" -ne 0 ] || { echo "boot resolution failure contract: FAIL: abort did not terminate" >&2; exit 1; }

[ -d "$PATCH" ] || { echo "boot resolution failure contract: FAIL: helper tree missing after failure" >&2; exit 1; }
[ -f "$PATCH/recovery-helper.sentinel" ] || { echo "boot resolution failure contract: FAIL: sentinel missing after failure" >&2; exit 1; }

echo "boot resolution failure contract: PASS"
