#!/usr/bin/env bash
# Run PatchNest source and metadata checks without network or GitHub Actions.
set -euo pipefail
IFS=$'\n\t'

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required" >&2
  exit 1
}

printf '%s\n' '[1/6] Compile Python audit tools'
python3 -m py_compile \
  scripts/offline_audit.py \
  scripts/verify_release_metadata.py \
  tests/test_offline_audit.py \
  tests/test_release_metadata.py \
  tests/validate_boot_hardening.py

printf '%s\n' '[2/6] Run offline scanner unit tests'
python3 tests/test_offline_audit.py

printf '%s\n' '[3/6] Run boot hardening contracts'
python3 tests/validate_boot_hardening.py

printf '%s\n' '[4/6] Run release metadata tests and current-tree validation'
python3 tests/test_release_metadata.py
python3 scripts/verify_release_metadata.py --root "$ROOT"

printf '%s\n' '[5/6] Generate repository audit report'
python3 scripts/offline_audit.py --root "$ROOT" --output-dir audit-output --no-syntax

printf '%s\n' '[6/6] Parse shell scripts'
if command -v bash >/dev/null 2>&1; then
  bash -n build.sh scripts/run_offline_checks.sh
  while IFS= read -r script; do
    bash -n "$script"
  done < <(find module/patch module scripts -type f -name '*.sh' -print | LC_ALL=C sort)
else
  echo 'WARNING: bash unavailable; shell parse checks skipped' >&2
fi

printf '%s\n' 'All offline checks completed.'
