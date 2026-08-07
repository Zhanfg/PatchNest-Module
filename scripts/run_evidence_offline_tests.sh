#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

python3 -m py_compile \
  release_gate/check_matrix_candidate_binding.py \
  scripts/record_matrix_evidence.py \
  tests/test_matrix_candidate_binding.py \
  tests/test_record_matrix_evidence.py

python3 tests/test_matrix_candidate_binding.py
python3 tests/test_record_matrix_evidence.py
bash -n scripts/run_evidence_gate_checks.sh scripts/run_evidence_offline_tests.sh

echo 'Evidence recorder and candidate-binding tests passed.'
