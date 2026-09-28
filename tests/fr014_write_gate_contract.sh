#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
PATCH="$MOD/patch"
STATE="$TMP/state"
mkdir -p "$PATCH" "$STATE" "$TMP/work" "$TMP/backups"
printf '%s\n' 'candidate-gate-contract' > "$MOD/FR014_DEVICE_CANDIDATE"
cp "$ROOT/module/patch/transaction_safety.sh" "$PATCH/transaction_safety.sh"
cp "$ROOT/module/patch/fr014_gate.sh" "$PATCH/fr014_gate.sh"
cp "$ROOT/module/patch/transactional_flash.sh" "$PATCH/transactional_flash.sh"

SOURCE="$TMP/work/new-boot.img"
TARGET="$TMP/boot.img"
BACKUP="$TMP/backups/boot_backup_20260808T030000Z_GATE.img"
printf '%s\n' patched > "$SOURCE"
printf '%s\n' original > "$TARGET"
cp "$TARGET" "$BACKUP"

PATCHNEST_TRANSACTION_TEST=1
PATCHNEST_DEVICE_IDENTITY='fr014-gate-device'
PATCHNEST_MODULE_DIR="$MOD"
MODPATH="$PATCH"
PATCHNEST_ROLLBACK_BINDING_FILE="$STATE/rollback_binding.json"
PATCHNEST_PENDING_TRANSACTION_FILE="$STATE/transaction.pending.json"
PATCHNEST_RECOVERY_REQUIRED_FILE="$STATE/flash_recovery_required"
PATCHNEST_BACKUP_DIR="$TMP/backups"
PATCHNEST_FR014_PREFLIGHT_FILE="$STATE/fr014_preflight.json"
PATCHNEST_RECOVERY_EXPORT_FILE="$STATE/recovery_export.json"
PATCHNEST_SUPERKEY_PENDING_FILE="$STATE/superkey.pending"
export PATCHNEST_TRANSACTION_TEST PATCHNEST_DEVICE_IDENTITY PATCHNEST_MODULE_DIR MODPATH
export PATCHNEST_ROLLBACK_BINDING_FILE PATCHNEST_PENDING_TRANSACTION_FILE PATCHNEST_RECOVERY_REQUIRED_FILE PATCHNEST_BACKUP_DIR
export PATCHNEST_FR014_PREFLIGHT_FILE PATCHNEST_RECOVERY_EXPORT_FILE PATCHNEST_SUPERKEY_PENDING_FILE

# shellcheck disable=SC1090
. "$PATCH/transaction_safety.sh"
patchnest_superkey_sha256() {
    printf '%s' '0123456789abcdef0123456789abcdef0123456789abcdef' | sha256sum | awk '{print $1}'
}
patchnest_discard_pending_key() { rm -f "$PATCHNEST_SUPERKEY_PENDING_FILE"; }
FLASH_CALLS="$TMP/flash.calls"
printf '%s\n' 0 > "$FLASH_CALLS"
flash_image() {
    _pn_n=$(cat "$FLASH_CALLS")
    _pn_n=$((_pn_n + 1))
    printf '%s\n' "$_pn_n" > "$FLASH_CALLS"
    cp "$1" "$2"
}
# shellcheck disable=SC1090
. "$PATCH/transactional_flash.sh"

write_recovery_receipt() {
    _pn_sha=$(sha256sum "$TARGET" | awk '{print $1}')
    _pn_size=$(stat -c '%s' "$TARGET")
    cat > "$PATCHNEST_RECOVERY_EXPORT_FILE" <<EOF
{
  "boot_target": "$TARGET",
  "image_path": "/off-device/recovery.img",
  "image_sha256": "$_pn_sha",
  "image_size": $_pn_size,
  "verified": true
}
EOF
    chmod 0600 "$PATCHNEST_RECOVERY_EXPORT_FILE"
}

reset_clean_target() {
    rm -f "$PATCHNEST_PENDING_TRANSACTION_FILE" "$PATCHNEST_RECOVERY_REQUIRED_FILE" \
        "$PATCHNEST_FR014_PREFLIGHT_FILE" "$PATCHNEST_RECOVERY_EXPORT_FILE" \
        "$STATE/superkey" "$STATE/superkey.pending" "$STATE/rollback_binding.json" \
        "$STATE/last_flash.json" "$STATE/last_restore.json" "$MOD/unresolved"
    rm -rf "$STATE/kpm"
    cp "$BACKUP" "$TARGET"
    printf '%s\n' 0 > "$FLASH_CALLS"
}

# 1. Candidate destructive write without a fresh preflight receipt must fail
# before flash_image is called.
set +e
patchnest_transactional_flash "$SOURCE" "$TARGET" "$BACKUP"
rc=$?
set -e
[ "$rc" -eq 9 ] || { echo "FR-014 write gate contract: FAIL: no-receipt rc=$rc" >&2; exit 1; }
[ "$(cat "$FLASH_CALLS")" -eq 0 ] || { echo "FR-014 write gate contract: FAIL: no-receipt path touched writer" >&2; exit 1; }
cmp -s "$TARGET" "$BACKUP" || { echo "FR-014 write gate contract: FAIL: no-receipt path changed target" >&2; exit 1; }

# 2. A receipt is bound to the exact live target bytes. External target change
# after preflight must invalidate it before the writer is reached.
patchnest_write_fr014_preflight_receipt "$TARGET" || { echo "FR-014 write gate contract: FAIL: receipt creation failed" >&2; exit 1; }
write_recovery_receipt
printf '%s\n' externally-changed > "$TARGET"
set +e
patchnest_transactional_flash "$SOURCE" "$TARGET" "$BACKUP"
rc=$?
set -e
[ "$rc" -eq 9 ] || { echo "FR-014 write gate contract: FAIL: changed-target rc=$rc" >&2; exit 1; }
[ "$(cat "$FLASH_CALLS")" -eq 0 ] || { echo "FR-014 write gate contract: FAIL: changed-target path touched writer" >&2; exit 1; }

