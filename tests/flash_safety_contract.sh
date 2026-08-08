#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PATCH="$ROOT/module/patch/boot_patch.sh"
SAFETY="$ROOT/module/patch/flash_safety.sh"
TRANSACTION="$ROOT/module/patch/transaction_safety.sh"
SUPERKEY="$ROOT/module/patch/superkey_safety.sh"
UNPATCH="$ROOT/module/patch/boot_unpatch.sh"
EXTRACT="$ROOT/module/patch/boot_extract.sh"

PATCHNEST_TRANSACTION_TEST=1
export PATCHNEST_TRANSACTION_TEST

fail() {
  echo "flash safety contract: FAIL: $*" >&2
  exit 1
}

# Structural release invariants.
grep -Fq '. "$MODPATH/flash_safety.sh"' "$PATCH" || fail "boot_patch does not activate flash_safety"
grep -Fq '. "$MODPATH/superkey_safety.sh"' "$PATCH" || fail "boot_patch does not activate superkey lifecycle"
grep -Fq 'mktemp -d /data/local/tmp/patchnest_patch.XXXXXX' "$PATCH" || fail "patch workspace is not private"
grep -Fq '"boot_target":' "$PATCH" || fail "backup manifest has no target binding"
grep -Fq '"backup_sha256":' "$PATCH" || fail "backup manifest has no backup digest"
grep -Fq '"superkey_sha256":' "$PATCH" || fail "backup/receipt has no credential binding"
grep -Fq '"backup_verified": true' "$PATCH" || fail "backup manifest is not verified"
grep -Fq 'validate_boot_image "$WORKDIR/new-boot.img"' "$PATCH" || fail "repacked image is not validated"
grep -Fq 'flash_image "$WORKDIR/new-boot.img" "$BOOT_TARGET"' "$PATCH" || fail "patch bypasses reviewed writer"
grep -Fq -- '-s "$PATCHNEST_SUPERKEY"' "$PATCH" || fail "Public1158 key is not embedded"
grep -Fq 'patchnest_commit_superkey' "$PATCH" || fail "verified flash does not commit credential state"
! grep -Fq 'if [ ! -f kernel ]' "$PATCH" || fail "patch may reuse stale kernel"
! grep -Fq 'Cannot verify with kptools' "$PATCH" || fail "embedded KPM validation is fail-open"
! grep -Fq '(proceeding)' "$PATCH" || fail "embedded KPM validation is fail-open"

for file in "$PATCH" "$UNPATCH" "$EXTRACT"; do
  grep -Fq 'flash_safety.sh' "$file" || fail "$(basename "$file") does not source flash_safety"
done

grep -Fq -- '--restore-bound-backup' "$UNPATCH" || fail "bound restore entry point missing"
grep -Fq 'rollback_binding.json' "$UNPATCH" || fail "restore does not require transaction binding"
grep -Fq 'device_binding_sha256' "$UNPATCH" || fail "restore does not verify device identity"
grep -Fq 'patched_image_sha256' "$UNPATCH" || fail "restore does not verify current patched bytes"
! grep -Fq 'for manifest in' "$UNPATCH" || fail "restore still selects arbitrary manifests"

grep -Fq 'superkey.pending' "$SUPERKEY" || fail "pending credential crash state missing"
grep -Fq 'PATCHNEST_SUPERKEY_PENDING_FILE' "$SUPERKEY" || fail "pending credential path is not explicit"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Writer readback contract on an offline regular-file target.
printf '%s\n' 'PatchNest transactional flash contract' > "$TMP/source.img"
printf '%s\n' 'old target contents' > "$TMP/target.img"
# shellcheck disable=SC1090
. "$SAFETY"
flash_image "$TMP/source.img" "$TMP/target.img" || fail "file-target flash_image failed"
cmp -s "$TMP/source.img" "$TMP/target.img" || fail "file-target readback differs"
expected=$(sha256sum "$TMP/source.img" | awk '{print $1}')
actual=$(sha256sum "$TMP/target.img" | awk '{print $1}')
[ "$expected" = "$actual" ] || fail "digest mismatch after verified write"

