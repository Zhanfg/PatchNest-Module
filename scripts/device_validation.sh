#!/bin/sh
# Source-tree convenience wrapper. The canonical, packaged physical-device
# validation harness lives at module/device_validation.sh.

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
exec "$ROOT/module/device_validation.sh" "$@"
