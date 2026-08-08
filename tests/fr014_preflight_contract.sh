#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM
mkdir -p /data/local/tmp

fail() {
    echo "FR-014 preflight contract: FAIL: $*" >&2
    exit 1
}

make_fixture() {
    _pn_case=$1
    _pn_mod="$TMP/$_pn_case/module"
    _pn_state="$TMP/$_pn_case/state"
    _pn_evidence="$TMP/$_pn_case/evidence"
    _pn_target="$TMP/$_pn_case/boot.img"
    mkdir -p "$_pn_mod/bin" "$_pn_mod/patch" "$_pn_state" "$_pn_evidence"
    cp "$ROOT/module/device_validation.sh" "$_pn_mod/device_validation.sh"
    chmod 0755 "$_pn_mod/device_validation.sh"
    printf '%s\n' 'FR-014 synthetic candidate' > "$_pn_mod/FR014_DEVICE_CANDIDATE"
    printf '%s\n' 'synthetic-stock-boot' > "$_pn_target"

    cat > "$_pn_mod/patch/boot_extract.sh" <<EOF
#!/bin/sh
printf 'SLOT=_a\nBOOTIMAGE=%s\n' "$_pn_target"
EOF
    chmod 0755 "$_pn_mod/patch/boot_extract.sh"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$_pn_mod/patch/boot_unpatch.sh"
    chmod 0755 "$_pn_mod/patch/boot_unpatch.sh"
    cp "$ROOT/module/patch/transaction_safety.sh" "$_pn_mod/patch/transaction_safety.sh"
    cp "$ROOT/module/patch/fr014_gate.sh" "$_pn_mod/patch/fr014_gate.sh"
    : > "$_pn_mod/patch/transactional_flash.sh"

    cat > "$_pn_mod/bin/magiskboot" <<'EOF'
#!/bin/sh
[ "${1:-}" = "unpack" ] || exit 1
printf '%s\n' 'synthetic-kernel' > kernel
exit 0
EOF
    chmod 0755 "$_pn_mod/bin/magiskboot"

    cat > "$_pn_mod/bin/kptools" <<'EOF'
#!/bin/sh
if [ "${PATCHNEST_TEST_PATCHED:-0}" = "1" ]; then
    printf '%s\n' '[kernel]' 'patched=true'
else
    printf '%s\n' '[kernel]' 'patched=false'
fi
exit 0
EOF
    chmod 0755 "$_pn_mod/bin/kptools"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$_pn_mod/bin/kpatch"
    chmod 0755 "$_pn_mod/bin/kpatch"
    printf '%s\n' 'kpimg' > "$_pn_mod/bin/kpimg"

    cat > "$_pn_mod/bin/getprop" <<'EOF'
#!/bin/sh
case "${1:-}" in
  ro.boot.serialno|ro.serialno) printf '%s\n' 'SYNTHETIC-SERIAL' ;;
  ro.boot.slot_suffix) printf '%s\n' '_a' ;;
  ro.product.device) printf '%s\n' 'synthetic-device' ;;
  ro.boot.vbmeta.digest) printf '%s\n' 'synthetic-vbmeta' ;;
  ro.boot.vbmeta.device_state) printf '%s\n' 'unlocked' ;;
  sys.boot_completed) printf '%s\n' '1' ;;
  *) printf '%s\n' '' ;;
esac
EOF
    chmod 0755 "$_pn_mod/bin/getprop"

    FIX_MOD=$_pn_mod
    FIX_STATE=$_pn_state
    FIX_EVIDENCE=$_pn_evidence
    FIX_TARGET=$_pn_target
}

run_preflight() {
    PATCHNEST_TEST_PATCHED="${PATCHNEST_TEST_PATCHED:-0}" \
    PATCHNEST_MODDIR="$FIX_MOD" \
    PATCHNEST_STATE_DIR="$FIX_STATE" \
    PATCHNEST_EVIDENCE_DIR="$FIX_EVIDENCE" \
    PATH="$FIX_MOD/bin:$PATH" \
    sh "$FIX_MOD/device_validation.sh" preflight > "$FIX_EVIDENCE/stdout.log" 2>&1
}

# 1. Explicit candidate + stock kernel + empty historical state passes and
# creates a secure receipt bound to the exact target/candidate identity.
make_fixture clean
run_preflight || fail "clean candidate was rejected"
grep -Fq 'result=PREFLIGHT_PASS' "$FIX_EVIDENCE/validation.log" || fail "clean candidate did not emit PREFLIGHT_PASS"
[ -f "$FIX_STATE/fr014_preflight.json" ] || fail "clean preflight receipt missing"
[ "$(stat -c '%a' "$FIX_STATE/fr014_preflight.json")" = "600" ] || fail "preflight receipt is not mode 0600"
grep -Fq '"preflight_pass": true' "$FIX_STATE/fr014_preflight.json" || fail "preflight receipt missing pass marker"
grep -Fq "\"boot_target\": \"$FIX_TARGET\"" "$FIX_STATE/fr014_preflight.json" || fail "preflight receipt not bound to exact target"

# 2. Old runtime KPM would be auto-loaded by service and must block a clean test.
make_fixture old-kpm
mkdir -p "$FIX_STATE/kpm"
printf '%s\n' old > "$FIX_STATE/kpm/old.kpm"
if run_preflight; then fail "pre-existing KPM was accepted"; fi
grep -Fq 'pre-existing runtime KPM blocks clean FR-014 preflight' "$FIX_EVIDENCE/stdout.log" || fail "old KPM rejection reason missing"

# 3. Existing credential/transaction-era state invalidates new-key lifecycle proof.
make_fixture old-key
printf '%s\n' '0123456789abcdef0123456789abcdef0123456789abcdef' > "$FIX_STATE/superkey"
chmod 0600 "$FIX_STATE/superkey"
if run_preflight; then fail "historical superkey was accepted"; fi
grep -Fq 'stale PatchNest state blocks clean FR-014 preflight: superkey' "$FIX_EVIDENCE/stdout.log" || fail "old superkey rejection reason missing"

make_fixture old-binding
printf '%s\n' '{}' > "$FIX_STATE/rollback_binding.json"
chmod 0600 "$FIX_STATE/rollback_binding.json"
if run_preflight; then fail "historical rollback binding was accepted"; fi
grep -Fq 'stale PatchNest state blocks clean FR-014 preflight: rollback_binding.json' "$FIX_EVIDENCE/stdout.log" || fail "old binding rejection reason missing"

# 4. The pre-test boot kernel must not already be KernelPatch-patched.
make_fixture patched-kernel
if PATCHNEST_TEST_PATCHED=1 run_preflight; then fail "already-patched kernel was accepted"; fi
grep -Fq 'already KernelPatch-patched' "$FIX_EVIDENCE/stdout.log" || fail "patched-kernel rejection reason missing"

# 5. An unblocked module without the explicit physical-candidate marker fails.
make_fixture unmarked
rm -f "$FIX_MOD/FR014_DEVICE_CANDIDATE"
if run_preflight; then fail "unmarked unblocked package was accepted"; fi
grep -Fq 'unblocked package is not an FR-014 device candidate' "$FIX_EVIDENCE/stdout.log" || fail "candidate-marker rejection reason missing"

echo "FR-014 preflight contract: PASS"
