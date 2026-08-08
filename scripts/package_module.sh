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
    # File modes are preserved by cp -a and stored by zip on Unix.
    find . -type f -print | sed 's#^\./##' | LC_ALL=C sort > "$STAGE/file-list"
    [ -s "$STAGE/file-list" ] || {
        echo "module tree contains no files" >&2
        exit 1
    }
    zip -X -q "$OUTPUT_ABS" -@ < "$STAGE/file-list"
)

[ -s "$OUTPUT_ABS" ] || { echo "deterministic package is empty" >&2; exit 1; }
