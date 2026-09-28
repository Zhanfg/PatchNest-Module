#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
    echo "KPM runtime admission contract: FAIL: $*" >&2
    exit 1
}
command -v xxd >/dev/null 2>&1 || fail "xxd missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

MOD="$TMP/module"
STATE="$TMP/state"
mkdir -p "$MOD/bin" "$MOD/patch" "$STATE/kpm/failed" "$STATE/kpm_events"

# Signature policy off isolates this contract to autoload/binary admission.
printf '%s\n' 'KPM_SIGNATURE_POLICY=off' > "$STATE/config"

cat > "$MOD/bin/kpatch" <<EOF
#!/bin/sh
case "\${1:-}" in
  hello) printf '%s\n' hello1158; exit 0 ;;
  *) printf '%s\n' "\$*" >> "$TMP/kpatch.calls"; exit 0 ;;
esac
EOF
chmod 0755 "$MOD/bin/kpatch"
cat > "$MOD/bin/kptools" <<'EOF'
#!/bin/sh
printf '%s\n' '[kpm]' 'name=runtime_contract'
exit 0
EOF
chmod 0755 "$MOD/bin/kptools"
cat > "$MOD/bin/getprop" <<'EOF'
#!/bin/sh
case "${1:-}" in
  sys.boot_completed) printf '%s\n' 1 ;;
  *) printf '%s\n' '' ;;
esac
EOF
chmod 0755 "$MOD/bin/getprop"
cat > "$MOD/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$MOD/bin/sleep"

printf '%s\n' '#!/bin/sh' > "$MOD/kpm_verify.sh"
printf '%s\n' '#!/bin/sh' > "$MOD/patch/superkey_safety.sh"
printf '%s\n' '#!/bin/sh' > "$MOD/patch/transaction_safety.sh"

make_elf() {
    _pn_path=$1
    _pn_machine=$2
    python3 - "$_pn_path" "$_pn_machine" <<'PY'
import sys
p=sys.argv[1]; machine=int(sys.argv[2],0)
b=bytearray(64)
b[0:4]=b'\x7fELF'; b[4]=2; b[5]=1; b[6]=1
b[16:18]=(1).to_bytes(2,'little'); b[18:20]=machine.to_bytes(2,'little')
open(p,'wb').write(b)
PY
}

make_elf "$STATE/kpm/enabled.kpm" 0xb7
make_elf "$STATE/kpm/disabled.kpm" 0xb7
make_elf "$STATE/kpm/badarch.kpm" 0x3e
touch "$STATE/kpm_events/enabled.autoload"
touch "$STATE/kpm_events/badarch.autoload"

sed "s#PNDIR=\"/data/adb/patchnest\"#PNDIR=\"$STATE\"#" "$ROOT/module/service.sh" > "$MOD/service.sh"
chmod 0755 "$MOD/service.sh"

PATH="$MOD/bin:$PATH" sh "$MOD/service.sh"

# enabled is the only valid explicitly-autoloaded module.
grep -Fq "kpm load $STATE/kpm/enabled.kpm" "$TMP/kpatch.calls" \
    || fail "valid autoload-enabled KPM was not loaded"
if grep -Fq "kpm load $STATE/kpm/disabled.kpm" "$TMP/kpatch.calls"; then
    fail "autoload-disabled KPM was loaded"
fi
if grep -Fq "kpm load $STATE/kpm/badarch.kpm" "$TMP/kpatch.calls"; then
    fail "non-AArch64 KPM reached kpatch load"
fi
[ -f "$STATE/kpm/disabled.kpm" ] || fail "autoload-disabled KPM was incorrectly removed"
[ -f "$STATE/kpm/failed/badarch.kpm" ] || fail "invalid KPM was not quarantined"
[ ! -e "$STATE/kpm_events/badarch.autoload" ] || fail "invalid KPM autoload marker survived quarantine"
grep -Fq 'KPM autoload disabled or unregistered: disabled.kpm' "$STATE/service.log" \
    || fail "autoload-disabled decision not logged"
grep -Fq 'REJECTED (invalid/non-AArch64 KPM): badarch.kpm' "$STATE/service.log" \
    || fail "runtime binary rejection not logged"

echo "KPM runtime admission contract: PASS"
