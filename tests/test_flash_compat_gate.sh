#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MODULE="$WORK/module"
mkdir -p "$MODULE/patch" "$WORK/state"

cat >"$MODULE/runtime_compat_check.sh" <<'PROBE'
#!/bin/sh
printf 'args=%s\n' "$*" >"$PATCHNEST_STATE_DIR/probe-call.txt"
printf 'module=%s\n' "$PATCHNEST_MODDIR_OVERRIDE" >>"$PATCHNEST_STATE_DIR/probe-call.txt"
exit "${PROBE_RC:-0}"
PROBE
chmod 0755 "$MODULE/runtime_compat_check.sh"

MODPATH="$MODULE/patch"
PATCHNEST_MODDIR_OVERRIDE="$MODULE"
PATCHNEST_STATE_DIR="$WORK/state"
# shellcheck source=/dev/null
. "$ROOT/module/patch/flash_guard.sh"

runtime_compatibility_gate
grep -q '^args=--strict$' "$WORK/state/probe-call.txt"
grep -q "^module=$MODULE$" "$WORK/state/probe-call.txt"

export PROBE_RC=1
if runtime_compatibility_gate; then
  echo 'failed compatibility probe was accepted' >&2
  exit 1
fi
unset PROBE_RC

rm -f "$MODULE/runtime_compat_check.sh"
if runtime_compatibility_gate; then
  echo 'missing compatibility probe was accepted' >&2
  exit 1
fi

printf '%s\n' 'Flash runtime compatibility gate vectors passed.'
