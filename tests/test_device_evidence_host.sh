#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MODULE="$WORK/module"
OUTPUT="$WORK/evidence"
mkdir -p "$MODULE"
cat >"$MODULE/runtime_compat_check.sh" <<'PROBE'
#!/system/bin/sh
printf '%s\n' 'check_id	status	required	detail'
printf '%s\n' 'summary	fail	yes	checks=1 required_failures=1'
exit 1
PROBE
chmod 0755 "$MODULE/runtime_compat_check.sh"

PATCHNEST_MODULE_DIR="$MODULE" \
  sh "$ROOT/scripts/collect_device_evidence.sh" --output "$OUTPUT" >"$WORK/collector.log"

grep -q '^exit=1$' "$OUTPUT/runtime-compat-status.txt"
grep -q '^summary' "$OUTPUT/runtime-compat-console.txt"
grep -q 'runtime probe did not execute blockdev --setrw' "$OUTPUT/SHARING_NOTICE.txt"
grep -q '^schema_version=2$' "$OUTPUT/collector-info.txt"
[[ -f "$OUTPUT/uname.txt" ]]
[[ -f "$OUTPUT/id.txt" ]]
[[ -f "$OUTPUT/boot-target.txt" ]]
[[ -f "${OUTPUT}.tar.gz" ]]

if grep -Eq '^[[:space:]]*blockdev[[:space:]]+--setrw([[:space:]]|$)' "$ROOT/scripts/collect_device_evidence.sh"; then
  echo 'collector executes blockdev --setrw' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*dd[[:space:]].*of=.*(/dev/block|BOOT_BLOCK)' "$ROOT/scripts/collect_device_evidence.sh"; then
  echo 'collector contains a block-device dd output path' >&2
  exit 1
fi

printf '%s\n' 'Device evidence host vectors passed.'
