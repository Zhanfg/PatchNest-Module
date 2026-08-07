#!/usr/bin/env bash
# Run the WebUI test/build suite without fetching dependencies.
set -euo pipefail
IFS=$'\n\t'

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WEBUI="$ROOT/webui"
cd "$WEBUI"

for command_name in node pnpm; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: $command_name is required" >&2
    exit 1
  }
done

if [[ ! -x node_modules/.bin/vitest || ! -x node_modules/.bin/vite ]]; then
  cat >&2 <<'EOF'
ERROR: webui/node_modules is not prepared.
This entrypoint intentionally never downloads dependencies.
Prepare the exact committed lockfile in a network-enabled environment first:
  cd webui
  pnpm install --frozen-lockfile
Then rerun this script offline.
EOF
  exit 1
fi

printf '%s\n' '[1/3] Parse WebUI JavaScript'
while IFS= read -r source; do
  node --check "$source"
done < <(find . -type f -name '*.js' \
  ! -path './node_modules/*' \
  ! -path './dist/*' \
  | LC_ALL=C sort)

printf '%s\n' '[2/3] Run Vitest suite'
pnpm test

printf '%s\n' '[3/3] Build WebUI from the existing dependency tree'
pnpm build --emptyOutDir

printf '%s\n' 'WebUI offline tests and build completed.'
