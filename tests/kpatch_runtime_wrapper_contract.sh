#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
BIN="$MOD/bin"
mkdir -p "$BIN"

fail() {
    echo "kpatch runtime wrapper contract: FAIL: $*" >&2
    exit 1
}

cp "$ROOT/module/kpatch_runtime_wrapper.sh" "$BIN/kpatch"
chmod 0755 "$BIN/kpatch"

# The heredoc intentionally writes literal shell expansions for the generated
# fake executable; they must expand when that fixture runs, not while this test
# creates it.
# shellcheck disable=SC2016
cat > "$BIN/kpatch.real" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/real.calls"
case "\${1:-}" in
  hello) printf '%s\n' hello1158 ;;
esac
exit 0
EOF
chmod 0755 "$BIN/kpatch.real"

# shellcheck disable=SC2016
cat > "$MOD/validate_kpm_file.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$TMP/validator.calls"
case "\${PATCHNEST_TEST_VALIDATOR_RC:-0}" in
  0) exit 0 ;;
  *) exit "\$PATCHNEST_TEST_VALIDATOR_RC" ;;
esac
EOF
chmod 0755 "$MOD/validate_kpm_file.sh"

printf '%s\n' synthetic > "$TMP/module.kpm"

# 1. Non-load commands delegate unchanged and never invoke KPM admission.
PATH="$BIN:$PATH" "$BIN/kpatch" hello > "$TMP/hello.out"
[ "$(cat "$TMP/hello.out")" = "hello1158" ] || fail "hello output was not delegated unchanged"
grep -Fxq 'hello' "$TMP/real.calls" || fail "hello did not reach real CLI"
[ ! -e "$TMP/validator.calls" ] || fail "non-KPM command invoked KPM validator"

# 2. kpm load must validate before real CLI and preserve all argv content.
: > "$TMP/real.calls"
PATH="$BIN:$PATH" "$BIN/kpatch" kpm load "$TMP/module.kpm" 'mode=test value=2'
[ "$(cat "$TMP/validator.calls")" = "$TMP/module.kpm" ] || fail "KPM path was not sent to validator"
grep -Fxq "kpm load $TMP/module.kpm mode=test value=2" "$TMP/real.calls" \
    || fail "validated KPM load was not delegated with original argv"

# 3. Validator rejection must prevent any kernel CLI invocation.
: > "$TMP/real.calls"
: > "$TMP/validator.calls"
set +e
PATCHNEST_TEST_VALIDATOR_RC=17 PATH="$BIN:$PATH" "$BIN/kpatch" kpm load "$TMP/module.kpm" rejected >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 17 ] || fail "validator rejection status was not propagated (rc=$rc)"
[ ! -s "$TMP/real.calls" ] || fail "rejected KPM still reached kpatch.real"
[ "$(cat "$TMP/validator.calls")" = "$TMP/module.kpm" ] || fail "rejected KPM was not validated first"

# 4. Missing validator fails closed before real CLI.
rm -f "$MOD/validate_kpm_file.sh"
: > "$TMP/real.calls"
set +e
PATH="$BIN:$PATH" "$BIN/kpatch" kpm load "$TMP/module.kpm" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "missing validator did not fail closed with rc=3 (rc=$rc)"
[ ! -s "$TMP/real.calls" ] || fail "missing-validator path reached kpatch.real"

# 5. Missing real CLI fails closed for every command.
mv "$BIN/kpatch.real" "$BIN/kpatch.real.missing"
set +e
PATH="$BIN:$PATH" "$BIN/kpatch" hello >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 127 ] || fail "missing real CLI did not fail with rc=127 (rc=$rc)"

echo "kpatch runtime wrapper contract: PASS"
