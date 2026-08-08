#!/system/bin/sh
# Controlled FR-014 test trigger. This script never writes the boot partition.
# It only arms the same bootloop request that post-fs-data.sh would create after
# three failed boots. service.sh performs the actual transaction-bound restore.

set -eu
MODDIR=${0%/*}
PNDIR=${PATCHNEST_STATE_DIR:-/data/adb/patchnest}

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "! root shell required" >&2; exit 1; }
[ "${PATCHNEST_DEVICE_TEST_UNLOCK:-}" = "AUTO_RECOVERY" ] || {
    echo "! Refusing to arm automatic rollback without:" >&2
    echo "! PATCHNEST_DEVICE_TEST_UNLOCK=AUTO_RECOVERY" >&2
    exit 2
}

[ -x "$MODDIR/device_validation.sh" ] || { echo "! device_validation.sh missing" >&2; exit 1; }
[ ! -e "$PNDIR/transaction.pending.json" ] || { echo "! unfinished transaction exists" >&2; exit 1; }
[ ! -e "$PNDIR/flash_recovery_required" ] || { echo "! recovery is already required" >&2; exit 1; }

# Prove that a live exact rollback is eligible before arming the bootloop path.
sh "$MODDIR/device_validation.sh" rollback-check || {
    echo "! rollback is not eligible; auto-recovery test not armed" >&2
    exit 1
}

mkdir -p "$PNDIR"
printf '3\n' > "$PNDIR/boot_count"
touch "$PNDIR/autorecovery_active" "$PNDIR/auto_unpatch_requested"
sync

echo "AUTO_RECOVERY_ARMED"
echo "Reboot once. PatchNest service must restore the transaction-bound backup"
echo "and request a second reboot. After the device reaches Android again, run:"
echo "  sh $MODDIR/verify_auto_recovery.sh"
