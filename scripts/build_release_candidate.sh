#!/usr/bin/env bash
# Build a publishable PatchNest candidate only after release-specific gates pass.
set -euo pipefail
IFS=$'\n\t'

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

for command_name in python3 bash; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  }
done

# Fail before any network or package work while the repository still uses the
# development signing key.
python3 scripts/verify_signing_key_policy.py --root "$ROOT" --release-ready

# Completed matrices cannot be committed without changing HEAD and invalidating
# their testedCommit fields. They must be supplied from a controlled evidence
# directory outside this Git work tree.
MATRIX_DIR=${PATCHNEST_MATRIX_DIR:-}
[[ -n "$MATRIX_DIR" ]] || {
  echo 'ERROR: PATCHNEST_MATRIX_DIR must point to completed external evidence matrices' >&2
  exit 1
}

# Once production-key custody is complete, bind the official GitHub tag and
# Release asset metadata to the pinned commit, asset name, digest, and URL.
python3 scripts/verify_monocypher_pin.py --root "$ROOT"
python3 scripts/verify_release_metadata.py --root "$ROOT"

# build.sh independently enforces a clean tree, pinned dependencies, the exact
# Android NDK revision, verifier vectors, and reproducible archive metadata.
bash "$ROOT/build.sh"

# A successful package build is not yet a release candidate. Re-check the exact
# ZIP, digest and provenance against the clean commit, production key, package
# layout, file modes, completed physical-device matrices, and every passing
# record's candidateSha256 binding.
bash "$ROOT/scripts/run_evidence_gate_checks.sh" \
  "$ROOT/out/PatchNest-Module.zip" \
  "$MATRIX_DIR"

printf '%s\n' 'Release candidate and external evidence gates passed.'
