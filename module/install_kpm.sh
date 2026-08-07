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

MODDIR=${0%/*}
PNDIR="/data/adb/patchnest"
KPM_DIR="$PNDIR/kpm"
KPM_ZIP_DIR="$PNDIR/kpm_zips"
KPM_EVENT_DIR="$PNDIR/kpm_events"
LOG="$PNDIR/service.log"
PATH="$MODDIR/bin:$PATH"

log() {
    echo "[$(date)] install_kpm: $1" >> "$LOG"
    echo "- $1"
}

get_prop() {
    local file="$1" key="$2"
    grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2-
}

ZIP_FILE="$1"
case "$ZIP_FILE" in
    "" | /*)
        echo "! install_kpm.sh: refusing to install with empty or absolute path: '$ZIP_FILE'" >&2
        exit 2
        ;;
    *..* | */./*)
        echo "! install_kpm.sh: refusing to install with path-traversal: '$ZIP_FILE'" >&2
        exit 2
        ;;
    *[!A-Za-z0-9._/+@%=-]*)
        echo "! install_kpm.sh: refusing to install with unsafe characters in zip filename: '$ZIP_FILE'" >&2
        exit 2
        ;;
esac
if [ ! -f "$ZIP_FILE" ]; then
    echo "! Usage: install_kpm.sh <path_to_zip>"
    exit 1
fi

TMPDIR=$(mktemp -d /data/local/tmp/kpm_install.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

echo "- Extracting $ZIP_FILE..."
unzip -o "$ZIP_FILE" -d "$TMPDIR" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "! Failed to extract ZIP"
    exit 1
fi

if [ ! -f "$TMPDIR/module.prop" ]; then
    echo "! No module.prop found in ZIP"
    exit 1
fi

MOD_ID=$(get_prop "$TMPDIR/module.prop" "id")
MOD_NAME=$(get_prop "$TMPDIR/module.prop" "name")
MOD_VERSION=$(get_prop "$TMPDIR/module.prop" "version")
MOD_AUTHOR=$(get_prop "$TMPDIR/module.prop" "author")
MOD_DESC=$(get_prop "$TMPDIR/module.prop" "description")
MOD_EVENT=$(get_prop "$TMPDIR/module.prop" "event")
MOD_ARGS=$(get_prop "$TMPDIR/module.prop" "args")
MOD_AUTOLOAD=$(get_prop "$TMPDIR/module.prop" "autoLoad")

MOD_ARGS="$(printf '%s' "$MOD_ARGS" | tr -cd 'A-Za-z0-9_=,.+:/@% -')"

MOD_ID="${MOD_ID:-unknown}"
MOD_NAME="${MOD_NAME:-$MOD_ID}"
MOD_VERSION="${MOD_VERSION:-0.0.0}"
MOD_AUTOLOAD="${MOD_AUTOLOAD:-true}"

if [ -z "$MOD_ID" ] || [ "$MOD_ID" = "unknown" ]; then
    MOD_ID=$(basename "$ZIP_FILE" .zip | tr ' ' '_')
fi

MOD_ID="$(printf '%s' "$MOD_ID" | tr -cd 'A-Za-z0-9_.-')"
MOD_NAME="$(printf '%s' "$MOD_NAME" | tr -cd 'A-Za-z0-9 _.-')"
MOD_VERSION="$(printf '%s' "$MOD_VERSION" | tr -cd 'A-Za-z0-9_.+-')"
MOD_AUTHOR="$(printf '%s' "$MOD_AUTHOR" | tr -cd 'A-Za-z0-9_@. -')"
MOD_EVENT="$(printf '%s' "$MOD_EVENT" | tr -cd 'A-Za-z0-9_,')"

if [ -z "$MOD_ID" ] || [ "${#MOD_ID}" -gt 64 ] || [ "$MOD_ID" = "." ] || [ "$MOD_ID" = ".." ]; then
    echo "! install_kpm.sh: refusing to install with unsafe id: '$MOD_ID'" >&2
    exit 2
fi

log "Installing KPM: $MOD_NAME ($MOD_ID) v$MOD_VERSION"
mkdir -p "$KPM_DIR" "$KPM_ZIP_DIR" "$KPM_EVENT_DIR"

SRC_FILES=$(find "$TMPDIR" -type f -name "*.c" \
    ! -name '._*' ! -name '.DS_Store' 2>/dev/null)
KPM_FILES=$(find "$TMPDIR" -type f \
    \( -name "*.kpm" -o -name "*.ko" -o -name "*.o" \) \
    ! -name '._*' ! -name '.DS_Store' 2>/dev/null)

if [ -n "$KPM_FILES" ]; then
    KPM_FILE=$(echo "$KPM_FILES" | head -1)
    KPM_BASENAME=$(basename "$KPM_FILE")
    cp "$KPM_FILE" "$KPM_DIR/${MOD_ID}.kpm"
    log "Binary module installed: $KPM_DIR/${MOD_ID}.kpm"

    _kpm_stem=$(printf '%s' "$KPM_BASENAME" | sed -E 's/\.(kpm|ko|o)$//')
    for _sig in "$TMPDIR/${_kpm_stem}.kpm.sig" \
                "$TMPDIR/${_kpm_stem}.sig" \
                "$TMPDIR/$(basename "$KPM_BASENAME" .kpm).kpm.sig" \
                "$TMPDIR/$(basename "$KPM_BASENAME" .kpm).sig"; do
        if [ -f "$_sig" ]; then
            cp "$_sig" "$KPM_DIR/${MOD_ID}.kpm.sig"
            log "Signature copied: $KPM_DIR/${MOD_ID}.kpm.sig"
            break
        fi
    done
elif [ -n "$SRC_FILES" ]; then
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
        mkdir -p "$PNDIR/kpm_src"
        mkdir -p "$PNDIR/kpm_src/${MOD_ID}"
        cp -r "$TMPDIR"/* "$PNDIR/kpm_src/${MOD_ID}/"
        log "Source module stored (no compiler available): $PNDIR/kpm_src/${MOD_ID}/"
        echo "- Source stored, compilation requires TCC compiler"
    fi
else
    echo "! No .kpm/.ko/.o or .c files found in ZIP"
    exit 1
fi

cp "$ZIP_FILE" "$KPM_ZIP_DIR/${MOD_ID}.zip"

if [ -n "$MOD_EVENT" ]; then
    echo "$MOD_EVENT" > "$KPM_EVENT_DIR/${MOD_ID}.events"
    log "Events registered: $MOD_EVENT"
fi

if [ -n "$MOD_ARGS" ]; then
    echo "$MOD_ARGS" > "$KPM_EVENT_DIR/${MOD_ID}.args"
fi

if [ "$MOD_AUTOLOAD" = "true" ]; then
    touch "$KPM_EVENT_DIR/${MOD_ID}.autoload"
fi

cp "$TMPDIR/module.prop" "$KPM_ZIP_DIR/${MOD_ID}.prop"

if [ "$MOD_AUTOLOAD" = "true" ]; then
    echo "- Loading module..."
    # PatchNest C CLI contract is `kpm load PATH [ARGS]`. Do not inject a
    # literal `--`; that token was previously delivered to the KPM as its args
    # while the real MOD_ARGS value was ignored.
    if [ -n "$MOD_ARGS" ]; then
        kpatch kpm load "$KPM_DIR/${MOD_ID}.kpm" "$MOD_ARGS" 2>&1
    else
        kpatch kpm load "$KPM_DIR/${MOD_ID}.kpm" 2>&1
    fi
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
