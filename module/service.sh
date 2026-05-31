#!/bin/sh

MODDIR=${0%/*}
KPNDIR="/data/adb/kp-next"
PATH="$MODDIR/bin:$PATH"
CONFIG="$KPNDIR/package_config"
REHOOK="$(cat $KPNDIR/rehook 2>/dev/null)"
LOG="$KPNDIR/service.log"
KPM_DIR="$KPNDIR/kpm"
KPM_EVENT_DIR="$KPNDIR/kpm_events"

# Helper: read a key from module.prop
get_prop() {
    grep "^${1}=" "$2" 2>/dev/null | head -1 | cut -d'=' -f2-
}

# Rotate log on boot
mkdir -p "$KPNDIR" "$KPM_DIR/failed" "$KPM_EVENT_DIR"
echo "=== $(date) service.sh started ===" > "$LOG"

# Retry kpatch hello
retries=0
while [ -z "$(kpatch hello)" ] && [ $retries -lt 3 ]; do
    echo "[$(date)] kpatch hello attempt $((retries + 1)) failed, retrying..." >> "$LOG"
    sleep 2
    retries=$((retries + 1))
done
if [ -z "$(kpatch hello)" ]; then
    echo "[$(date)] kpatch hello failed after $retries retries" >> "$LOG"
    touch "$MODDIR/unresolved"
    exit 0
fi
echo "[$(date)] kpatch hello OK" >> "$LOG"

# ============================================================
# Load KPM modules (.kpm, .ko, .o)
# For each module, check module.prop for event/args/autoLoad
# ============================================================
load_kpm_module() {
    local kpm_file="$1"
    local mod_basename=$(basename "$kpm_file" | sed 's/\.\(kpm\|ko\|o\)$//')
    local prop_file="$KPM_EVENT_DIR/${mod_basename}.args"
    local args=""

    # Read args from saved config
    if [ -f "$KPM_EVENT_DIR/${mod_basename}.args" ]; then
        args="$(cat "$KPM_EVENT_DIR/${mod_basename}.args")"
    fi

    if ! kpatch kpm load "$kpm_file" $args; then
        echo "[$(date)] Failed to load: $(basename "$kpm_file"), moving to failed/" >> "$LOG"
        mv "$kpm_file" "$KPM_DIR/failed/$(basename "$kpm_file")"
    else
        echo "[$(date)] Loaded: $(basename "$kpm_file") args=[$args]" >> "$LOG"
    fi
}

# Load all KPM files in kpm directory
for kpm in "$KPM_DIR"/*.kpm "$KPM_DIR"/*.ko "$KPM_DIR"/*.o; do
    [ -s "$kpm" ] || continue
    load_kpm_module "$kpm"
done

# ============================================================
# Rehook configuration
# ============================================================
if [ -n "$REHOOK" ]; then
    if [ "$REHOOK" = "enable" ] || [ "$REHOOK" = "disable" ]; then
        kpatch rehook $REHOOK
        echo "[$(date)] rehook $REHOOK" >> "$LOG"
    else
        rm -f "$KPNDIR/rehook"
    fi
fi

# ============================================================
# Dispatch events to loaded KPM modules
# ============================================================
dispatch_event() {
    local event_name="$1"
    echo "[$(date)] Dispatching event: $event_name" >> "$LOG"
    kpatch event "$event_name" "" "" 2>/dev/null
}

# Dispatch POST_FS_DATA event
dispatch_event "POST_FS_DATA"

# ============================================================
# Wait for boot completion
# ============================================================
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
done

# Dispatch BOOT_COMPLETED event
dispatch_event "BOOT_COMPLETED"

# ============================================================
# Apply package exclusion config
# ============================================================
if [ -f "$CONFIG" ]; then
    tail -n +2 "$CONFIG" | while IFS=, read -r pkg exclude allow uid; do
        if [ "$exclude" = "1" ]; then
            UID=$(grep "^$pkg $uid" /data/system/packages.list | cut -d' ' -f2)
            [ -z "$UID" ] && UID=$(grep "^$pkg " /data/system/packages.list | cut -d' ' -f2)
            [ -n "$UID" ] && kpatch exclude_set "$UID" 1
        fi
    done
fi

echo "[$(date)] service.sh completed" >> "$LOG"
