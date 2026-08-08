#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PATCH="$ROOT/module/patch/boot_patch.sh"
SAFETY="$ROOT/module/patch/flash_safety.sh"
SUPERKEY="$ROOT/module/patch/superkey_safety.sh"
UNPATCH="$ROOT/module/patch/boot_unpatch.sh"
EXTRACT="$ROOT/module/patch/boot_extract.sh"

fail() {
  echo "flash safety contract: FAIL: $*" >&2
  exit 1
}

# Structural gates: these are release invariants, not documentation hints.
grep -Fq '. "$MODPATH/flash_safety.sh"' "$PATCH" || fail "boot_patch does not activate flash_safety"
grep -Fq '. "$MODPATH/superkey_safety.sh"' "$PATCH" || fail "boot_patch does not activate superkey lifecycle"
grep -Fq 'mktemp -d /data/local/tmp/patchnest_patch.XXXXXX' "$PATCH" || fail "patch workspace is not operation-private"
grep -Fq '"boot_target":' "$PATCH" || fail "backup manifest has no target binding"
grep -Fq '"backup_sha256":' "$PATCH" || fail "backup manifest has no backup digest"
grep -Fq '"superkey_sha256":' "$PATCH" || fail "backup/receipt has no credential binding"
grep -Fq '"backup_verified": true' "$PATCH" || fail "backup manifest is not explicitly verified"
grep -Fq 'validate_boot_image "$WORKDIR/new-boot.img"' "$PATCH" || fail "repacked image is not validated"
grep -Fq 'flash_image "$WORKDIR/new-boot.img" "$BOOT_TARGET"' "$PATCH" || fail "patch path bypasses reviewed flash writer"
grep -Fq -- '-s "$PATCHNEST_SUPERKEY"' "$PATCH" || fail "Public1158 superkey is not embedded by kptools"
grep -Fq 'patchnest_commit_superkey' "$PATCH" || fail "verified flash does not commit its matching superkey"

# Old fail-open/stale-workspace patterns must never return.
! grep -Fq 'if [ ! -f kernel ]' "$PATCH" || fail "patch may reuse stale kernel"
! grep -Fq 'Cannot verify with kptools' "$PATCH" || fail "embedded KPM validation is fail-open"
! grep -Fq '(proceeding)' "$PATCH" || fail "embedded KPM validation is fail-open"
! grep -Eq 'TMP_DATE=.*%y%m%d%H%M([^%]|$)' "$PATCH" || fail "backup naming is minute-granularity"

# All destructive boot flows must activate the reviewed override layer.
for file in "$PATCH" "$UNPATCH" "$EXTRACT"; do
  grep -Fq 'flash_safety.sh' "$file" || fail "$(basename "$file") does not source flash_safety"
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Exercise the writer against a regular-file target. This validates the same
# digest contract used by offline tests without requiring a privileged block device.
printf '%s\n' 'PatchNest transactional flash contract' > "$TMP/source.img"
printf '%s\n' 'old target contents' > "$TMP/target.img"

# shellcheck disable=SC1090
. "$SAFETY"
flash_image "$TMP/source.img" "$TMP/target.img" || fail "file-target flash_image failed"
cmp -s "$TMP/source.img" "$TMP/target.img" || fail "file-target readback differs"

expected=$(sha256sum "$TMP/source.img" | awk '{print $1}')
actual=$(sha256sum "$TMP/target.img" | awk '{print $1}')
[ "$expected" = "$actual" ] || fail "digest mismatch after verified write"

# Exercise the Public1158 credential lifecycle entirely in the temp tree.
PATCHNEST_SUPERKEY_FILE="$TMP/state/superkey"
PATCHNEST_EXPORT_KEY_DIR="$TMP/state/export_keys"
export PATCHNEST_SUPERKEY_FILE PATCHNEST_EXPORT_KEY_DIR
# shellcheck disable=SC1090
. "$SUPERKEY"
patchnest_prepare_superkey "$TMP" || fail "superkey preparation failed"
patchnest_validate_superkey "$PATCHNEST_SUPERKEY" || fail "generated key is invalid"
[ ! -e "$PATCHNEST_SUPERKEY_FILE" ] || fail "new key persisted before flash commit"
key_before=$PATCHNEST_SUPERKEY
key_sha=$(patchnest_superkey_sha256)
printf '%s' "$key_sha" | grep -Eq '^[0-9a-f]{64}$' || fail "superkey digest is invalid"

patchnest_commit_superkey || fail "superkey commit failed"
[ -f "$PATCHNEST_SUPERKEY_FILE" ] || fail "committed superkey missing"
[ "$(stat -c '%a' "$PATCHNEST_SUPERKEY_FILE")" = "600" ] || fail "committed superkey mode is not 0600"
[ "$(cat "$PATCHNEST_SUPERKEY_FILE")" = "$key_before" ] || fail "committed key changed"

# A later patch must reuse the persisted credential rather than silently rotate it.
PATCHNEST_SUPERKEY=''
patchnest_prepare_superkey "$TMP" || fail "persisted superkey reload failed"
[ "$PATCHNEST_SUPERKEY" = "$key_before" ] || fail "persisted key was not reused"

export_record=$(patchnest_store_export_key "$TMP/source.img") || fail "export key record failed"
[ -f "$export_record" ] || fail "export key record missing"
[ "$(stat -c '%a' "$export_record")" = "600" ] || fail "export key record mode is not 0600"

echo "flash safety contract: PASS"
