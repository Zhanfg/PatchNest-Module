#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export PATCHNEST_STATE_DIR="$TEST_ROOT/state"
export PATCHNEST_KPM_DIR="$PATCHNEST_STATE_DIR/kpm"
export PATCHNEST_KPM_ZIP_DIR="$PATCHNEST_STATE_DIR/kpm_zips"
export PATCHNEST_EVENT_DIR="$PATCHNEST_STATE_DIR/kpm_events"
export PATCHNEST_INSTALL_LOG="$PATCHNEST_STATE_DIR/recovery-test.log"

mkdir -p "$PATCHNEST_KPM_DIR" "$PATCHNEST_KPM_ZIP_DIR" "$PATCHNEST_EVENT_DIR"
# shellcheck disable=SC1091
. "$ROOT/module/kpm_install_recovery.sh"

assert_file_content() {
  local path=$1
  local expected=$2
  [[ -f "$path" ]]
  [[ "$(cat "$path")" == "$expected" ]]
}

new_stage() {
  local name=$1
  local module_id=$2
  local state=$3
  local stage="$PATCHNEST_STATE_DIR/.kpm-stage.$name"
  mkdir -p "$stage/previous"
  patchnest_write_install_journal "$stage" "$state" "$module_id"
  printf '%s' "$stage"
}

# preparing: no persistent files were changed, so only staging is removed.
stage=$(new_stage preparing demo preparing)
printf 'scratch' >"$stage/module.kpm"
patchnest_recover_install_stage "$stage"
[[ ! -e "$stage" ]]

# backup: some old files were moved, while untouched destinations must remain.
printf 'old-kpm' >"$PATCHNEST_KPM_DIR/demo.kpm"
printf 'old-args' >"$PATCHNEST_EVENT_DIR/demo.args"
stage=$(new_stage backup demo backup)
mv "$PATCHNEST_KPM_DIR/demo.kpm" "$stage/previous/kpm"
patchnest_recover_install_stage "$stage"
assert_file_content "$PATCHNEST_KPM_DIR/demo.kpm" old-kpm
assert_file_content "$PATCHNEST_EVENT_DIR/demo.args" old-args
[[ ! -e "$stage" ]]

# writing: new destinations are removed and every preserved old file restored.
printf 'old-kpm-2' >"$PATCHNEST_KPM_DIR/demo.kpm"
printf 'old-sig' >"$PATCHNEST_KPM_DIR/demo.kpm.sig"
printf 'old-zip' >"$PATCHNEST_KPM_ZIP_DIR/demo.zip"
printf 'old-digest' >"$PATCHNEST_KPM_ZIP_DIR/demo.zip.sha256"
printf 'old-prop' >"$PATCHNEST_KPM_ZIP_DIR/demo.prop"
printf 'old-events' >"$PATCHNEST_EVENT_DIR/demo.events"
printf 'old-args-2' >"$PATCHNEST_EVENT_DIR/demo.args"
: >"$PATCHNEST_EVENT_DIR/demo.autoload"
stage=$(new_stage writing demo writing)
mv "$PATCHNEST_KPM_DIR/demo.kpm" "$stage/previous/kpm"
mv "$PATCHNEST_KPM_DIR/demo.kpm.sig" "$stage/previous/sig"
mv "$PATCHNEST_KPM_ZIP_DIR/demo.zip" "$stage/previous/zip"
mv "$PATCHNEST_KPM_ZIP_DIR/demo.zip.sha256" "$stage/previous/zip-digest"
mv "$PATCHNEST_KPM_ZIP_DIR/demo.prop" "$stage/previous/prop"
mv "$PATCHNEST_EVENT_DIR/demo.events" "$stage/previous/events"
mv "$PATCHNEST_EVENT_DIR/demo.args" "$stage/previous/args"
mv "$PATCHNEST_EVENT_DIR/demo.autoload" "$stage/previous/autoload"
printf 'new-kpm' >"$PATCHNEST_KPM_DIR/demo.kpm"
printf 'new-sig' >"$PATCHNEST_KPM_DIR/demo.kpm.sig"
printf 'new-only-event' >"$PATCHNEST_EVENT_DIR/demo.events"
patchnest_recover_install_stage "$stage"
assert_file_content "$PATCHNEST_KPM_DIR/demo.kpm" old-kpm-2
assert_file_content "$PATCHNEST_KPM_DIR/demo.kpm.sig" old-sig
assert_file_content "$PATCHNEST_KPM_ZIP_DIR/demo.zip" old-zip
assert_file_content "$PATCHNEST_KPM_ZIP_DIR/demo.zip.sha256" old-digest
assert_file_content "$PATCHNEST_KPM_ZIP_DIR/demo.prop" old-prop
assert_file_content "$PATCHNEST_EVENT_DIR/demo.events" old-events
assert_file_content "$PATCHNEST_EVENT_DIR/demo.args" old-args-2
[[ -f "$PATCHNEST_EVENT_DIR/demo.autoload" ]]
[[ ! -e "$stage" ]]

# complete: the new destination is authoritative; only stale staging is removed.
printf 'committed-kpm' >"$PATCHNEST_KPM_DIR/demo.kpm"
stage=$(new_stage complete demo complete)
printf 'obsolete-previous' >"$stage/previous/kpm"
patchnest_recover_install_stage "$stage"
assert_file_content "$PATCHNEST_KPM_DIR/demo.kpm" committed-kpm
[[ ! -e "$stage" ]]

# Invalid journal is preserved for manual inspection and cannot be guessed.
stage="$PATCHNEST_STATE_DIR/.kpm-stage.invalid"
mkdir -p "$stage/previous"
printf 'state=writing\nmodule_id=../escape\n' >"$stage/journal.properties"
if patchnest_recover_install_stage "$stage"; then
  echo 'invalid journal unexpectedly recovered' >&2
  exit 1
fi
[[ -d "$stage" ]]
rm -rf "$stage"

# A stale lock with a recoverable stage is taken over by the current process.
stage=$(new_stage stale-lock demo preparing)
mkdir -p "$PATCHNEST_INSTALL_LOCK"
printf '999999\n' >"$PATCHNEST_INSTALL_LOCK/pid"
patchnest_acquire_install_lock
[[ ! -e "$stage" ]]
assert_file_content "$PATCHNEST_INSTALL_LOCK/pid" "$$"
patchnest_release_install_lock
[[ ! -e "$PATCHNEST_INSTALL_LOCK" ]]

printf '%s\n' 'Durable KPM install recovery vectors passed.'
