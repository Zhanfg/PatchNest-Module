#!/system/bin/sh
# PatchNest early-boot recovery state tracker.
#
# This script does not flash or restore a boot image. It only records that the
# configured failed-boot threshold has been reached. A later recovery executor
# must still select and verify a target-bound backup before any write.

set -eu
umask 077

MODDIR=${0%/*}
SERVICE_D="/data/adb/service.d"
STATUS_SH="$SERVICE_D/patchnest.sh"
PNDIR="/data/adb/patchnest"
BOOT_COUNT_FILE="$PNDIR/boot_count"
RECOVERY_MARKER="$PNDIR/autorecovery_active"
RECOVERY_REQUEST="$PNDIR/auto_unpatch_requested"
RECOVERY_STATE="$PNDIR/recovery_state.json"
THRESHOLD=3

mkdir -p "$SERVICE_D" "$PNDIR"
if cp "$MODDIR/status.sh" "$STATUS_SH"; then
  chmod 755 "$STATUS_SH"
fi

current_count=0
if [ -f "$BOOT_COUNT_FILE" ]; then
  current_count=$(printf '%s' "$(cat "$BOOT_COUNT_FILE" 2>/dev/null || true)" \
    | tr -cd '0-9' | head -c 6)
  [ -n "$current_count" ] || current_count=0
fi

case "$current_count" in
  *[!0-9]*|'') current_count=0 ;;
esac

if [ "$current_count" -lt "$THRESHOLD" ]; then
  current_count=$((current_count + 1))
fi
printf '%s\n' "$current_count" >"$BOOT_COUNT_FILE"

requested=false
if [ "$current_count" -ge "$THRESHOLD" ]; then
  requested=true
  : >"$RECOVERY_MARKER"
  : >"$RECOVERY_REQUEST"
else
  rm -f "$RECOVERY_MARKER" "$RECOVERY_REQUEST"
fi

requested_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
state_tmp="${RECOVERY_STATE}.tmp.$$"
cat >"$state_tmp" <<EOF
{
  "schema_version": 1,
  "boot_count": $current_count,
  "threshold": $THRESHOLD,
  "recovery_requested": $requested,
  "requested_at": "$requested_at",
  "automatic_flash_performed": false,
  "required_next_step": "select_target_bound_verified_backup"
}
EOF
mv "$state_tmp" "$RECOVERY_STATE"

exit 0
