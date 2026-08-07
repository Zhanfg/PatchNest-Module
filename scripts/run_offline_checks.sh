#!/usr/bin/env bash
# Run PatchNest source and metadata checks without network or GitHub Actions.
set -euo pipefail
IFS=$'\n\t'

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

for command_name in python3 bash openssl node; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: $command_name is required" >&2
    exit 1
  }
done

printf '%s\n' '[1/11] Compile Python audit tools'
python3 -m py_compile \
  scripts/offline_audit.py \
  scripts/verify_release_metadata.py \
  tests/test_offline_audit.py \
  tests/test_release_metadata.py \
  tests/validate_boot_hardening.py \
  tests/validate_install_lifecycle.py \
  tests/validate_compile_policy.py

printf '%s\n' '[2/11] Run offline scanner unit tests'
python3 tests/test_offline_audit.py

printf '%s\n' '[3/11] Run boot hardening contracts'
python3 tests/validate_boot_hardening.py

printf '%s\n' '[4/11] Run install and KPM lifecycle contracts'
python3 tests/validate_install_lifecycle.py

printf '%s\n' '[5/11] Enforce off-device-only KPM source builds'
python3 tests/validate_compile_policy.py

printf '%s\n' '[6/11] Run Ed25519 signature vectors'
bash tests/test_kpm_verify.sh

printf '%s\n' '[7/11] Run kptools argv vectors'
bash tests/test_kptools_argv.sh

printf '%s\n' '[8/11] Run release metadata tests and current-tree validation'
python3 tests/test_release_metadata.py
python3 scripts/verify_release_metadata.py --root "$ROOT"

printf '%s\n' '[9/11] Generate repository audit report'
python3 scripts/offline_audit.py --root "$ROOT" --output-dir audit-output --no-syntax

printf '%s\n' '[10/11] Parse shell scripts'
bash -n \
  build.sh \
  scripts/run_offline_checks.sh \
  scripts/run_webui_offline_checks.sh \
  tests/test_kpm_verify.sh \
  tests/test_kptools_argv.sh
while IFS= read -r script; do
  bash -n "$script"
done < <(find module/patch module scripts -type f -name '*.sh' -print | LC_ALL=C sort)

printf '%s\n' '[11/11] Parse JavaScript modules'
while IFS= read -r source; do
  node --check "$source"
done < <(find webui -type f -name '*.js' \
  ! -path 'webui/node_modules/*' \
  ! -path 'webui/dist/*' \
  | LC_ALL=C sort)

printf '%s\n' 'All source-only offline checks completed.'
printf '%s\n' 'Run scripts/run_webui_offline_checks.sh when committed node_modules are already installed locally.'
