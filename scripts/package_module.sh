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

command -v zip >/dev/null 2>&1 || { echo "zip is required" >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "unzip is required" >&2; exit 1; }
command -v sort >/dev/null 2>&1 || { echo "sort is required" >&2; exit 1; }

STAGE=$(mktemp -d)
cleanup() {
    rm -rf "$STAGE"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$STAGE/module"
cp -a "$SOURCE_DIR/." "$STAGE/module/"

# ZIP's DOS timestamp field cannot represent dates before 1980. A fixed UTC
# timestamp makes package bytes independent from checkout/build wall-clock time.
find "$STAGE/module" -exec touch -h -t 200001010000.00 {} +

mkdir -p "$(dirname "$OUTPUT_ABS")"
rm -f "$OUTPUT_ABS"

(
    cd "$STAGE/module"
    # Stable lexical path order + -X (no UID/GID/extra timestamp fields).
    # Strip the find(1) "./" prefix so module.prop and META-INF live at the
    # canonical ZIP root expected by Android root-manager installers.
    find . -type f -print | sed 's#^\./##' | LC_ALL=C sort > "$STAGE/file-list"
    [ -s "$STAGE/file-list" ] || {
        echo "module tree contains no files" >&2
        exit 1
    }
    zip -X -q "$OUTPUT_ABS" -@ < "$STAGE/file-list"
)

[ -s "$OUTPUT_ABS" ] || { echo "deterministic package is empty" >&2; exit 1; }

# The archive itself is the release boundary. Fail even when the source tree is
# correct if any flash-safety/runtime artifact was omitted from the ZIP.
unzip -Z1 "$OUTPUT_ABS" > "$STAGE/zip-list"
for required in \
    module.prop \
    FLASH_REVIEW_BLOCKED \
    customize.sh \
    service.sh \
    device_validation.sh \
    patch/boot_patch.sh \
    patch/boot_unpatch.sh \
    patch/flash_safety.sh \
    patch/transaction_safety.sh \
    patch/transactional_flash.sh \
    patch/superkey_safety.sh; do
    grep -Fxq "$required" "$STAGE/zip-list" || {
        echo "required package entry missing: $required" >&2
        exit 1
    }
done

# Canonical archive paths only: no traversal and no find(1) ./ prefixes.
if grep -Eq '(^|/)\.\.(/|$)|^\./' "$STAGE/zip-list"; then
    echo "unsafe or non-canonical path found in module ZIP" >&2
    exit 1
fi
