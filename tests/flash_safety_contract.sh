#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PATCH="$ROOT/module/patch/boot_patch.sh"
SAFETY="$ROOT/module/patch/flash_safety.sh"
TRANSACTION="$ROOT/module/patch/transaction_safety.sh"
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

# Recovery is transaction-bound; no "newest valid backup" selector may return.
grep -Fq -- '--restore-bound-backup' "$UNPATCH" || fail "bound-backup restore entry point missing"
grep -Fq 'rollback_binding.json' "$UNPATCH" || fail "restore does not require rollback transaction binding"
grep -Fq 'device_binding_sha256' "$UNPATCH" || fail "restore does not verify device identity"
grep -Fq 'patched_image_sha256' "$UNPATCH" || fail "restore does not verify current patched bytes"
! grep -Fq 'for manifest in' "$UNPATCH" || fail "restore still scans/selects arbitrary backup manifests"

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

# Commit a synthetic destructive transaction and ensure only digests/identities
# required for exact rollback are persisted.
PATCHNEST_ROLLBACK_BINDING_FILE="$TMP/state/rollback_binding.json"
PATCHNEST_DEVICE_IDENTITY='unit-test-device-A'
export PATCHNEST_ROLLBACK_BINDING_FILE PATCHNEST_DEVICE_IDENTITY
# shellcheck disable=SC1090
. "$TRANSACTION"

BOOT_TARGET="$TMP/transaction-target.img"
BACKUP_CANDIDATE="$TMP/boot_backup_20260808T000000Z_TEST.img"
WORKDIR="$TMP/transaction-work"
FLASH_TO_DEVICE=true
export BOOT_TARGET BACKUP_CANDIDATE WORKDIR FLASH_TO_DEVICE
mkdir -p "$WORKDIR"
printf '%s\n' 'original boot bytes' > "$BACKUP_CANDIDATE"
printf '%s\n' 'patched boot bytes' > "$WORKDIR/new-boot.img"
cp "$WORKDIR/new-boot.img" "$BOOT_TARGET"

patchnest_commit_superkey || fail "destructive transaction commit failed"
[ -f "$PATCHNEST_ROLLBACK_BINDING_FILE" ] || fail "rollback transaction was not committed"
[ "$(stat -c '%a' "$PATCHNEST_ROLLBACK_BINDING_FILE")" = "600" ] || fail "rollback binding mode is not 0600"

grep -Fq '"verified_readback": true' "$PATCHNEST_ROLLBACK_BINDING_FILE" || fail "rollback binding is not readback-qualified"
grep -Fq '"rollback_backup": "boot_backup_20260808T000000Z_TEST.img"' "$PATCHNEST_ROLLBACK_BINDING_FILE" || fail "rollback binding does not name exact backup"
grep -Eq '"device_binding_sha256": "[0-9a-f]{64}"' "$PATCHNEST_ROLLBACK_BINDING_FILE" || fail "device digest missing"
grep -Eq '"patched_image_sha256": "[0-9a-f]{64}"' "$PATCHNEST_ROLLBACK_BINDING_FILE" || fail "patched digest missing"
grep -Eq '"patched_image_size": [1-9][0-9]*' "$PATCHNEST_ROLLBACK_BINDING_FILE" || fail "patched byte range missing"

binding_a=$(patchnest_device_binding_sha256)
PATCHNEST_DEVICE_IDENTITY='unit-test-device-B'
export PATCHNEST_DEVICE_IDENTITY
binding_b=$(patchnest_device_binding_sha256)
[ "$binding_a" != "$binding_b" ] || fail "device binding does not distinguish device identity"

echo "flash safety contract: PASS"
