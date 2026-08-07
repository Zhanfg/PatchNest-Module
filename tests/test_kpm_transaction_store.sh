#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export PATCHNEST_STATE_DIR="$TEST_ROOT/state"
export PATCHNEST_KPM_DIR="$PATCHNEST_STATE_DIR/kpm"
export PATCHNEST_EVENT_DIR="$PATCHNEST_STATE_DIR/kpm_events"
export PATCHNEST_TRANSACTION_LOG="$PATCHNEST_STATE_DIR/transactions.log"
QUARANTINE="$PATCHNEST_STATE_DIR/kpm_quarantine"
FAILED="$PATCHNEST_STATE_DIR/kpm_failed"
SYSTEM_SHA256SUM=$(command -v sha256sum)
SYSTEM_PATH=$PATH

mkdir -p "$PATCHNEST_KPM_DIR" "$PATCHNEST_EVENT_DIR" "$QUARANTINE" "$FAILED"
# shellcheck disable=SC1091
. "$ROOT/module/kpm_transaction_store.sh"

assert_no_live_set() {
  local id=$1
  [[ ! -e "$PATCHNEST_KPM_DIR/$id.kpm" ]]
  [[ ! -e "$PATCHNEST_KPM_DIR/$id.kpm.sig" ]]
  [[ ! -e "$PATCHNEST_EVENT_DIR/$id.events" ]]
  [[ ! -e "$PATCHNEST_EVENT_DIR/$id.args" ]]
  [[ ! -e "$PATCHNEST_EVENT_DIR/$id.autoload" ]]
}

create_live_set() {
  local id=$1
  printf 'kpm-%s' "$id" >"$PATCHNEST_KPM_DIR/$id.kpm"
  printf 'sig-%s' "$id" >"$PATCHNEST_KPM_DIR/$id.kpm.sig"
  printf 'BOOT_COMPLETED\n' >"$PATCHNEST_EVENT_DIR/$id.events"
  printf 'mode=test\n' >"$PATCHNEST_EVENT_DIR/$id.args"
  : >"$PATCHNEST_EVENT_DIR/$id.autoload"
}

# Normal transaction: all files move together, manifest is complete, and the
# retained checksum set verifies with the host sha256sum.
create_live_set normal
entry_id=$(patchnest_store_kpm_transaction \
  "$PATCHNEST_KPM_DIR/normal.kpm" "$QUARANTINE" autoload-disabled)
entry="$QUARANTINE/$entry_id"
assert_no_live_set normal
[[ "$(cat "$entry/state")" == 'state=complete' ]]
grep -qx 'reason=autoload-disabled' "$entry/manifest.properties"
grep -qx 'primary=module.kpm' "$entry/manifest.properties"
(
  cd "$entry"
  "$SYSTEM_SHA256SUM" -c checksums.sha256 >/dev/null
)

# A checksum-generation failure with no restore conflict must put every file
# back and remove the incomplete transaction directory.
MOCK_BIN="$TEST_ROOT/mock-fail"
mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/sha256sum" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$MOCK_BIN/sha256sum"
PATH="$MOCK_BIN:$SYSTEM_PATH"
export PATH
create_live_set recoverable
if patchnest_store_kpm_transaction \
    "$PATCHNEST_KPM_DIR/recoverable.kpm" "$FAILED" load-failed; then
  echo 'checksum failure unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(cat "$PATCHNEST_KPM_DIR/recoverable.kpm")" == 'kpm-recoverable' ]]
[[ "$(cat "$PATCHNEST_KPM_DIR/recoverable.kpm.sig")" == 'sig-recoverable' ]]
[[ "$(cat "$PATCHNEST_EVENT_DIR/recoverable.args")" == 'mode=test' ]]
[[ -f "$PATCHNEST_EVENT_DIR/recoverable.autoload" ]]
if find "$FAILED" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
  echo 'recoverable failed transaction was not removed' >&2
  exit 1
fi

# If an external conflict prevents the primary from being restored, the store
# must preserve the transaction with state=rollback-failed rather than delete
# the only surviving original payload.
MOCK_BIN="$TEST_ROOT/mock-conflict"
mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/sha256sum" <<'EOF'
#!/bin/sh
: >"$PATCHNEST_KPM_DIR/conflict.kpm"
exit 1
EOF
chmod +x "$MOCK_BIN/sha256sum"
PATH="$MOCK_BIN:$SYSTEM_PATH"
export PATH
create_live_set conflict
if patchnest_store_kpm_transaction \
    "$PATCHNEST_KPM_DIR/conflict.kpm" "$FAILED" load-failed; then
  echo 'conflicted rollback unexpectedly succeeded' >&2
  exit 1
fi
rollback_entry=$(find "$FAILED" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[[ -n "$rollback_entry" ]]
[[ "$(cat "$rollback_entry/state")" == 'state=rollback-failed' ]]
[[ "$(cat "$rollback_entry/module.kpm")" == 'kpm-conflict' ]]
grep -q 'rollback incomplete' "$PATCHNEST_TRANSACTION_LOG"

# Transaction roots are exact trusted directories and may not be symlinks.
PATH=$SYSTEM_PATH
export PATH
rm -rf "$QUARANTINE"
mkdir "$TEST_ROOT/redirected"
ln -s "$TEST_ROOT/redirected" "$QUARANTINE"
create_live_set symlinked
if patchnest_store_kpm_transaction \
    "$PATCHNEST_KPM_DIR/symlinked.kpm" "$QUARANTINE" autoload-disabled; then
  echo 'symlink transaction root unexpectedly accepted' >&2
  exit 1
fi
[[ "$(cat "$PATCHNEST_KPM_DIR/symlinked.kpm")" == 'kpm-symlinked' ]]
[[ -z "$(find "$TEST_ROOT/redirected" -mindepth 1 -print -quit)" ]]

printf '%s\n' 'KPM transaction store vectors passed.'
