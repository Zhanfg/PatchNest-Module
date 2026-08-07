#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

MODULE="$WORK/module"
STATE="$WORK/state"
mkdir -p "$MODULE/bin" "$STATE"
cp "$ROOT/module/runtime_compat_check.sh" "$MODULE/runtime_compat_check.sh"
cat >"$MODULE/kpm_verify.sh" <<'VERIFY'
kpm_verify__require_backend() {
  KPM_VERIFY_BACKEND=binary
  return 0
}
VERIFY
chmod 0755 "$MODULE/runtime_compat_check.sh"

PATCHNEST_MODDIR_OVERRIDE="$MODULE" \
PATCHNEST_STATE_DIR="$STATE" \
PATCHNEST_SYSTEM_SHELL=/bin/sh \
PATCHNEST_COMPAT_EXPECT_ARCH=any \
PATCHNEST_COMPAT_SKIP_ANDROID_TARGET=1 \
PATCHNEST_COMPAT_SKIP_BINARIES=1 \
TMPDIR="$WORK" \
  sh "$MODULE/runtime_compat_check.sh" --strict >"$WORK/report.txt"

grep -q $'^system_shell\tpass\tyes\t' "$WORK/report.txt"
grep -q $'^mktemp_directory\tpass\tyes\t' "$WORK/report.txt"
grep -q $'^sha256sum_check\tpass\tyes\t' "$WORK/report.txt"
grep -q $'^unzip_z1\tpass\tyes\t' "$WORK/report.txt"
grep -q $'^dd_flags\tpass\tyes\t' "$WORK/report.txt"
grep -q $'^ed25519_verifier\tpass\tyes\t' "$WORK/report.txt"
grep -q $'^boot_target_mapping\twarn\tno\t' "$WORK/report.txt"
grep -q $'^summary\tpass\tyes\t' "$WORK/report.txt"

if grep -Eq '^[[:space:]]*blockdev[[:space:]]+--setrw([[:space:]]|$)' "$MODULE/runtime_compat_check.sh"; then
  echo 'runtime probe executes blockdev --setrw' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*dd[[:space:]].*of=.*(/dev/block|BOOTIMAGE|_target)' "$MODULE/runtime_compat_check.sh"; then
  echo 'runtime probe contains a block-device dd output path' >&2
  exit 1
fi

printf '%s\n' 'Runtime compatibility host vectors passed.'
