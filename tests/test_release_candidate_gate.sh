#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUTPUT=$(mktemp)
trap 'rm -f "$OUTPUT"' EXIT

set +e
bash "$ROOT/scripts/build_release_candidate.sh" >"$OUTPUT" 2>&1
RC=$?
set -e

if [[ "$RC" -eq 0 ]]; then
  echo 'release candidate build unexpectedly passed with a development key' >&2
  exit 1
fi
grep -q 'requires kpm_signing_key_status=production' "$OUTPUT"
if grep -q '^Built ' "$OUTPUT"; then
  echo 'build.sh was reached before the production-key gate' >&2
  exit 1
fi

printf '%s\n' 'Release candidate signing-key gate passed.'
