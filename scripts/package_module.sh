#!/bin/sh
set -eu

SOURCE_DIR=${1:-}
OUTPUT=${2:-}

[ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ] || {
    echo "usage: package_module.sh <module-dir> <output.zip>" >&2
    exit 2
}
[ -n "$OUTPUT" ] || {
    echo "usage: package_module.sh <module-dir> <output.zip>" >&2
    exit 2
}

case "$OUTPUT" in
    /*) OUTPUT_ABS=$OUTPUT ;;
    *) OUTPUT_ABS="$(pwd)/$OUTPUT" ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
SAFETY_VALIDATOR="$REPO_ROOT/tests/validate_flash_package.js"

command -v zip >/dev/null 2>&1 || { echo "zip is required" >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "unzip is required" >&2; exit 1; }
command -v sort >/dev/null 2>&1 || { echo "sort is required" >&2; exit 1; }

# Build assembles the Android binaries/WebUI into module/ immediately before
# packaging. When that complete tree is present, release-safety validation is a
# mandatory pre-ZIP gate. The source-only Flash safety workflow intentionally
# lacks these generated binaries and continues with its shell/transaction tests.
if [ -s "$SOURCE_DIR/bin/kpatch" ] && \
   [ -s "$SOURCE_DIR/bin/kptools" ] && \
   [ -s "$SOURCE_DIR/bin/kpimg" ] && \
   [ -s "$SOURCE_DIR/bin/magiskboot" ] && \
   [ -s "$SOURCE_DIR/webroot/index.html" ]; then
    [ -f "$SAFETY_VALIDATOR" ] || {
        echo "assembled module safety validator missing: $SAFETY_VALIDATOR" >&2
        exit 1
    }
    command -v node >/dev/null 2>&1 || {
        echo "node is required to validate an assembled release package" >&2
        exit 1
    }
    node "$SAFETY_VALIDATOR"
fi

STAGE=$(mktemp -d)
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT HUP INT TERM

mkdir -p "$STAGE/module"
cp -a "$SOURCE_DIR/." "$STAGE/module/"
find "$STAGE/module" -exec touch -h -t 200001010000.00 {} +

mkdir -p "$(dirname "$OUTPUT_ABS")"
rm -f "$OUTPUT_ABS"

(
    cd "$STAGE/module"
    find . -type f -print | sed 's#^\./##' | LC_ALL=C sort > "$STAGE/file-list"
    [ -s "$STAGE/file-list" ] || { echo "module tree contains no files" >&2; exit 1; }
    zip -X -q "$OUTPUT_ABS" -@ < "$STAGE/file-list"
)

[ -s "$OUTPUT_ABS" ] || { echo "deterministic package is empty" >&2; exit 1; }
unzip -Z1 "$OUTPUT_ABS" > "$STAGE/zip-list"
for required in \
    module.prop \
    FLASH_REVIEW_BLOCKED \
    customize.sh \
    service.sh \
    device_validation.sh \
    arm_auto_recovery.sh \
    verify_auto_recovery.sh \
    export_recovery_boot.sh \
    patch/boot_patch.sh \
    patch/boot_unpatch.sh \
    patch/flash_safety.sh \
    patch/transaction_safety.sh \
    patch/transactional_flash.sh \
    patch/fr014_gate.sh \
    patch/superkey_safety.sh; do
    grep -Fxq "$required" "$STAGE/zip-list" || {
        echo "required package entry missing: $required" >&2
        exit 1
    }
done

if grep -Eq '(^|/)\.\.(/|$)|^\./' "$STAGE/zip-list"; then
    echo "unsafe or non-canonical path found in module ZIP" >&2
    exit 1
fi
