#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PATCHNEST_TRANSACTION_TEST=1
PATCHNEST_DEVICE_IDENTITY='backup-name-contract-device'
PATCHNEST_ROLLBACK_BINDING_FILE="$TMP/state/rollback_binding.json"
PATCHNEST_PENDING_TRANSACTION_FILE="$TMP/state/transaction.pending.json"
PATCHNEST_RECOVERY_REQUIRED_FILE="$TMP/state/flash_recovery_required"
PATCHNEST_BACKUP_DIR="$TMP/backups"
PATCHNEST_SUPERKEY_FILE="$TMP/state/superkey"
PATCHNEST_SUPERKEY_PENDING_FILE="$TMP/state/superkey.pending"
PATCHNEST_SUPERKEY='0123456789abcdef0123456789abcdef0123456789abcdef'
FLASH_TO_DEVICE=true
export PATCHNEST_TRANSACTION_TEST PATCHNEST_DEVICE_IDENTITY
export PATCHNEST_ROLLBACK_BINDING_FILE PATCHNEST_PENDING_TRANSACTION_FILE PATCHNEST_RECOVERY_REQUIRED_FILE PATCHNEST_BACKUP_DIR
export PATCHNEST_SUPERKEY_FILE PATCHNEST_SUPERKEY_PENDING_FILE PATCHNEST_SUPERKEY FLASH_TO_DEVICE

mkdir -p "$TMP/state" "$PATCHNEST_BACKUP_DIR" "$TMP/work"
BOOT_TARGET="$TMP/boot.img"
BACKUP_CANDIDATE="$PATCHNEST_BACKUP_DIR/boot_backup_20260808T020000Z_REAL.img"
WORKDIR="$TMP/work"
export BOOT_TARGET BACKUP_CANDIDATE WORKDIR
printf '%s\n' original > "$BACKUP_CANDIDATE"
printf '%s\n' patched > "$WORKDIR/new-boot.img"
cp "$WORKDIR/new-boot.img" "$BOOT_TARGET"

# shellcheck disable=SC1090
. "$ROOT/module/patch/superkey_safety.sh"
# The helper resets PATCHNEST_SUPERKEY when sourced; restore the explicit test key.
PATCHNEST_SUPERKEY='0123456789abcdef0123456789abcdef0123456789abcdef'
export PATCHNEST_SUPERKEY
# shellcheck disable=SC1090
. "$ROOT/module/patch/transaction_safety.sh"

patchnest_stage_pending_transaction "$WORKDIR/new-boot.img" "$BOOT_TARGET" "$BACKUP_CANDIDATE" \
    || { echo 'transaction backup identity contract: FAIL: staging failed' >&2; exit 1; }
patchnest_mark_pending_transaction_written \
    || { echo 'transaction backup identity contract: FAIL: written transition failed' >&2; exit 1; }

# Tamper only the filename while preserving all content digests. A hash-only
# validator would accept this; the transaction must bind the exact backup name.
sed 's/boot_backup_20260808T020000Z_REAL.img/boot_backup_20260808T020000Z_OTHER.img/' \
    "$PATCHNEST_PENDING_TRANSACTION_FILE" > "$PATCHNEST_PENDING_TRANSACTION_FILE.tmp"
mv "$PATCHNEST_PENDING_TRANSACTION_FILE.tmp" "$PATCHNEST_PENDING_TRANSACTION_FILE"
chmod 0600 "$PATCHNEST_PENDING_TRANSACTION_FILE"

if patchnest_commit_rollback_binding; then
    echo 'transaction backup identity contract: FAIL: mismatched pending backup filename accepted' >&2
    exit 1
fi
[ ! -e "$PATCHNEST_ROLLBACK_BINDING_FILE" ] || {
    echo 'transaction backup identity contract: FAIL: binding written after mismatch' >&2
    exit 1
}

echo 'transaction backup identity contract: PASS'
