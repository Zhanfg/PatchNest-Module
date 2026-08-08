#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
EXPORT_SCRIPT="$ROOT/module/export_recovery_boot.sh"

fail() {
    echo "recovery export contract: FAIL: $*" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
STATE="$TMP/state"
OUT="$TMP/output"
TARGET="$TMP/boot-target.img"
mkdir -p "$MOD/bin" "$MOD/patch" "$STATE" "$OUT"
printf '%s\n' 'synthetic boot image for recovery export' > "$TARGET"

cat > "$MOD/patch/boot_extract.sh" <<EOF
#!/bin/sh
printf 'BOOTIMAGE=%s\n' "$TARGET"
EOF
chmod 0755 "$MOD/patch/boot_extract.sh"

cat > "$MOD/bin/magiskboot" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "unpack" ]; then
    printf '%s\n' 'synthetic-kernel' > kernel
    exit 0
fi
exit 1
EOF
chmod 0755 "$MOD/bin/magiskboot"
cp "$EXPORT_SCRIPT" "$MOD/export_recovery_boot.sh"
chmod 0755 "$MOD/export_recovery_boot.sh"

PATCHNEST_TRANSACTION_TEST=1 \
PATCHNEST_DEVICE_TEST_UNLOCK=RECOVERY_EXPORT \
PATCHNEST_RECOVERY_OUTPUT_DIR="$OUT" \
PATCHNEST_STATE_DIR="$STATE" \
sh "$MOD/export_recovery_boot.sh" > "$TMP/export.log"

grep -Fq 'RECOVERY_EXPORT_VERIFIED' "$TMP/export.log" || fail "export did not report verified state"
IMAGE=$(sed -n 's/^image=//p' "$TMP/export.log" | tail -n1)
MANIFEST=$(sed -n 's/^manifest=//p' "$TMP/export.log" | tail -n1)
SHA=$(sed -n 's/^sha256=//p' "$TMP/export.log" | tail -n1)
[ -f "$IMAGE" ] || fail "recovery image missing"
[ -f "$MANIFEST" ] || fail "recovery manifest missing"
[ -f "$STATE/recovery_export.json" ] || fail "root-only recovery receipt missing"
cmp -s "$IMAGE" "$TARGET" || fail "exported recovery bytes differ from live target"
[ "$(sha256sum "$IMAGE" | awk '{print $1}')" = "$SHA" ] || fail "reported recovery SHA differs from image"
[ "$(stat -c '%a' "$STATE/recovery_export.json")" = "600" ] || fail "recovery receipt mode is not 0600"
grep -Fq '"magiskboot_unpack_verified": true' "$MANIFEST" || fail "manifest lacks unpack verification"
grep -Fq '"verified": true' "$STATE/recovery_export.json" || fail "state receipt lacks verified marker"

# Wrong unlock must fail before creating another export.
rm -rf "$OUT"/* "$STATE"/*
set +e
PATCHNEST_TRANSACTION_TEST=1 \
PATCHNEST_DEVICE_TEST_UNLOCK=WRONG \
PATCHNEST_RECOVERY_OUTPUT_DIR="$OUT" \
PATCHNEST_STATE_DIR="$STATE" \
sh "$MOD/export_recovery_boot.sh" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "wrong unlock did not fail with usage/safety status"
[ -z "$(find "$OUT" -type f -print -quit)" ] || fail "wrong unlock still wrote recovery export"

echo "recovery export contract: PASS"
