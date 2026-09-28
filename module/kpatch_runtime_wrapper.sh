#!/system/bin/sh
# Runtime guard for the packaged Public1158 kpatch CLI.
# All normal commands are delegated unchanged. Only `kpm load` receives an
# additional fail-closed userspace admission check before entering the kernel.

set -u

BINDIR=${0%/*}
MODDIR=${BINDIR%/bin}
REAL="$BINDIR/kpatch.real"

[ -x "$REAL" ] || {
    printf '%s\n' "! kpatch.real is missing or not executable" >&2
    exit 127
}

if [ "${1:-}" = "kpm" ] && [ "${2:-}" = "load" ]; then
    KPM_FILE=${3:-}
    [ -n "$KPM_FILE" ] || {
        printf '%s\n' "! kpatch kpm load requires a module path" >&2
        exit 2
    }
    [ -x "$MODDIR/validate_kpm_file.sh" ] || {
        printf '%s\n' "! KPM admission helper is missing" >&2
        exit 3
    }
    PATH="$BINDIR:$PATH" "$MODDIR/validate_kpm_file.sh" "$KPM_FILE" || exit $?
fi

exec "$REAL" "$@"
