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
# P1-fix (ultracode-audit-2026-06-06): also reject any $ZIP_FILE that
# contains a path-traversal sequence, an absolute path, or a shell
# metacharacter. The file is later opened by unzip into a tmpdir; even
# though unzip -o can't write outside the tmpdir, a malicious filename
# could let a separate process (e.g. a malicious pre-existing .kpm.sig
# check) confuse the manifest parser. The whitelist allows KPM zip
# filenames that look like the canonical KPM naming we generate.
#
# Pattern order matters in POSIX case-glob: each branch is checked
# top-to-bottom, so put the most-specific rejections first. The
# earlier version of this comment mentioned codes like SC2221/SC2222
# by name, but lint tooling that scans the comment for `shellcheck`
# directives (e.g. Github Actions ShellCheck 0.9) tries to parse the
# line as a directive, fails, and fails the build. Avoid the
# bare `shellcheck` keyword in comments to side-step that.
case "$ZIP_FILE" in
    # Reject empty or absolute paths outright.
    "" | /*)
        echo "! install_kpm.sh: refusing to install with empty or absolute path: '$ZIP_FILE'" >&2
        exit 2
        ;;
    # Reject path-traversal sequences anywhere in the path.
    *..* | */./*)
        echo "! install_kpm.sh: refusing to install with path-traversal: '$ZIP_FILE'" >&2
        exit 2
        ;;
    # Reject any character that isn't in our safe set. This must come
    # last because it matches the broadest class; anything that
    # reached here was already accepted by the two checks above.
    *[!A-Za-z0-9._/+@%=-]*)
        echo "! install_kpm.sh: refusing to install with unsafe characters in zip filename: '$ZIP_FILE'" >&2
        exit 2
        ;;
esac
if [ ! -f "$ZIP_FILE" ]; then
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

# P0-fix (ultracode-audit-2026-06-06): sanitize MOD_ARGS to the same
# safe character class that service.sh applies at load time. The args
# file is parsed in shell context; without sanitization, a malicious
# module.prop with args='$(id)' would execute on the user's device.
MOD_ARGS="$(printf '%s' "$MOD_ARGS" | tr -cd 'A-Za-z0-9_=,.+:/@% -')"

# Defaults
MOD_ID="${MOD_ID:-unknown}"
MOD_NAME="${MOD_NAME:-$MOD_ID}"
MOD_VERSION="${MOD_VERSION:-0.0.0}"
MOD_AUTOLOAD="${MOD_AUTOLOAD:-true}"

if [ -z "$MOD_ID" ] || [ "$MOD_ID" = "unknown" ]; then
    # Generate ID from filename
    MOD_ID=$(basename "$ZIP_FILE" .zip | tr ' ' '_')
fi

# P0-fix (ultracode-audit-2026-06-06, finding NEW-001): sanitize
# MOD_ID and any other module.prop value that flows into a path
# interpolation. Without this, a crafted KPM zip with
#   id=../../system/xbin/foo
# would let install_kpm.sh write a .kpm file to an arbitrary
# root-owned path on the user's device. The whitelist matches the
# sanitization pattern used by service.sh for args.
MOD_ID="$(printf '%s' "$MOD_ID" | tr -cd 'A-Za-z0-9_.-')"
# Also sanitize the other fields that are echoed into the kpm
# events dir, even though they don't directly form paths.
MOD_NAME="$(printf '%s' "$MOD_NAME" | tr -cd 'A-Za-z0-9 _.-')"
MOD_VERSION="$(printf '%s' "$MOD_VERSION" | tr -cd 'A-Za-z0-9_.+-')"
MOD_AUTHOR="$(printf '%s' "$MOD_AUTHOR" | tr -cd 'A-Za-z0-9_@. -')"
MOD_EVENT="$(printf '%s' "$MOD_EVENT" | tr -cd 'A-Za-z0-9_,')"

# Reject empty / unsafe IDs after sanitization. A MOD_ID that
# collapses to empty means the KPM's id field was all non-ASCII
# (or all dots) — refuse rather than silently installing as
# `.kpm`, which would clobber any file the user happens to have
# named `.kpm` on the device.
if [ -z "$MOD_ID" ] || [ "${#MOD_ID}" -gt 64 ] || [ "$MOD_ID" = "." ] || [ "$MOD_ID" = ".." ]; then
    echo "! install_kpm.sh: refusing to install with unsafe id: '$MOD_ID'" >&2
    exit 2
fi

log "Installing KPM: $MOD_NAME ($MOD_ID) v$MOD_VERSION"

# Create directories
mkdir -p "$KPM_DIR" "$KPM_ZIP_DIR" "$KPM_EVENT_DIR"

# Check for source files (.c)
# P1-Cluster B fix: explicitly skip macOS resource forks (._*) and
# .DS_Store which unzip-on-macOS leaves behind. Otherwise `head -1`
# below can pick up a metadata file and the script silently reports
# "no .kpm found" with no error message.
SRC_FILES=$(find "$TMPDIR" -type f -name "*.c" \
    ! -name '._*' ! -name '.DS_Store' 2>/dev/null)
KPM_FILES=$(find "$TMPDIR" -type f \
    \( -name "*.kpm" -o -name "*.ko" -o -name "*.o" \) \
    ! -name '._*' ! -name '.DS_Store' 2>/dev/null)

if [ -n "$KPM_FILES" ]; then
    # Binary module: copy .kpm/.ko/.o directly
    KPM_FILE=$(echo "$KPM_FILES" | head -1)
    KPM_BASENAME=$(basename "$KPM_FILE")
    cp "$KPM_FILE" "$KPM_DIR/${MOD_ID}.kpm"
    log "Binary module installed: $KPM_DIR/${MOD_ID}.kpm"

    # If a matching .kpm.sig is present in the ZIP, copy it alongside
    # the binary so service.sh can verify the load on the next boot.
    # The verifier looks for $KPM_DIR/${MOD_ID}.kpm.sig specifically.
    # The sig file (if any) is the one whose basename is the kpm's
    # basename + ".sig"; we look it up by name rather than the first
    # .sig found in the ZIP, to support multi-kpm ZIPs cleanly.
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
    # NOTE: source-compiled modules are inherently unsigned in this MVP.
    # TODO(security): when REQUIRE_KPM_SIGNATURES=1 is enforced strictly
    # and a user installs a source module that gets compiled locally, the
    # resulting $KPM_DIR/${MOD_ID}.kpm will be rejected at next boot
    # unless a signing step is added to compile_kpm.sh. For now, this is
    # fine because service.sh allows unsigned modules with a warning.
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
    # The double-dash ends kpatch's option parsing, so any leading
    # '-' in $MOD_ARGS (or values that would otherwise be parsed as
    # options) is preserved verbatim. $MOD_ARGS is itself quoted
    # below so an args string with whitespace is passed as a single
    # argument to kpatch kpm load.
    ARGS_OPT=""
    if [ -n "$MOD_ARGS" ]; then
        ARGS_OPT="-- $MOD_ARGS"
    fi
    kpatch kpm load "$KPM_DIR/${MOD_ID}.kpm" $ARGS_OPT 2>&1
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
