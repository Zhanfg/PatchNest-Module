#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PATCH="$ROOT/module/patch/boot_patch.sh"
SAFETY="$ROOT/module/patch/flash_safety.sh"
UNPATCH="$ROOT/module/patch/boot_unpatch.sh"
EXTRACT="$ROOT/module/patch/boot_extract.sh"

fail() {
  echo "flash safety contract: FAIL: $*" >&2
  exit 1
}

# Structural gates: these are release invariants, not documentation hints.
grep -Fq '. "$MODPATH/flash_safety.sh"' "$PATCH" || fail "boot_patch does not activate flash_safety"
grep -Fq 'mktemp -d /data/local/tmp/patchnest_patch.XXXXXX' "$PATCH" || fail "patch workspace is not operation-private"
grep -Fq '"boot_target":' "$PATCH" || fail "backup manifest has no target binding"
grep -Fq '"backup_sha256":' "$PATCH" || fail "backup manifest has no backup digest"
grep -Fq '"backup_verified": true' "$PATCH" || fail "backup manifest is not explicitly verified"
grep -Fq 'validate_boot_image "$WORKDIR/new-boot.img"' "$PATCH" || fail "repacked image is not validated"
grep -Fq 'flash_image "$WORKDIR/new-boot.img" "$BOOT_TARGET"' "$PATCH" || fail "patch path bypasses reviewed flash writer"

# Old fail-open/stale-workspace patterns must never return.
! grep -Fq 'if [ ! -f kernel ]' "$PATCH" || fail "patch may reuse stale kernel"
! grep -Fq 'Cannot verify with kptools' "$PATCH" || fail "embedded KPM validation is fail-open"
! grep -Fq '(proceeding)' "$PATCH" || fail "embedded KPM validation is fail-open"
! grep -Eq 'TMP_DATE=.*%y%m%d%H%M([^%]|$)' "$PATCH" || fail "backup naming is minute-granularity"

# All destructive boot flows must activate the reviewed override layer.
for file in "$PATCH" "$UNPATCH" "$EXTRACT"; do
  grep -Fq 'flash_safety.sh' "$file" || fail "$(basename "$file") does not source flash_safety"
done

# Exercise the writer against a regular-file target. This validates the same
# digest contract used by offline tests without requiring a privileged block device.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
printf '%s\n' 'PatchNest transactional flash contract' > "$TMP/source.img"
printf '%s\n' 'old target contents' > "$TMP/target.img"

# shellcheck disable=SC1090
. "$SAFETY"
flash_image "$TMP/source.img" "$TMP/target.img" || fail "file-target flash_image failed"
cmp -s "$TMP/source.img" "$TMP/target.img" || fail "file-target readback differs"

expected=$(sha256sum "$TMP/source.img" | awk '{print $1}')
actual=$(sha256sum "$TMP/target.img" | awk '{print $1}')
[ "$expected" = "$actual" ] || fail "digest mismatch after verified write"

echo "flash safety contract: PASS"
