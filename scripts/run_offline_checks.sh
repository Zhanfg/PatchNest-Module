#!/usr/bin/env bash
# Run PatchNest source and metadata checks without network or GitHub Actions.
set -euo pipefail
IFS=$'\n\t'

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

for command_name in python3 bash openssl; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: $command_name is required" >&2
    exit 1
  }
done

printf '%s\n' '[1/9] Compile Python audit tools'
python3 -m py_compile \
  scripts/offline_audit.py \
  scripts/verify_release_metadata.py \
  tests/test_offline_audit.py \
  tests/test_release_metadata.py \
  tests/validate_boot_hardening.py \
  tests/validate_install_lifecycle.py \
  tests/validate_compile_policy.py

printf '%s\n' '[2/9] Run offline scanner unit tests'
python3 tests/test_offline_audit.py

printf '%s\n' '[3/9] Run boot hardening contracts'
python3 tests/validate_boot_hardening.py

printf '%s\n' '[4/9] Run install and KPM lifecycle contracts'
python3 tests/validate_install_lifecycle.py

printf '%s\n' '[5/9] Enforce off-device-only KPM source builds'
python3 tests/validate_compile_policy.py

printf '%s\n' '[6/9] Run Ed25519 signature vectors'
bash tests/test_kpm_verify.sh

printf '%s\n' '[7/9] Run release metadata tests and current-tree validation'
python3 tests/test_release_metadata.py
python3 scripts/verify_release_metadata.py --root "$ROOT"

printf '%s\n' '[8/9] Generate repository audit report'
python3 scripts/offline_audit.py --root "$ROOT" --output-dir audit-output --no-syntax

printf '%s\n' '[9/9] Parse shell scripts'
bash -n build.sh scripts/run_offline_checks.sh tests/test_kpm_verify.sh
while IFS= read -r script; do
  bash -n "$script"
done < <(find module/patch module scripts -type f -name '*.sh' -print | LC_ALL=C sort)

printf '%s\n' 'All offline checks completed.'
