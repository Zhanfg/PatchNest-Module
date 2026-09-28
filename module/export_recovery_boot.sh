#!/system/bin/sh
# Export an exact, validated copy of the current boot target before any
# destructive PatchNest test. This script never writes the boot partition.

set -eu
MODDIR=${0%/*}
PNDIR=${PATCHNEST_STATE_DIR:-/data/adb/patchnest}

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "! root shell required" >&2; exit 1; }
[ "${PATCHNEST_DEVICE_TEST_UNLOCK:-}" = "RECOVERY_EXPORT" ] || {
    echo "! Refusing recovery export without:" >&2
    echo "! PATCHNEST_DEVICE_TEST_UNLOCK=RECOVERY_EXPORT" >&2
    exit 2
}

OUTDIR=/storage/emulated/0/Download
if [ "${PATCHNEST_TRANSACTION_TEST:-0}" = "1" ] && [ -n "${PATCHNEST_RECOVERY_OUTPUT_DIR:-}" ]; then
    OUTDIR=$PATCHNEST_RECOVERY_OUTPUT_DIR
fi

[ -x "$MODDIR/patch/boot_extract.sh" ] || { echo "! boot_extract.sh missing" >&2; exit 1; }
[ -x "$MODDIR/bin/magiskboot" ] || { echo "! magiskboot missing" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "! sha256sum missing" >&2; exit 1; }

mkdir -p "$OUTDIR" "$PNDIR" || exit 1
chmod 0700 "$PNDIR" 2>/dev/null || true

_resolved=$(PATH="$MODDIR/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH" \
    "$MODDIR/patch/boot_extract.sh" false) || {
    echo "! exact boot target resolution failed" >&2
    exit 1
}
TARGET=$(printf '%s\n' "$_resolved" | sed -n 's/^BOOTIMAGE=//p' | tail -n 1)
[ -n "$TARGET" ] || { echo "! boot target was not emitted" >&2; exit 1; }
TARGET=$(readlink -f "$TARGET" 2>/dev/null || printf '%s' "$TARGET")
[ -e "$TARGET" ] || { echo "! resolved boot target missing: $TARGET" >&2; exit 1; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%S)
OUT="$OUTDIR/PatchNest_Recovery_Boot_${STAMP}.img"
MANIFEST="$OUTDIR/PatchNest_Recovery_Boot_${STAMP}.json"
TMP_OUT="${OUT}.partial.$$"
TMP_VALIDATE=$(mktemp -d /data/local/tmp/patchnest-recovery-validate.XXXXXX) || exit 1
cleanup() {
    rm -f "$TMP_OUT"
    rm -rf "$TMP_VALIDATE"
}
trap cleanup EXIT HUP INT TERM

# Read only. The copy is complete before it receives its final visible name.
cat "$TARGET" > "$TMP_OUT" || { echo "! boot recovery copy failed" >&2; exit 1; }
sync
[ -s "$TMP_OUT" ] || { echo "! boot recovery copy is empty" >&2; exit 1; }

TARGET_SHA=$(sha256sum "$TARGET" | awk '{print $1}')
COPY_SHA=$(sha256sum "$TMP_OUT" | awk '{print $1}')
[ "$TARGET_SHA" = "$COPY_SHA" ] || {
    echo "! recovery copy digest differs from live boot target" >&2
    exit 1
}
SIZE=$(stat -c '%s' "$TMP_OUT" 2>/dev/null)
printf '%s' "$SIZE" | grep -Eq '^[1-9][0-9]*$' || exit 1

if ! (cd "$TMP_VALIDATE" && "$MODDIR/bin/magiskboot" unpack "$TMP_OUT" >/dev/null 2>&1); then
    echo "! recovery image cannot be unpacked by magiskboot" >&2
    exit 1
fi
[ -s "$TMP_VALIDATE/kernel" ] || {
    echo "! recovery image unpack produced no kernel" >&2
    exit 1
}

mv -f "$TMP_OUT" "$OUT" || exit 1
chmod 0644 "$OUT" 2>/dev/null || true
PRODUCT=$(getprop ro.product.device 2>/dev/null | tr -d '\r\n')
SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r\n')

json_escape() {
    printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

cat > "${MANIFEST}.tmp.$$" <<EOF
{
  "schema": 1,
  "purpose": "off-device boot recovery before PatchNest destructive validation",
  "boot_target": "$(json_escape "$TARGET")",
  "slot_suffix": "$(json_escape "$SLOT")",
  "product_device": "$(json_escape "$PRODUCT")",
  "image_path": "$(json_escape "$OUT")",
  "image_sha256": "$COPY_SHA",
  "image_size": $SIZE,
  "magiskboot_unpack_verified": true,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"
}
EOF
mv -f "${MANIFEST}.tmp.$$" "$MANIFEST" || exit 1
chmod 0644 "$MANIFEST" 2>/dev/null || true

umask 077
cat > "$PNDIR/recovery_export.json.tmp.$$" <<EOF
{
  "boot_target": "$(json_escape "$TARGET")",
  "image_path": "$(json_escape "$OUT")",
  "image_sha256": "$COPY_SHA",
  "image_size": $SIZE,
  "verified": true
}
EOF
chmod 0600 "$PNDIR/recovery_export.json.tmp.$$" || exit 1
mv -f "$PNDIR/recovery_export.json.tmp.$$" "$PNDIR/recovery_export.json" || exit 1

printf '%s\n' "RECOVERY_EXPORT_VERIFIED"
printf 'boot_target=%s\n' "$TARGET"
printf 'image=%s\n' "$OUT"
printf 'manifest=%s\n' "$MANIFEST"
printf 'sha256=%s\n' "$COPY_SHA"
printf '%s\n' "Copy the image + manifest off-device and verify this SHA-256 before first reboot."
