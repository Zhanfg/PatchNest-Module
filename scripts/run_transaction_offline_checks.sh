#!/usr/bin/env bash
# Run KPM transaction and durable-install checks without network or Actions.
set -euo pipefail
IFS=$'\n\t'

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

for command_name in python3 bash sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: $command_name is required" >&2
    exit 1
  }
done

printf '%s\n' '[1/6] Parse transaction shell sources'
bash -n \
  module/kpm_transaction_store.sh \
  module/kpm_install_recovery.sh \
  module/manage_kpm_quarantine.sh \
  tests/test_kpm_transaction_store.sh \
  tests/test_kpm_install_recovery.sh

printf '%s\n' '[2/6] Compile transaction contract tests'
python3 -m py_compile \
  tests/validate_transaction_store.py \
  tests/validate_transaction_visibility.py \
  tests/validate_install_recovery.py

printf '%s\n' '[3/6] Validate transaction store contracts'
python3 tests/validate_transaction_store.py

printf '%s\n' '[4/6] Validate transaction visibility contracts'
python3 tests/validate_transaction_visibility.py

printf '%s\n' '[5/6] Run transaction rollback vectors'
bash tests/test_kpm_transaction_store.sh

printf '%s\n' '[6/6] Run durable install recovery vectors'
python3 tests/validate_install_recovery.py
bash tests/test_kpm_install_recovery.sh

printf '%s\n' 'All focused KPM transaction checks completed.'
