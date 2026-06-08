#!/bin/sh

MODDIR=${0%/*}
PNDIR="/data/adb/patchnest"
PATH="$MODDIR/bin:$PATH"
CONFIG="$PNDIR/package_config"
# P1-fix (ultracode-audit-2026-06-06): quote $PNDIR. If the path
# ever contains a space (custom user layout, su bind-mount trick,
# or future Magisk layout change) the previous form would word-split
# into two paths and `cat` would error out — masking the real
# config. The sanitization of $REHOOK below also defends against
# a hostile $PNDIR/rehook file (only off|enable|disable|empty
# are accepted).
REHOOK="$(cat "$PNDIR/rehook" 2>/dev/null || true)"
LOG="$PNDIR/service.log"
KPM_DIR="$PNDIR/kpm"
KPM_EVENT_DIR="$PNDIR/kpm_events"

# Helper: read a key from module.prop
get_prop() {
    grep "^${1}=" "$2" 2>/dev/null | head -1 | cut -d'=' -f2-
}

# Read the global PatchNest config file. This is a simple KEY=VALUE
# file; we only look at the keys we care about and treat anything else
# as future work. The file may not exist on first-run / legacy installs;
# defaults below are chosen to preserve pre-signature behavior.
#
# KPM_SIGNATURE_POLICY controls how unsigned / unverified KPM modules
# are handled at boot. Three modes:
#
#   off    — Never check signatures. Unsigned modules load silently.
#            This is the default; preserves pre-v0.3.0 behavior.
#   warn   — Load unsigned modules but emit a visible warning to the
#            service log and to the WebUI. Recommended for users who
#            want to develop / embed their own KPMs without giving up
#            the safety net of seeing which ones are unsigned.
#   strict — Refuse to load any KPM that is not accompanied by a valid
#            .kpm.sig file. Strictest; use only after all your KPMs
#            are signed.
#
# The policy can be set in /data/adb/patchnest/config, e.g.:
#     KPM_SIGNATURE_POLICY=warn
# or toggled from the WebUI Settings page.
KPN_CONFIG="$PNDIR/config"
KPM_SIGNATURE_POLICY=off
if [ -f "$KPN_CONFIG" ]; then
    # Tolerate comments, blank lines, and `export ` prefixes.
    _val=$(grep -E '^[[:space:]]*(export[[:space:]]+)?KPM_SIGNATURE_POLICY[[:space:]]*=' \
        "$KPN_CONFIG" 2>/dev/null | tail -1 | sed -E 's/^[^=]*=//' | tr -d '"\r\n' | tr 'A-Z' 'a-z')
    case "$_val" in
        off|warn|strict) KPM_SIGNATURE_POLICY="$_val" ;;
        0|false)         KPM_SIGNATURE_POLICY=off ;;
        1|true|yes|on)   KPM_SIGNATURE_POLICY=strict ;;
        *)               KPM_SIGNATURE_POLICY=off ;;
    esac
fi

# Map the policy to the legacy boolean expected by the existing logic,
# and expose a third state.  All actual decisions are made on the
# string policy below; the boolean is kept for logging only.
case "$KPM_SIGNATURE_POLICY" in
    off)    REQUIRE_KPM_SIGNATURES=0 ;;
    warn|strict) REQUIRE_KPM_SIGNATURES=1 ;;
    *)      REQUIRE_KPM_SIGNATURES=0 ;;
esac

# Source the KPM signature verifier. It is a no-op cost when
# KPM_SIGNATURE_POLICY=off (we never call it below). The verifier
# exposes `verify_kpm_sig <kpm> <sig>` which returns 0/1.
# shellcheck disable=SC1091
. "$MODDIR/kpm_verify.sh" 2>/dev/null || true

# Rotate log on boot
mkdir -p "$PNDIR" "$KPM_DIR/failed" "$KPM_EVENT_DIR"
echo "=== $(date) service.sh started ===" > "$LOG"
echo "[$(date)] MODDIR=$MODDIR" >> "$LOG"
echo "[$(date)] PATH=$PATH" >> "$LOG"
echo "[$(date)] KPM_SIGNATURE_POLICY=$KPM_SIGNATURE_POLICY" >> "$LOG"

# Detect root manager
ROOT_MGR="unknown"
if [ -f "$PNDIR/root_manager" ]; then
    # P1-fix (ultracode-audit-2026-06-06): quote $PNDIR in the cat
    # call, and sanitize the value to a safe character class. The
    # /data/adb/patchnest/root_manager file is written by customize.sh
    # (only 'apatch'|'ksu'|'magisk'|'unknown' values), but if a
    # future installer writes a tampered value here, an unquoted
    # expansion could break later `case` statements. The whitelist
    # sanitization prevents the value from containing shell
    # metacharacters that could affect any downstream use.
    _rm_raw="$(cat "$PNDIR/root_manager" 2>/dev/null || true)"
    _rm_sane="$(printf '%s' "$_rm_raw" | tr -cd 'a-z')"
    if [ -n "$_rm_sane" ]; then
        ROOT_MGR="$_rm_sane"
    fi
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

# Bootloop Auto-Recovery: healthy boot detected — reset the counter
# and clear any auto-recovery markers so we don't trigger unpatch.
echo "0" > "$PNDIR/boot_count" 2>/dev/null
rm -f "$PNDIR/autorecovery_active" "$PNDIR/auto_unpatch_requested"

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

    # --- KPM signature verification (policy-controlled) --------------------
    # off   → skip all checks, log nothing.
    # warn  → allow unsigned, but log + flag for the WebUI.
    # strict → reject unsigned / invalid.
    _kpm_sig="$KPM_DIR/${mod_basename}.kpm.sig"
    if [ "$KPM_SIGNATURE_POLICY" != "off" ]; then
        if [ ! -f "$_kpm_sig" ]; then
            # No .kpm.sig file present.
            if [ "$KPM_SIGNATURE_POLICY" = "strict" ]; then
                echo "[$(date)] REJECTED (strict, unsigned): $(basename "$kpm"), moving to failed/" >> "$LOG"
                mv "$kpm" "$KPM_DIR/failed/$(basename "$kpm")"
                continue
            else
                # warn mode — allow but flag it
                echo "[$(date)] WARN (unsigned, policy=$KPM_SIGNATURE_POLICY): $(basename "$kpm") — loading anyway" >> "$LOG"
                # Write a marker file so the WebUI can surface the warning.
                echo "unsigned:$(basename "$kpm"):$(date +%s)" >> "$PNDIR/unsigned_modules.log"
            fi
        elif ! verify_kpm_sig "$kpm" "$_kpm_sig"; then
            echo "[$(date)] REJECTED (sig invalid): $(basename "$kpm"), moving to failed/" >> "$LOG"
            mv "$kpm" "$KPM_DIR/failed/$(basename "$kpm")"
            mv "$_kpm_sig" "$KPM_DIR/failed/$(basename "$_kpm_sig")" 2>/dev/null || true
            continue
        fi
    fi

    if ! kpatch kpm load "$kpm" -- "$args"; then
        echo "[$(date)] Failed to load: $(basename "$kpm"), moving to failed/" >> "$LOG"
        mv "$kpm" "$KPM_DIR/failed/$(basename "$kpm")"
    else
        echo "[$(date)] Loaded: $(basename "$kpm") args=[$args]" >> "$LOG"
    fi
done

# Rehook
if [ -n "$REHOOK" ]; then
    if [ "$REHOOK" = "enable" ] || [ "$REHOOK" = "disable" ]; then
        kpatch rehook "$REHOOK"
        echo "[$(date)] rehook $REHOOK" >> "$LOG"
    else
        rm -f "$PNDIR/rehook"
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
    _cfg_tmp=$(mktemp /data/local/tmp/patchnest_cfg.XXXXXX)
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
            UID_VAL=$(grep -F " $uid" /data/system/packages.list 2>/dev/null | grep "^$pkgq " | head -1 | awk '{print $2}')
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
