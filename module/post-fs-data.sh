#!/system/bin/sh
# Early boot counter / automatic recovery arming.
set -eu

MODDIR=${0%/*}
SERVICE_D="/data/adb/service.d"
STATUS_SH="$SERVICE_D/patchnest.sh"
PNDIR="/data/adb/patchnest"
BOOT_COUNT_FILE="$PNDIR/boot_count"
AUTORECOVERY_MARKER="$PNDIR/autorecovery_active"

mkdir -p "$SERVICE_D" "$PNDIR"
cp "$MODDIR/status.sh" "$STATUS_SH"
chmod 755 "$STATUS_SH"

# A dedicated FR-014 candidate is intentionally installed before the first
# PatchNest boot mutation so preflight/recovery export can run against the stock
# target. In that state there is no patched kernel to recover and counting the
# normal stock boot as a PatchNest boot failure would create a false bootloop.
# Once any durable patch/credential/transaction evidence exists, normal recovery
# counting becomes mandatory again.
fr014_prepatch_idle() {
    [ -f "$MODDIR/FR014_DEVICE_CANDIDATE" ] || return 1
    for _pn_evidence in \
        rollback_binding.json \
        transaction.pending.json \
        flash_recovery_required \
        superkey \
        superkey.pending \
        last_flash.json; do
        [ ! -e "$PNDIR/$_pn_evidence" ] || return 1
    done
    return 0
}

if fr014_prepatch_idle; then
    printf '%s\n' 0 > "$BOOT_COUNT_FILE"
    rm -f "$AUTORECOVERY_MARKER" "$PNDIR/auto_unpatch_requested"
    exit 0
fi

# ============================================================
# Bootloop Auto-Recovery counter
# - Increments on every post-fs-data.sh run after PatchNest has durable
#   evidence that a destructive candidate transaction has begun/committed.
# - If counter reaches >= 3 consecutive failed boots, service.sh performs the
#   exact transaction-bound restore before normal runtime mutations.
# ============================================================
current_count=0
if [ -f "$BOOT_COUNT_FILE" ]; then
    current_count=$(printf '%s' "$(cat "$BOOT_COUNT_FILE" 2>/dev/null || true)" | tr -cd '0-9' | head -c 6)
    [ -n "$current_count" ] || current_count=0
fi

if [ "$current_count" -ge 3 ] 2>/dev/null; then
    touch "$AUTORECOVERY_MARKER"
    touch "$PNDIR/auto_unpatch_requested"
else
    current_count=$((current_count + 1))
    echo "$current_count" > "$BOOT_COUNT_FILE"
    if [ "$current_count" -ge 3 ]; then
        touch "$AUTORECOVERY_MARKER"
        touch "$PNDIR/auto_unpatch_requested"
    else
        rm -f "$AUTORECOVERY_MARKER" "$PNDIR/auto_unpatch_requested"
    fi
fi
