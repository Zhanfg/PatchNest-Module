#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE="$ROOT/module/service.sh"
VERSIONS="$ROOT/version.properties"

fail() {
    echo "runtime ABI contract: FAIL: $*" >&2
    exit 1
}

# Successful hello values must map to explicit profiles; there is no generic
# "non-empty output means ready" path.
grep -Fq 'hello1158) ABI_PROFILE=public1158' "$SERVICE" || fail "Public1158 hello mapping missing"
grep -Fq 'hello2026) ABI_PROFILE=next2026' "$SERVICE" || fail "Next2026 hello mapping missing"
grep -Fq 'unrecognized successful hello response' "$SERVICE" || fail "unknown hello is not fail-closed"

# Public1158 command 0x1100/0x1101 means SU grant/revoke, not rehook. The
# service must branch on profile before any `kpatch rehook` invocation.
public_guard=$(grep -n 'if \[ "$ABI_PROFILE" = "public1158" \]; then' "$SERVICE" | head -n1 | cut -d: -f1 || true)
rehook_call=$(grep -n 'kpatch rehook' "$SERVICE" | head -n1 | cut -d: -f1 || true)
[ -n "$public_guard" ] || fail "Public1158 rehook guard missing"
[ -n "$rehook_call" ] || fail "Next2026 rehook call missing"
[ "$public_guard" -lt "$rehook_call" ] || fail "rehook call occurs before Public1158 guard"
grep -Fq 'rehook request ignored: unsupported and unsafe on Public1158' "$SERVICE" || fail "Public1158 rehook rejection is not explicit"

# KPM event dispatch is a reviewed Public1158 capability only.
grep -Fq 'if [ "$ABI_PROFILE" != "public1158" ]; then' "$SERVICE" || fail "event dispatch is not profile-gated"
grep -Fq 'kpatch event "$event_name" "PatchNest" ""' "$SERVICE" || fail "Public1158 event dispatch missing"

# The module may only build the separately reviewed Public1158 compatibility
# binary. Reintroducing the historical Next release asset is forbidden.
grep -Fq 'patchnest_public1158_commit=' "$VERSIONS" || fail "Public1158 source pin missing"
! grep -q '^kpatch_android_' "$VERSIONS" || fail "Next2026 release binary pin reintroduced"

echo "runtime ABI contract: PASS"