# Export-only key generation must not create an active/pending device credential.
(
  PATCHNEST_SUPERKEY_FILE="$TMP/export-state/superkey"
  PATCHNEST_SUPERKEY_PENDING_FILE="$TMP/export-state/superkey.pending"
  PATCHNEST_EXPORT_KEY_DIR="$TMP/export-state/export_keys"
  FLASH_TO_DEVICE=false
  export PATCHNEST_SUPERKEY_FILE PATCHNEST_SUPERKEY_PENDING_FILE PATCHNEST_EXPORT_KEY_DIR FLASH_TO_DEVICE
  # shellcheck disable=SC1090
  . "$SUPERKEY"
  patchnest_prepare_superkey "$TMP" || fail "export key preparation failed"
  patchnest_validate_superkey "$PATCHNEST_SUPERKEY" || fail "generated export key invalid"
  [ ! -e "$PATCHNEST_SUPERKEY_FILE" ] || fail "export path created active key"
  [ ! -e "$PATCHNEST_SUPERKEY_PENDING_FILE" ] || fail "export path created pending device key"
  record=$(patchnest_store_export_key "$TMP/source.img") || fail "export key record failed"
  [ -f "$record" ] || fail "export key record missing"
  [ "$(stat -c '%a' "$record")" = "600" ] || fail "export key record mode is not 0600"
)

# Successful destructive credential commit: pending exists before commit, then
# atomically becomes the active key. Stub only the independent binding writer.
(
  PATCHNEST_SUPERKEY_FILE="$TMP/success-state/superkey"
  PATCHNEST_SUPERKEY_PENDING_FILE="$TMP/success-state/superkey.pending"
  PATCHNEST_EXPORT_KEY_DIR="$TMP/success-state/export_keys"
  FLASH_TO_DEVICE=true
  export PATCHNEST_SUPERKEY_FILE PATCHNEST_SUPERKEY_PENDING_FILE PATCHNEST_EXPORT_KEY_DIR FLASH_TO_DEVICE
  # shellcheck disable=SC1090
  . "$SUPERKEY"
  patchnest_prepare_superkey "$TMP" || fail "destructive key preparation failed"
  before=$PATCHNEST_SUPERKEY
  [ -f "$PATCHNEST_SUPERKEY_PENDING_FILE" ] || fail "pending key not staged before write"
  [ ! -e "$PATCHNEST_SUPERKEY_FILE" ] || fail "active key exists before verified write"
  [ "$(stat -c '%a' "$PATCHNEST_SUPERKEY_PENDING_FILE")" = "600" ] || fail "pending key mode is not 0600"
  patchnest_commit_rollback_binding() { return 0; }
  patchnest_commit_superkey || fail "destructive key commit failed"
  [ -f "$PATCHNEST_SUPERKEY_FILE" ] || fail "active key missing after commit"
  [ ! -e "$PATCHNEST_SUPERKEY_PENDING_FILE" ] || fail "pending key remains after commit"
  [ "$(cat "$PATCHNEST_SUPERKEY_FILE")" = "$before" ] || fail "promoted key changed"
)

# If rollback binding commit fails, the new active key must be moved back to
# pending so a power loss cannot strand a boot that already requires it.
(
  PATCHNEST_SUPERKEY_FILE="$TMP/failure-state/superkey"
  PATCHNEST_SUPERKEY_PENDING_FILE="$TMP/failure-state/superkey.pending"
  PATCHNEST_EXPORT_KEY_DIR="$TMP/failure-state/export_keys"
  FLASH_TO_DEVICE=true
  export PATCHNEST_SUPERKEY_FILE PATCHNEST_SUPERKEY_PENDING_FILE PATCHNEST_EXPORT_KEY_DIR FLASH_TO_DEVICE
  # shellcheck disable=SC1090
  . "$SUPERKEY"
  patchnest_prepare_superkey "$TMP" || fail "failure-path key preparation failed"
  before=$PATCHNEST_SUPERKEY
  patchnest_commit_rollback_binding() { return 1; }
  if patchnest_commit_superkey; then
    fail "key commit succeeded despite rollback binding failure"
  fi
  [ ! -e "$PATCHNEST_SUPERKEY_FILE" ] || fail "failed transaction left active key committed"
  [ -f "$PATCHNEST_SUPERKEY_PENDING_FILE" ] || fail "failed transaction lost recoverable pending key"
  [ "$(cat "$PATCHNEST_SUPERKEY_PENDING_FILE")" = "$before" ] || fail "reverted pending key changed"
)

