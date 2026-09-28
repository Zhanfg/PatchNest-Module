#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TX="$ROOT/module/patch/transaction_safety.sh"
TF="$ROOT/module/patch/transactional_flash.sh"
SK="$ROOT/module/patch/superkey_safety.sh"
PATCH="$ROOT/module/patch/boot_patch.sh"
UNPATCH="$ROOT/module/patch/boot_unpatch.sh"

fail() {
    echo "destructive transaction contract: FAIL: $*" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

export PATCHNEST_TRANSACTION_TEST=1
export PATCHNEST_DEVICE_IDENTITY='synthetic-device-A'
export PATCHNEST_PENDING_TRANSACTION_FILE="$TMP/state/transaction.pending.json"
export PATCHNEST_RECOVERY_REQUIRED_FILE="$TMP/state/flash_recovery_required"
export PATCHNEST_ROLLBACK_BINDING_FILE="$TMP/state/rollback_binding.json"
export PATCHNEST_SUPERKEY_FILE="$TMP/state/superkey"
export PATCHNEST_SUPERKEY_PENDING_FILE="$TMP/state/superkey.pending"
export PATCHNEST_EXPORT_KEY_DIR="$TMP/state/export_keys"
export PATCHNEST_BACKUP_DIR="$TMP"
mkdir -p "$TMP/state" "$TMP/work"

# shellcheck disable=SC1090
. "$TX"
# shellcheck disable=SC1090
. "$SK"
# shellcheck disable=SC1090
. "$TF"

PATCHNEST_SUPERKEY='0123456789abcdef0123456789abcdef0123456789abcdef'
PATCHNEST_SUPERKEY_IS_NEW=1
PATCHNEST_SUPERKEY_CANDIDATE="$TMP/work/superkey.candidate"
export PATCHNEST_SUPERKEY PATCHNEST_SUPERKEY_IS_NEW PATCHNEST_SUPERKEY_CANDIDATE
printf '%s\n' "$PATCHNEST_SUPERKEY" > "$PATCHNEST_SUPERKEY_CANDIDATE"
chmod 0600 "$PATCHNEST_SUPERKEY_CANDIDATE"

SOURCE="$TMP/patched.img"
BACKUP="$TMP/boot_backup_20260808T000000Z_TEST.img"
TARGET="$TMP/boot-target.img"
printf '%s\n' 'PATCHED-IMAGE-BYTES' > "$SOURCE"
printf '%s\n' 'ORIGINAL-BOOT-BYTES' > "$BACKUP"
cp "$BACKUP" "$TARGET"

stage_pending_key() {
    printf '%s\n' "$PATCHNEST_SUPERKEY" > "$PATCHNEST_SUPERKEY_PENDING_FILE"
    chmod 0600 "$PATCHNEST_SUPERKEY_PENDING_FILE"
}

reset_state() {
    rm -f "$PATCHNEST_PENDING_TRANSACTION_FILE" "$PATCHNEST_RECOVERY_REQUIRED_FILE" \
        "$PATCHNEST_ROLLBACK_BINDING_FILE" "$PATCHNEST_SUPERKEY_PENDING_FILE" "$PATCHNEST_SUPERKEY_FILE"
    cp "$BACKUP" "$TARGET"
    stage_pending_key
}

# 1. A writer may partially mutate the target before reporting failure.
# The transaction MUST issue a second verified write using the exact backup.
reset_state
flash_calls=0
flash_image() {
    flash_calls=$((flash_calls + 1))
    if [ "$flash_calls" -eq 1 ]; then
        printf '%s\n' 'PARTIAL-CORRUPTION' > "$2"
        return 5
    fi
    cp "$1" "$2"
    return 0
}
set +e
patchnest_transactional_flash "$SOURCE" "$TARGET" "$BACKUP"
rc=$?
set -e
[ "$rc" -eq 20 ] || fail "partial-write failure did not report verified rollback (rc=$rc)"
cmp -s "$TARGET" "$BACKUP" || fail "partial-write failure did not restore backup bytes"
[ "$flash_calls" -eq 2 ] || fail "rollback writer was not invoked exactly once"
[ ! -e "$PATCHNEST_PENDING_TRANSACTION_FILE" ] || fail "pending transaction survived successful rollback"
[ ! -e "$PATCHNEST_SUPERKEY_PENDING_FILE" ] || fail "pending key survived successful rollback"

# 2. If the recovery write also fails, evidence MUST remain and success is forbidden.
reset_state
flash_calls=0
flash_image() {
    flash_calls=$((flash_calls + 1))
    printf '%s\n' "BROKEN-$flash_calls" > "$2"
    return 5
}
set +e
patchnest_transactional_flash "$SOURCE" "$TARGET" "$BACKUP"
rc=$?
set -e
[ "$rc" -eq 21 ] || fail "double write failure did not enter fatal state (rc=$rc)"
[ -e "$PATCHNEST_PENDING_TRANSACTION_FILE" ] || fail "fatal transaction evidence was discarded"
[ -e "$PATCHNEST_SUPERKEY_PENDING_FILE" ] || fail "fatal pending credential was discarded"
[ -e "$PATCHNEST_RECOVERY_REQUIRED_FILE" ] || fail "fatal recovery marker missing"

# 3. Known pre-write rejection must not perform a recovery write.
reset_state
flash_calls=0
flash_image() {
    flash_calls=$((flash_calls + 1))
    return 2
}
set +e
patchnest_transactional_flash "$SOURCE" "$TARGET" "$BACKUP"
rc=$?
set -e
[ "$rc" -eq 11 ] || fail "pre-write failure classification wrong (rc=$rc)"
[ "$flash_calls" -eq 1 ] || fail "pre-write failure incorrectly attempted rollback"
cmp -s "$TARGET" "$BACKUP" || fail "pre-write failure changed target"
[ ! -e "$PATCHNEST_PENDING_TRANSACTION_FILE" ] || fail "pre-write failure left transaction state"

# 4. If the write verifies but state cannot advance to written, target must roll back.
reset_state
(
    patchnest_mark_pending_transaction_written() { return 1; }
    flash_calls=0
    flash_image() {
        flash_calls=$((flash_calls + 1))
        cp "$1" "$2"
        return 0
    }
    set +e
    patchnest_transactional_flash "$SOURCE" "$TARGET" "$BACKUP"
    rc=$?
    set -e
    [ "$rc" -eq 22 ] || exit 41
    cmp -s "$TARGET" "$BACKUP" || exit 42
    [ "$flash_calls" -eq 2 ] || exit 43
) || fail "verified-write/state-advance failure did not roll back"

# 5. Successful write must leave a secure state=written transaction that binds
# the exact key/device/target/patched byte range.
reset_state
flash_image() { cp "$1" "$2"; return 0; }
patchnest_transactional_flash "$SOURCE" "$TARGET" "$BACKUP" || fail "successful transaction write failed"
[ "$(patchnest_json_string state "$PATCHNEST_PENDING_TRANSACTION_FILE")" = "written" ] \
    || fail "successful write did not advance transaction to written"
patchnest_pending_transaction_matches_written_key "$PATCHNEST_SUPERKEY" \
    || fail "written transaction does not validate exact key/target bytes"
! patchnest_pending_transaction_matches_written_key 'ffffffffffffffffffffffffffffffffffffffffffffffff' \
    || fail "written transaction accepted the wrong key"

# Final binding on a destructive path MUST require and consume that exact
# state=written transaction.
BOOT_TARGET="$TARGET"
BACKUP_CANDIDATE="$BACKUP"
WORKDIR="$TMP/work"
FLASH_TO_DEVICE=true
export BOOT_TARGET BACKUP_CANDIDATE WORKDIR FLASH_TO_DEVICE
cp "$SOURCE" "$WORKDIR/new-boot.img"
patchnest_commit_rollback_binding || fail "rollback binding commit failed"
[ -f "$PATCHNEST_ROLLBACK_BINDING_FILE" ] || fail "rollback binding missing"
[ ! -e "$PATCHNEST_PENDING_TRANSACTION_FILE" ] || fail "committed binding did not clear pending transaction"
set +e
patchnest_commit_rollback_binding
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "destructive binding commit succeeded without written pending transaction"

# 6. Simulate the power-loss window: boot bytes were verified and state=written,
# but the private patch workspace vanished before rollback binding commit.
reset_state
flash_image() { cp "$1" "$2"; return 0; }
patchnest_transactional_flash "$SOURCE" "$TARGET" "$BACKUP" || fail "crash-window transaction setup failed"
patchnest_pending_transaction_matches_written_key "$PATCHNEST_SUPERKEY" \
    || fail "crash-window written transaction invalid"
patchnest_commit_binding_from_pending_written "$PATCHNEST_SUPERKEY" \
    || fail "service-style binding reconstruction failed"
[ -f "$PATCHNEST_ROLLBACK_BINDING_FILE" ] || fail "recovered rollback binding missing"
[ ! -e "$PATCHNEST_PENDING_TRANSACTION_FILE" ] || fail "binding recovery did not consume pending transaction"
grep -Fq '"recovered_from_pending": true' "$PATCHNEST_ROLLBACK_BINDING_FILE" \
    || fail "recovered binding is not auditable"

# 7. Orphan pending credentials cannot be reused as a fresh patch identity.
rm -f "$PATCHNEST_SUPERKEY_FILE" "$PATCHNEST_PENDING_TRANSACTION_FILE" "$PATCHNEST_RECOVERY_REQUIRED_FILE"
stage_pending_key
PATCHNEST_SUPERKEY=''
PATCHNEST_SUPERKEY_IS_NEW=0
set +e
patchnest_prepare_superkey "$TMP/work"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "orphan pending key was accepted as a new patch credential"

# 8. Execute the real restore script with a fake low-level writer. First write
# partially mutates the target and returns 5; the script must retry the exact
# same transaction-bound backup and only then commit its restore receipt.
RESTORE_ROOT="$TMP/restore-harness"
RESTORE_STATE="$RESTORE_ROOT/state"
RESTORE_PATCH="$RESTORE_ROOT/patch"
mkdir -p "$RESTORE_STATE/backup" "$RESTORE_PATCH"
RESTORE_TARGET="$RESTORE_ROOT/boot-target.img"
RESTORE_BACKUP="$RESTORE_STATE/backup/boot_backup_20260808T010000Z_RESTORE.img"
printf '%s\n' 'RESTORE-ORIGINAL-BOOT' > "$RESTORE_BACKUP"
printf '%s\n' 'RESTORE-PATCHED-BOOT' > "$RESTORE_TARGET"
RESTORE_PATCHED_SHA=$(sha256sum "$RESTORE_TARGET" | awk '{print $1}')
RESTORE_BACKUP_SHA=$(sha256sum "$RESTORE_BACKUP" | awk '{print $1}')
RESTORE_PATCHED_SIZE=$(stat -c '%s' "$RESTORE_TARGET")
RESTORE_KEY='abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef'
RESTORE_KEY_SHA=$(printf '%s' "$RESTORE_KEY" | sha256sum | awk '{print $1}')
RESTORE_DEVICE_SHA=$(PATCHNEST_DEVICE_IDENTITY='synthetic-device-A' patchnest_device_binding_sha256 "$RESTORE_TARGET")

cat > "$RESTORE_STATE/rollback_binding.json" <<EOF
{
  "schema": 2,
  "boot_target": "$RESTORE_TARGET",
  "device_binding_sha256": "$RESTORE_DEVICE_SHA",
  "rollback_backup": "$(basename "$RESTORE_BACKUP")",
  "rollback_backup_sha256": "$RESTORE_BACKUP_SHA",
  "patched_image_sha256": "$RESTORE_PATCHED_SHA",
  "patched_image_size": $RESTORE_PATCHED_SIZE,
  "superkey_sha256": "$RESTORE_KEY_SHA",
  "verified_readback": true,
  "recovered_from_pending": false,
  "committed_at": "2026-08-08T01:00:00Z"
}
EOF
chmod 0600 "$RESTORE_STATE/rollback_binding.json"

# Copy the production script while redirecting only its persistent state root.
sed "s#PNDIR=\"/data/adb/patchnest\"#PNDIR=\"$RESTORE_STATE\"#" "$UNPATCH" > "$RESTORE_PATCH/boot_unpatch.sh"
chmod 0755 "$RESTORE_PATCH/boot_unpatch.sh"
printf '%s\n' '#!/bin/sh' > "$RESTORE_PATCH/util_functions.sh"

RESTORE_CALL_FILE="$RESTORE_ROOT/flash.calls"
printf '0\n' > "$RESTORE_CALL_FILE"
cat > "$RESTORE_PATCH/flash_safety.sh" <<EOF
#!/bin/sh
. "$TX"
flash_image() {
    n=\$(cat "$RESTORE_CALL_FILE")
    n=\$((n + 1))
    printf '%s\n' "\$n" > "$RESTORE_CALL_FILE"
    if [ "\$n" -eq 1 ]; then
        printf '%s\n' 'PARTIAL-RESTORE-WRITE' > "\$2"
        return 5
    fi
    cp "\$1" "\$2"
    return 0
}
EOF
chmod 0755 "$RESTORE_PATCH/flash_safety.sh"

PATCHNEST_ROLLBACK_BINDING_FILE="$RESTORE_STATE/rollback_binding.json" \
PATCHNEST_PENDING_TRANSACTION_FILE="$RESTORE_STATE/transaction.pending.json" \
PATCHNEST_RECOVERY_REQUIRED_FILE="$RESTORE_STATE/flash_recovery_required" \
PATCHNEST_BACKUP_DIR="$RESTORE_STATE/backup" \
PATCHNEST_DEVICE_IDENTITY='synthetic-device-A' \
PATCHNEST_TRANSACTION_TEST=1 \
sh "$RESTORE_PATCH/boot_unpatch.sh" --restore-bound-backup "$RESTORE_TARGET" \
    >/dev/null 2>&1 || fail "production restore did not recover from partial first write"
[ "$(cat "$RESTORE_CALL_FILE")" -eq 2 ] || fail "production restore did not retry exactly once"
cmp -s "$RESTORE_TARGET" "$RESTORE_BACKUP" || fail "production restore target differs from exact backup"
[ -f "$RESTORE_STATE/last_restore.json" ] || fail "production restore receipt missing"
[ ! -e "$RESTORE_STATE/rollback_binding.json" ] || fail "rollback authorization survived verified restore"
[ ! -e "$RESTORE_STATE/flash_recovery_required" ] || fail "recovery marker survived verified retry"

# Structural invariants for production entry points.
grep -Fq 'patchnest_has_unfinished_transaction' "$PATCH" || fail "patch does not block unfinished transaction"
grep -Fq 'patchnest_stage_superkey_for_flash' "$PATCH" || fail "pending key is not staged adjacent to destructive write"
grep -Fq 'patchnest_transactional_flash' "$PATCH" || fail "patch bypasses high-level transaction writer"
grep -Fq 'patchnest_rollback_after_commit_failure' "$PATCH" || fail "post-write commit failure has no mandatory rollback"
grep -Fq -- '--check-bound-backup' "$UNPATCH" || fail "read-only bound validator missing"
grep -Fq 'restore_exact_backup_with_retry' "$UNPATCH" || fail "restore has no partial-write retry guard"
! grep -Fq 'verified_backup=$(resolve_bound_backup)' "$UNPATCH" || fail "rollback metadata still crosses command-substitution subshell"
! grep -Fq 'kptools -u --image' "$UNPATCH" || fail "release unpatch still has a second destructive live-unpatch implementation"

echo "destructive transaction contract: PASS"
