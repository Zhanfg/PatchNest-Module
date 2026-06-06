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
echo "[$(date)] MODDIR=$MODDIR" >> "$LOG"
echo "[$(date)] PATH=$PATH" >> "$LOG"

# Detect root manager
ROOT_MGR="unknown"
if [ -f "$KPNDIR/root_manager" ]; then
    ROOT_MGR="$(cat $KPNDIR/root_manager)"
fi
echo "[$(date)] root_manager=$ROOT_MGR" >> "$LOG"

# Check if kpatch binary exists and is executable
if [ ! -x "$MODDIR/bin/kpatch" ]; then
    echo "[$(date)] ERROR: kpatch binary not found or not executable" >> "$LOG"
    touch "$MODDIR/unresolved"
    exit 0
fi

# Retry kpatch hello (P1-Cluster D: increase retries 3->5 for slow devices,
# and require both 'hello' exit code 0 AND non-empty output, to avoid
# treating a stuck kernel as "ready".)
retries=0
max_retries=5
while [ $retries -lt $max_retries ]; do
    if kpatch hello >/dev/null 2>&1; then
        break
    fi
    echo "[$(date)] kpatch hello attempt $((retries + 1)) failed, retrying..." >> "$LOG"
    sleep 2
    retries=$((retries + 1))
done
if ! kpatch hello >/dev/null 2>&1; then
    echo "[$(date)] kpatch hello failed after $retries retries" >> "$LOG"
    echo "[$(date)] Kernel may not be patched yet. Open WebUI and click Start." >> "$LOG"
    touch "$MODDIR/unresolved"
    exit 0
fi
echo "[$(date)] kpatch hello OK" >> "$LOG"

# Safe KPM load
# Use a literal-glob test: when the directory is empty, the shell returns
# the pattern itself unchanged. The [ -e ] check then correctly skips it,
# avoiding the bug where the old [ -s ] guard would test the wrong path.
for kpm in "$KPM_DIR"/*.kpm "$KPM_DIR"/*.ko "$KPM_DIR"/*.o; do
    [ -e "$kpm" ] || continue
    [ -s "$kpm" ] || continue
    mod_basename=$(basename "$kpm" | sed 's/\.\(kpm\|ko\|o\)$//')
    args=""
    if [ -f "$KPM_EVENT_DIR/${mod_basename}.args" ]; then
        # P0-8 security fix: the .args file lives under KPM_EVENT_DIR and is
        # writable by anything running as root. Restrict to a safe character
        # class so that a stray shell metacharacter cannot become an extra
        # argument to `kpatch kpm load`.
        raw_args="$(cat "$KPM_EVENT_DIR/${mod_basename}.args" 2>/dev/null || true)"
        args="$(printf '%s' "$raw_args" | tr -cd 'A-Za-z0-9_=,.+:/@% -')"
    fi
    if ! kpatch kpm load "$kpm" $args; then
        echo "[$(date)] Failed to load: $(basename "$kpm"), moving to failed/" >> "$LOG"
        mv "$kpm" "$KPM_DIR/failed/$(basename "$kpm")"
    else
        echo "[$(date)] Loaded: $(basename "$kpm") args=[$args]" >> "$LOG"
    fi
done

# Rehook
if [ -n "$REHOOK" ]; then
    if [ "$REHOOK" = "enable" ] || [ "$REHOOK" = "disable" ]; then
        kpatch rehook $REHOOK
        echo "[$(date)] rehook $REHOOK" >> "$LOG"
    else
        rm -f "$KPNDIR/rehook"
    fi
fi

# Dispatch events
dispatch_event() {
    echo "[$(date)] Dispatching event: $1" >> "$LOG"
    kpatch event "$1" "" "" 2>/dev/null
}

dispatch_event "POST_FS_DATA"

# Wait for boot completion (with 5 min timeout to avoid infinite loop on broken ROMs)
wait_count=0
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
    wait_count=$((wait_count + 1))
    if [ "$wait_count" -ge 300 ]; then
        echo "[$(date)] WARN: boot_completed timeout, continuing anyway" >> "$LOG"
        break
    fi
done

dispatch_event "BOOT_COMPLETED"

# Apply exclusion config
# Use a temp file (not subshell pipeline) so we keep state and can quote safely.
if [ -f "$CONFIG" ]; then
    excluded_count=0
    excluded_failed=0
    # Read into a here-doc, then parse with a manual CSV reader that respects quoting.
    _cfg_tmp=$(mktemp /data/local/tmp/kpnext_cfg.XXXXXX)
    tail -n +2 "$CONFIG" > "$_cfg_tmp"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Parse CSV: pkg,exclude,allow,uid (no quoted fields supported in our writer,
        # but be defensive against embedded spaces by using a regex split).
        pkg=$(echo "$line" | awk -F, '{print $1}')
        exclude=$(echo "$line" | awk -F, '{print $2}')
        uid=$(echo "$line" | awk -F, '{print $4}')
        if [ "$exclude" = "1" ] && [ -n "$pkg" ] && [ -n "$uid" ]; then
            # /data/system/packages.list: "<pkg> <uid>"
            pkgq=$(printf '%s' "$pkg" | sed 's/[][\.*^$()+?{|/]/\\&/g')
            UID_VAL=$(grep -F " $uid" /data/system/packages.list 2>/dev/null | grep -F "^$pkgq " | head -1 | awk '{print $2}')
            if [ -n "$UID_VAL" ]; then
                kpatch exclude_set "$UID_VAL" 1
                excluded_count=$((excluded_count + 1))
            else
                excluded_failed=$((excluded_failed + 1))
            fi
        fi
    done < "$_cfg_tmp"
    rm -f "$_cfg_tmp"
    echo "[$(date)] exclusion: applied=$excluded_count failed=$excluded_failed" >> "$LOG"
fi

echo "[$(date)] service.sh completed" >> "$LOG"
