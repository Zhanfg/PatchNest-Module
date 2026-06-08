#!/system/bin/sh
# P1-fix (ultracode-audit-2026-06-06): enable strict error handling
# so an unexpected error in early boot doesn't silently disable
# bootloop recovery. Combined with the explicit quoting below,
# this means a corrupted $BOOT_COUNT_FILE can never reach an `eval`
# or cause a missing var to silently become '0' in the wrong way.
set -eu

MODDIR=${0%/*}
SERVICE_D="/data/adb/service.d"
STATUS_SH="$SERVICE_D/patchnest.sh"
PNDIR="/data/adb/patchnest"
BOOT_COUNT_FILE="$PNDIR/boot_count"
AUTORECOVERY_MARKER="$PNDIR/autorecovery_active"

# Ensure the directories exist BEFORE trying to write into them.
# mkdir -p on a missing parent path can otherwise create weird
# intermediate state if the script is interrupted mid-boot.
mkdir -p "$SERVICE_D" "$PNDIR"
cp "$MODDIR/status.sh" "$STATUS_SH"
chmod 755 "$STATUS_SH"

# ============================================================
# Bootloop Auto-Recovery counter
# - Increments on every post-fs-data.sh run.
# - If counter reaches >= 3 consecutive failed boots, do NOT
#   increment further; instead signal auto-unpatch by leaving
#   the marker file. service.sh will reset it on a healthy boot.
# ============================================================
current_count=0
if [ -f "$BOOT_COUNT_FILE" ]; then
    # P1-fix: read with a fd and strip everything that isn't a digit.
    # The `printf '%s'` (vs `echo`) prevents backslash interpretation
    # in shells that treat echo as a builtin with -e semantics.
    current_count=$(printf '%s' "$(cat "$BOOT_COUNT_FILE" 2>/dev/null || true)" | tr -cd '0-9' | head -c 6)
    [ -n "$current_count" ] || current_count=0
fi

if [ "$current_count" -ge 3 ] 2>/dev/null; then
    # Bootloop detected — signal auto-unpatch. Counter stays at 3
    # so we never miss the signal until service.sh clears it.
    touch "$AUTORECOVERY_MARKER"
    # Mark auto-unpatch request for boot_unpatch.sh consumers (e.g. WebUI action).
    touch "$PNDIR/auto_unpatch_requested"
else
    current_count=$((current_count + 1))
    echo "$current_count" > "$BOOT_COUNT_FILE"
    # If we just transitioned into the danger zone this boot, surface it.
    if [ "$current_count" -ge 3 ]; then
        touch "$AUTORECOVERY_MARKER"
        touch "$PNDIR/auto_unpatch_requested"
    else
        rm -f "$AUTORECOVERY_MARKER" "$PNDIR/auto_unpatch_requested"
    fi
fi
