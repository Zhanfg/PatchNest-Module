#!/system/bin/sh
#
# KPM ZIP Installer
# Usage: install_kpm.sh <path_to_zip>
#
# KPM ZIP format:
#   module.prop          # metadata (required)
#   xxx.kpm              # compiled binary (for binary modules)
#   xxx.c                # OR source code (for source modules)
#   config.json          # optional: event/args defaults
#
# module.prop format:
#   id=my_module
#   name=My Module
#   version=1.0.0
#   versionCode=100
#   author=me
#   description=A test module
#   event=BOOT_COMPLETED,POST_FS_DATA
#   args=--option1
#   autoLoad=true
#

MODDIR=${0%/*}
KPNDIR="/data/adb/kp-next"
KPM_DIR="$KPNDIR/kpm"
KPM_ZIP_DIR="$KPNDIR/kpm_zips"
KPM_EVENT_DIR="$KPNDIR/kpm_events"
LOG="$KPNDIR/service.log"
PATH="$MODDIR/bin:$PATH"

log() {
    echo "[$(date)] install_kpm: $1" >> "$LOG"
    echo "- $1"
}

# Read a key from module.prop
get_prop() {
    local file="$1" key="$2"
    grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2-
}

ZIP_FILE="$1"
if [ -z "$ZIP_FILE" ] || [ ! -f "$ZIP_FILE" ]; then
    echo "! Usage: install_kpm.sh <path_to_zip>"
    exit 1
fi

# Create temp extraction dir
TMPDIR=$(mktemp -d /data/local/tmp/kpm_install.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Extract zip
echo "- Extracting $ZIP_FILE..."
unzip -o "$ZIP_FILE" -d "$TMPDIR" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "! Failed to extract ZIP"
    exit 1
fi

# Validate module.prop
if [ ! -f "$TMPDIR/module.prop" ]; then
    echo "! No module.prop found in ZIP"
    exit 1
fi

# Read metadata
MOD_ID=$(get_prop "$TMPDIR/module.prop" "id")
MOD_NAME=$(get_prop "$TMPDIR/module.prop" "name")
MOD_VERSION=$(get_prop "$TMPDIR/module.prop" "version")
MOD_AUTHOR=$(get_prop "$TMPDIR/module.prop" "author")
MOD_DESC=$(get_prop "$TMPDIR/module.prop" "description")
MOD_EVENT=$(get_prop "$TMPDIR/module.prop" "event")
MOD_ARGS=$(get_prop "$TMPDIR/module.prop" "args")
MOD_AUTOLOAD=$(get_prop "$TMPDIR/module.prop" "autoLoad")

# Defaults
MOD_ID="${MOD_ID:-unknown}"
MOD_NAME="${MOD_NAME:-$MOD_ID}"
MOD_VERSION="${MOD_VERSION:-0.0.0}"
MOD_AUTOLOAD="${MOD_AUTOLOAD:-true}"

if [ -z "$MOD_ID" ] || [ "$MOD_ID" = "unknown" ]; then
    # Generate ID from filename
    MOD_ID=$(basename "$ZIP_FILE" .zip | tr ' ' '_')
fi

log "Installing KPM: $MOD_NAME ($MOD_ID) v$MOD_VERSION"

# Create directories
mkdir -p "$KPM_DIR" "$KPM_ZIP_DIR" "$KPM_EVENT_DIR"

# Check for source files (.c)
SRC_FILES=$(find "$TMPDIR" -name "*.c" -type f 2>/dev/null)
KPM_FILES=$(find "$TMPDIR" -name "*.kpm" -o -name "*.ko" -o -name "*.o" 2>/dev/null | grep -v '__MACOSX')

if [ -n "$KPM_FILES" ]; then
    # Binary module: copy .kpm/.ko/.o directly
    KPM_FILE=$(echo "$KPM_FILES" | head -1)
    KPM_BASENAME=$(basename "$KPM_FILE")
    cp "$KPM_FILE" "$KPM_DIR/${MOD_ID}.kpm"
    log "Binary module installed: $KPM_DIR/${MOD_ID}.kpm"
elif [ -n "$SRC_FILES" ]; then
    # Source module: needs compilation
    COMPILE_SCRIPT="$MODDIR/compile_kpm.sh"
    if [ -x "$COMPILE_SCRIPT" ]; then
        echo "- Compiling source module..."
        "$COMPILE_SCRIPT" "$TMPDIR" "$KPM_DIR/${MOD_ID}.kpm" "$MODDIR"
        if [ $? -ne 0 ]; then
            log "Compilation failed for $MOD_ID"
            echo "! Compilation failed"
            exit 1
        fi
        log "Source module compiled and installed"
    else
        # No compiler available, store source for later compilation
        mkdir -p "$KPNDIR/kpm_src"
        cp -r "$TMPDIR"/* "$KPNDIR/kpm_src/${MOD_ID}/"
        log "Source module stored (no compiler available): $KPNDIR/kpm_src/${MOD_ID}/"
        echo "- Source stored, compilation requires TCC compiler"
    fi
else
    echo "! No .kpm/.ko/.o or .c files found in ZIP"
    exit 1
fi

# Save ZIP for reference/updates
cp "$ZIP_FILE" "$KPM_ZIP_DIR/${MOD_ID}.zip"

# Save event config
if [ -n "$MOD_EVENT" ]; then
    echo "$MOD_EVENT" > "$KPM_EVENT_DIR/${MOD_ID}.events"
    log "Events registered: $MOD_EVENT"
fi

# Save args
if [ -n "$MOD_ARGS" ]; then
    echo "$MOD_ARGS" > "$KPM_EVENT_DIR/${MOD_ID}.args"
fi

# Save autoLoad flag
if [ "$MOD_AUTOLOAD" = "true" ]; then
    touch "$KPM_EVENT_DIR/${MOD_ID}.autoload"
fi

# Save full module.prop for reference
cp "$TMPDIR/module.prop" "$KPM_ZIP_DIR/${MOD_ID}.prop"

# Load module immediately if requested
if [ "$MOD_AUTOLOAD" = "true" ]; then
    echo "- Loading module..."
    ARGS_OPT=""
    if [ -n "$MOD_ARGS" ]; then
        ARGS_OPT="$MOD_ARGS"
    fi
    kpatch kpm load "$KPM_DIR/${MOD_ID}.kpm" $ARGS_OPT
    if [ $? -eq 0 ]; then
        log "Module $MOD_ID loaded successfully"
        echo "- Successfully installed and loaded: $MOD_NAME v$MOD_VERSION"
    else
        log "Module $MOD_ID load failed (will retry on boot)"
        echo "- Installed but load failed (will retry on boot): $MOD_NAME v$MOD_VERSION"
    fi
else
    echo "- Installed (auto-load disabled): $MOD_NAME v$MOD_VERSION"
fi
