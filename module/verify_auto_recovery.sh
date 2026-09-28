#!/system/bin/sh
# FR-014 automatic bootloop-recovery verifier.

set -eu
MODDIR=${0%/*}
PNDIR=${PATCHNEST_STATE_DIR:-/data/adb/patchnest}

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "! root shell required" >&2; exit 1; }
[ -x "$MODDIR/device_validation.sh" ] || { echo "! device_validation.sh missing" >&2; exit 1; }
[ -e "$PNDIR/auto_recovery_restored" ] || {
    echo "! automatic rollback evidence marker is missing" >&2
    exit 1
}

sh "$MODDIR/device_validation.sh" postrestore

[ ! -e "$PNDIR/auto_unpatch_requested" ] || {
    echo "! auto-unpatch request is still armed after recovery" >&2
    exit 1
}
[ ! -e "$PNDIR/rollback_binding.json" ] || {
    echo "! rollback authorization still exists after automatic restore" >&2
    exit 1
}

printf '%s\n' "AUTO_RECOVERY_VERIFIED"
