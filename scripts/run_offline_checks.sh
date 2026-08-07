#!/usr/bin/env bash
# Run PatchNest source and metadata checks without network or GitHub Actions.
set -euo pipefail
IFS=$'\n\t'
export PYTHONDONTWRITEBYTECODE=1

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

for command_name in python3 bash cc openssl node; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: $command_name is required" >&2
    exit 1
  }
done

printf '%s\n' '[1/25] Compile Python audit and release-gate tools'
python3 -m py_compile \
  release_gate/common.py \
  release_gate/check_git_clean.py \
  release_gate/check_signature.py \
  release_gate/check_boot_matrix.py \
  release_gate/check_matrix_candidate_binding.py \
  release_gate/check_module_layout.py \
  release_gate/check_permissions.py \
  scripts/offline_audit.py \
  scripts/record_matrix_evidence.py \
  scripts/verify_monocypher_pin.py \
  scripts/verify_release_metadata.py \
  scripts/verify_signing_key_policy.py \
  tests/test_matrix_candidate_binding.py \
  tests/test_monocypher_pin.py \
  tests/test_offline_audit.py \
  tests/test_record_matrix_evidence.py \
  tests/test_release_gate.py \
  tests/test_release_metadata.py \
  tests/test_signing_key_policy.py \
  tests/validate_boot_hardening.py \
  tests/validate_compile_policy.py \
  tests/validate_flash_compat_gate.py \
  tests/validate_install_lifecycle.py \
  tests/validate_legacy_boot_helpers.py \
  tests/validate_packaged_kpm_verifier.py \
  tests/validate_release_candidate_pipeline.py \
  tests/validate_runtime_compat.py

printf '%s\n' '[2/25] Run offline scanner unit tests'
python3 tests/test_offline_audit.py

printf '%s\n' '[3/25] Run release and evidence-gate fixture tests'
python3 tests/test_release_gate.py
bash scripts/run_evidence_offline_tests.sh

printf '%s\n' '[4/25] Run boot hardening contracts'
python3 tests/validate_boot_hardening.py

printf '%s\n' '[5/25] Run legacy boot and flash helper contracts'
python3 tests/validate_legacy_boot_helpers.py

printf '%s\n' '[6/25] Run flash compatibility gate contracts'
python3 tests/validate_flash_compat_gate.py

printf '%s\n' '[7/25] Run packaged KPM verifier contracts'
python3 tests/validate_packaged_kpm_verifier.py

printf '%s\n' '[8/25] Run install and KPM lifecycle contracts'
python3 tests/validate_install_lifecycle.py

printf '%s\n' '[9/25] Run focused KPM transaction suite'
bash scripts/run_transaction_offline_checks.sh

printf '%s\n' '[10/25] Enforce off-device-only KPM source builds'
python3 tests/validate_compile_policy.py

printf '%s\n' '[11/25] Validate runtime compatibility and evidence contracts'
python3 tests/validate_runtime_compat.py

printf '%s\n' '[12/25] Run flash compatibility gate vectors'
bash tests/test_flash_compat_gate.sh

printf '%s\n' '[13/25] Run KPM verifier CLI source vectors'
bash tests/test_kpm_verify_cli_source.sh

printf '%s\n' '[14/25] Run runtime compatibility host vectors'
bash tests/test_runtime_compat_host.sh

printf '%s\n' '[15/25] Run device evidence host vectors'
bash tests/test_device_evidence_host.sh

printf '%s\n' '[16/25] Run Ed25519 shell verification vectors'
bash tests/test_kpm_verify.sh

printf '%s\n' '[17/25] Run kptools argv vectors'
bash tests/test_kptools_argv.sh

printf '%s\n' '[18/25] Run Monocypher metadata fixture tests'
python3 tests/test_monocypher_pin.py

printf '%s\n' '[19/25] Run signing-key consistency tests'
python3 tests/test_signing_key_policy.py
python3 scripts/verify_signing_key_policy.py --root "$ROOT"

printf '%s\n' '[20/25] Verify release-candidate preflight and pipeline order'
bash tests/test_release_candidate_gate.sh
python3 tests/validate_release_candidate_pipeline.py

printf '%s\n' '[21/25] Run release metadata tests and current-tree validation'
python3 tests/test_release_metadata.py
python3 scripts/verify_release_metadata.py --root "$ROOT"

printf '%s\n' '[22/25] Run machine-enforced release gates in structure mode'
bash scripts/run_release_gate_checks.sh

printf '%s\n' '[23/25] Generate repository audit report'
python3 scripts/offline_audit.py --root "$ROOT" --output-dir audit-output --no-syntax

printf '%s\n' '[24/25] Parse shell scripts'
bash -n \
  build.sh \
  scripts/build_release_candidate.sh \
  scripts/run_evidence_gate_checks.sh \
  scripts/run_evidence_offline_tests.sh \
  scripts/run_offline_checks.sh \
  scripts/run_release_gate_checks.sh \
  scripts/run_transaction_offline_checks.sh \
  scripts/run_webui_offline_checks.sh \
  tests/test_device_evidence_host.sh \
  tests/test_flash_compat_gate.sh \
  tests/test_kpm_install_recovery.sh \
  tests/test_kpm_transaction_store.sh \
  tests/test_kpm_verify.sh \
  tests/test_kpm_verify_cli_source.sh \
  tests/test_kptools_argv.sh \
  tests/test_release_candidate_gate.sh \
  tests/test_runtime_compat_host.sh
while IFS= read -r script; do
  bash -n "$script"
done < <(find module/patch module scripts -type f -name '*.sh' -print | LC_ALL=C sort)

printf '%s\n' '[25/25] Parse JavaScript modules'
while IFS= read -r source; do
  node --check "$source"
done < <(find webui -type f -name '*.js' \
  ! -path 'webui/node_modules/*' \
  ! -path 'webui/dist/*' \
  | LC_ALL=C sort)

printf '%s\n' 'All source-only offline checks completed.'
printf '%s\n' 'Release readiness requires: bash scripts/run_evidence_gate_checks.sh out/PatchNest-Module.zip /secure/evidence/matrices'
printf '%s\n' 'Run scripts/run_webui_offline_checks.sh when committed node_modules are already installed locally.'