# An existing committed key must be secure and must not be rewritten.
(
  mkdir -p "$TMP/existing-state"
  PATCHNEST_SUPERKEY_FILE="$TMP/existing-state/superkey"
  PATCHNEST_SUPERKEY_PENDING_FILE="$TMP/existing-state/superkey.pending"
  PATCHNEST_EXPORT_KEY_DIR="$TMP/existing-state/export_keys"
  FLASH_TO_DEVICE=true
  export PATCHNEST_SUPERKEY_FILE PATCHNEST_SUPERKEY_PENDING_FILE PATCHNEST_EXPORT_KEY_DIR FLASH_TO_DEVICE
  printf '%s\n' '0123456789abcdef0123456789abcdef0123456789abcdef' > "$PATCHNEST_SUPERKEY_FILE"
  chmod 0600 "$PATCHNEST_SUPERKEY_FILE"
  inode_before=$(stat -c '%i' "$PATCHNEST_SUPERKEY_FILE")
  # shellcheck disable=SC1090
  . "$SUPERKEY"
  patchnest_prepare_superkey "$TMP" || fail "existing key preparation failed"
  patchnest_commit_rollback_binding() { return 0; }
  patchnest_commit_superkey || fail "existing key transaction commit failed"
  inode_after=$(stat -c '%i' "$PATCHNEST_SUPERKEY_FILE")
  [ "$inode_before" = "$inode_after" ] || fail "existing key was rewritten"
  [ ! -e "$PATCHNEST_SUPERKEY_PENDING_FILE" ] || fail "stale pending key survived committed-key path"
)

# Symlink credentials must never be accepted.
(
  mkdir -p "$TMP/symlink-state"
  printf '%s\n' '0123456789abcdef0123456789abcdef0123456789abcdef' > "$TMP/symlink-target"
  chmod 0600 "$TMP/symlink-target"
  PATCHNEST_SUPERKEY_FILE="$TMP/symlink-state/superkey"
  PATCHNEST_SUPERKEY_PENDING_FILE="$TMP/symlink-state/superkey.pending"
  FLASH_TO_DEVICE=true
  export PATCHNEST_SUPERKEY_FILE PATCHNEST_SUPERKEY_PENDING_FILE FLASH_TO_DEVICE
  ln -s "$TMP/symlink-target" "$PATCHNEST_SUPERKEY_FILE"
  # shellcheck disable=SC1090
  . "$SUPERKEY"
  if patchnest_prepare_superkey "$TMP" >/dev/null 2>&1; then
    fail "symlink key path was accepted"
  fi
)

# Commit and inspect the exact rollback transaction record itself.
PATCHNEST_ROLLBACK_BINDING_FILE="$TMP/transaction-state/rollback_binding.json"
PATCHNEST_DEVICE_IDENTITY='unit-test-device-A'
PATCHNEST_SUPERKEY='0123456789abcdef0123456789abcdef0123456789abcdef'
export PATCHNEST_ROLLBACK_BINDING_FILE PATCHNEST_DEVICE_IDENTITY PATCHNEST_SUPERKEY
# shellcheck disable=SC1090
. "$TRANSACTION"
BOOT_TARGET="$TMP/transaction-target.img"
BACKUP_CANDIDATE="$TMP/boot_backup_20260808T000000Z_TEST.img"
WORKDIR="$TMP/transaction-work"
export BOOT_TARGET BACKUP_CANDIDATE WORKDIR
mkdir -p "$WORKDIR"
printf '%s\n' 'original boot bytes' > "$BACKUP_CANDIDATE"
printf '%s\n' 'patched boot bytes' > "$WORKDIR/new-boot.img"
cp "$WORKDIR/new-boot.img" "$BOOT_TARGET"
patchnest_commit_rollback_binding || fail "rollback transaction commit failed"
[ -f "$PATCHNEST_ROLLBACK_BINDING_FILE" ] || fail "rollback transaction missing"
[ "$(stat -c '%a' "$PATCHNEST_ROLLBACK_BINDING_FILE")" = "600" ] || fail "rollback binding mode is not 0600"
grep -Fq '"verified_readback": true' "$PATCHNEST_ROLLBACK_BINDING_FILE" || fail "binding is not readback-qualified"
grep -Fq '"rollback_backup": "boot_backup_20260808T000000Z_TEST.img"' "$PATCHNEST_ROLLBACK_BINDING_FILE" || fail "binding does not name exact backup"
grep -Eq '"device_binding_sha256": "[0-9a-f]{64}"' "$PATCHNEST_ROLLBACK_BINDING_FILE" || fail "device digest missing"
grep -Eq '"patched_image_sha256": "[0-9a-f]{64}"' "$PATCHNEST_ROLLBACK_BINDING_FILE" || fail "patched digest missing"
grep -Eq '"patched_image_size": [1-9][0-9]*' "$PATCHNEST_ROLLBACK_BINDING_FILE" || fail "patched byte range missing"
binding_a=$(patchnest_device_binding_sha256)
PATCHNEST_DEVICE_IDENTITY='unit-test-device-B'
export PATCHNEST_DEVICE_IDENTITY
binding_b=$(patchnest_device_binding_sha256)
[ "$binding_a" != "$binding_b" ] || fail "device binding does not distinguish device identity"

echo "flash safety contract: PASS"
