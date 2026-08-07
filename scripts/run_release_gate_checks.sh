#!/usr/bin/env bash
# Run PatchNest machine-enforced release gates without GitHub Actions.
set -euo pipefail
IFS=$'\n\t'
export PYTHONDONTWRITEBYTECODE=1

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

RELEASE_READY=false
CANDIDATE=""
MATRIX_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-ready) RELEASE_READY=true; shift ;;
    --candidate)
      [[ $# -ge 2 ]] || { echo 'ERROR: --candidate requires a path' >&2; exit 2; }
      CANDIDATE=$2; shift 2 ;;
    --matrix-dir)
      [[ $# -ge 2 ]] || { echo 'ERROR: --matrix-dir requires a path' >&2; exit 2; }
      MATRIX_DIR=$2; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--release-ready] [--candidate out/PatchNest-Module.zip] [--matrix-dir /path/to/evidence-matrices]"
      exit 0
      ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "$RELEASE_READY" == true ]]; then
  [[ -n "$CANDIDATE" ]] || { echo 'ERROR: --release-ready requires --candidate' >&2; exit 2; }
  [[ -n "$MATRIX_DIR" ]] || { echo 'ERROR: --release-ready requires --matrix-dir outside the repository' >&2; exit 2; }
fi

COMMON=(--root "$ROOT")
READY=()
CANDIDATE_ARGS=()
MATRIX_ARGS=()
[[ "$RELEASE_READY" == true ]] && READY=(--release-ready)
[[ -n "$CANDIDATE" ]] && CANDIDATE_ARGS=(--candidate "$CANDIDATE")
[[ -n "$MATRIX_DIR" ]] && MATRIX_ARGS=(--matrix-dir "$MATRIX_DIR")

python3 release_gate/check_git_clean.py "${COMMON[@]}" "${READY[@]}"
python3 release_gate/check_signature.py "${COMMON[@]}" "${READY[@]}" "${CANDIDATE_ARGS[@]}"
python3 release_gate/check_boot_matrix.py "${COMMON[@]}" "${READY[@]}" "${MATRIX_ARGS[@]}"
python3 release_gate/check_module_layout.py "${COMMON[@]}" "${READY[@]}" "${CANDIDATE_ARGS[@]}"
python3 release_gate/check_permissions.py "${COMMON[@]}" "${READY[@]}" "${CANDIDATE_ARGS[@]}"

echo 'All requested release gates passed.'