# 3. Preflight without a matching verified recovery export is insufficient.
reset_clean_target
patchnest_write_fr014_preflight_receipt "$TARGET" || { echo "FR-014 write gate contract: FAIL: receipt creation for no-export case failed" >&2; exit 1; }
set +e
patchnest_transactional_flash "$SOURCE" "$TARGET" "$BACKUP"
rc=$?
set -e
[ "$rc" -eq 9 ] || { echo "FR-014 write gate contract: FAIL: missing recovery export rc=$rc" >&2; exit 1; }
[ "$(cat "$FLASH_CALLS")" -eq 0 ] || { echo "FR-014 write gate contract: FAIL: missing-export path touched writer" >&2; exit 1; }

# 4. KPM state appearing after preflight invalidates the clean lifecycle.
reset_clean_target
patchnest_write_fr014_preflight_receipt "$TARGET" || exit 1
write_recovery_receipt
mkdir -p "$STATE/kpm"
printf '%s\n' synthetic > "$STATE/kpm/injected.kpm"
set +e
patchnest_transactional_flash "$SOURCE" "$TARGET" "$BACKUP"
rc=$?
set -e
[ "$rc" -eq 9 ] || { echo "FR-014 write gate contract: FAIL: post-preflight KPM rc=$rc" >&2; exit 1; }
[ "$(cat "$FLASH_CALLS")" -eq 0 ] || { echo "FR-014 write gate contract: FAIL: KPM-contaminated path touched writer" >&2; exit 1; }

# 5. Fresh preflight + matching recovery export + unchanged clean state authorizes
# exactly one destructive attempt.
reset_clean_target
patchnest_write_fr014_preflight_receipt "$TARGET" || { echo "FR-014 write gate contract: FAIL: fresh receipt creation failed" >&2; exit 1; }
write_recovery_receipt
patchnest_transactional_flash "$SOURCE" "$TARGET" "$BACKUP" || { echo "FR-014 write gate contract: FAIL: valid receipt/export pair rejected" >&2; exit 1; }
[ "$(cat "$FLASH_CALLS")" -eq 1 ] || { echo "FR-014 write gate contract: FAIL: valid path writer count incorrect" >&2; exit 1; }
cmp -s "$TARGET" "$SOURCE" || { echo "FR-014 write gate contract: FAIL: valid path did not write source" >&2; exit 1; }
[ ! -e "$PATCHNEST_FR014_PREFLIGHT_FILE" ] || { echo "FR-014 write gate contract: FAIL: preflight receipt was not consumed" >&2; exit 1; }
[ -e "$PATCHNEST_RECOVERY_EXPORT_FILE" ] || { echo "FR-014 write gate contract: FAIL: recovery export evidence was consumed" >&2; exit 1; }
[ "$(patchnest_json_string state "$PATCHNEST_PENDING_TRANSACTION_FILE")" = "written" ] || { echo "FR-014 write gate contract: FAIL: transaction did not reach written" >&2; exit 1; }

# 6. A candidate marker with missing gate helper must fail closed.
(
    MISS="$TMP/missing-helper"
    mkdir -p "$MISS/module/patch" "$MISS/state" "$MISS/backups" "$MISS/work"
    printf '%s\n' candidate > "$MISS/module/FR014_DEVICE_CANDIDATE"
    cp "$PATCH/transaction_safety.sh" "$MISS/module/patch/transaction_safety.sh"
    cp "$PATCH/transactional_flash.sh" "$MISS/module/patch/transactional_flash.sh"
    printf '%s\n' original > "$MISS/boot.img"
    cp "$MISS/boot.img" "$MISS/backups/boot_backup_20260808T040000Z_MISSING.img"
    printf '%s\n' patched > "$MISS/work/new-boot.img"
    MODPATH="$MISS/module/patch"
    PATCHNEST_TRANSACTION_TEST=1
    PATCHNEST_DEVICE_IDENTITY='missing-gate-device'
    PATCHNEST_PENDING_TRANSACTION_FILE="$MISS/state/transaction.pending.json"
    PATCHNEST_ROLLBACK_BINDING_FILE="$MISS/state/rollback_binding.json"
    PATCHNEST_RECOVERY_REQUIRED_FILE="$MISS/state/flash_recovery_required"
    PATCHNEST_BACKUP_DIR="$MISS/backups"
    export MODPATH PATCHNEST_TRANSACTION_TEST PATCHNEST_DEVICE_IDENTITY
    export PATCHNEST_PENDING_TRANSACTION_FILE PATCHNEST_ROLLBACK_BINDING_FILE PATCHNEST_RECOVERY_REQUIRED_FILE PATCHNEST_BACKUP_DIR
    # shellcheck disable=SC1090
    . "$MISS/module/patch/transaction_safety.sh"
    patchnest_superkey_sha256() { printf '%s' key | sha256sum | awk '{print $1}'; }
    flash_image() { echo 'writer must not run' >&2; return 99; }
    # shellcheck disable=SC1090
    . "$MISS/module/patch/transactional_flash.sh"
    set +e
    patchnest_transactional_flash "$MISS/work/new-boot.img" "$MISS/boot.img" "$MISS/backups/boot_backup_20260808T040000Z_MISSING.img"
    _pn_rc=$?
    set -e
    [ "$_pn_rc" -eq 9 ] || exit 1
) || { echo "FR-014 write gate contract: FAIL: missing helper did not fail closed" >&2; exit 1; }

echo "FR-014 write gate contract: PASS"
