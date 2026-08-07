#!/usr/bin/env bash
# Validate one release candidate against completed external evidence matrices.
set -euo pipefail
IFS=$'\n\t'
export PYTHONDONTWRITEBYTECODE=1

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CANDIDATE=${1:-}
MATRIX_DIR=${2:-}

[[ -n "$CANDIDATE" && -n "$MATRIX_DIR" ]] || {
  echo "Usage: $0 out/PatchNest-Module.zip /external/evidence/matrices" >&2
  exit 2
}

bash "$ROOT/scripts/run_release_gate_checks.sh" \
  --release-ready \
  --candidate "$CANDIDATE" \
  --matrix-dir "$MATRIX_DIR"

python3 "$ROOT/release_gate/check_matrix_candidate_binding.py" \
  --root "$ROOT" \
  --candidate "$CANDIDATE" \
  --matrix-dir "$MATRIX_DIR"

echo 'External evidence and candidate binding gates passed.'
