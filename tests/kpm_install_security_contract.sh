#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p /data/local/tmp

fail() {
    echo "KPM install security contract: FAIL: $*" >&2
    exit 1
}
command -v zip >/dev/null 2>&1 || fail "zip missing"
command -v unzip >/dev/null 2>&1 || fail "unzip missing"
command -v xxd >/dev/null 2>&1 || fail "xxd missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

MOD="$TMP/module"
STATE="$TMP/state"
mkdir -p "$MOD/bin" "$STATE"
sed "s#PNDIR=\"/data/adb/patchnest\"#PNDIR=\"$STATE\"#" \
    "$ROOT/module/install_kpm.sh" > "$MOD/install_kpm.sh"
chmod 0755 "$MOD/install_kpm.sh"

cat > "$MOD/bin/kptools" <<'EOF'
#!/bin/sh
printf '%s\n' '[kpm]' 'name=contract_module' 'version=1.0.0'
exit 0
EOF
chmod 0755 "$MOD/bin/kptools"
cat > "$MOD/bin/kpatch" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/kpatch.calls"
exit 0
EOF
chmod 0755 "$MOD/bin/kpatch"

make_elf() {
    _pn_path=$1
    _pn_machine=$2
    python3 - "$_pn_path" "$_pn_machine" <<'PY'
import sys
p = sys.argv[1]
machine = int(sys.argv[2], 0)
b = bytearray(64)
b[0:4] = b'\x7fELF'
b[4] = 2
b[5] = 1
b[6] = 1
b[16:18] = (1).to_bytes(2, 'little')
b[18:20] = machine.to_bytes(2, 'little')
with open(p, 'wb') as f:
    f.write(b)
PY
}

make_zip() {
    _pn_dir=$1
    _pn_zip=$2
    (cd "$_pn_dir" && zip -q "$_pn_zip" module.prop module.kpm)
}

# 1. Valid ARM64 package installs atomically and autoLoad=true creates marker.
SAFE="$TMP/safe"
mkdir -p "$SAFE"
cat > "$SAFE/module.prop" <<'EOF'
id=safe_mod
name=Safe Module
version=1.0.0
autoLoad=true
args=mode=test
EOF
make_elf "$SAFE/module.kpm" 0xb7
make_zip "$SAFE" "$TMP/safe.zip"
sh "$MOD/install_kpm.sh" "$TMP/safe.zip" >/dev/null
[ -f "$STATE/kpm/safe_mod.kpm" ] || fail "valid ARM64 KPM not installed"
[ -f "$STATE/kpm_events/safe_mod.autoload" ] || fail "autoLoad=true marker missing"
grep -Fq 'kpm load' "$TMP/kpatch.calls" || fail "autoLoad=true did not attempt immediate load"

# 2. autoLoad=false must not create marker or invoke immediate kernel load.
DISABLED="$TMP/disabled"
mkdir -p "$DISABLED"
cat > "$DISABLED/module.prop" <<'EOF'
id=disabled_mod
name=Disabled Module
version=1.0.0
autoLoad=false
EOF
make_elf "$DISABLED/module.kpm" 0xb7
make_zip "$DISABLED" "$TMP/disabled.zip"
: > "$TMP/kpatch.calls"
sh "$MOD/install_kpm.sh" "$TMP/disabled.zip" >/dev/null
[ -f "$STATE/kpm/disabled_mod.kpm" ] || fail "autoload-disabled KPM not installed"
[ ! -e "$STATE/kpm_events/disabled_mod.autoload" ] || fail "autoLoad=false still created marker"
[ ! -s "$TMP/kpatch.calls" ] || fail "autoLoad=false still invoked kernel load"

# 3. Non-AArch64 ELF is rejected before persistent module installation.
BADARCH="$TMP/badarch"
mkdir -p "$BADARCH"
cat > "$BADARCH/module.prop" <<'EOF'
id=badarch
name=Bad Arch
version=1.0.0
autoLoad=true
EOF
make_elf "$BADARCH/module.kpm" 0x3e
make_zip "$BADARCH" "$TMP/badarch.zip"
set +e
sh "$MOD/install_kpm.sh" "$TMP/badarch.zip" >/dev/null 2>&1
badarch_rc=$?
set -e
[ "$badarch_rc" -ne 0 ] || fail "non-AArch64 KPM was accepted"
[ ! -e "$STATE/kpm/badarch.kpm" ] || fail "non-AArch64 KPM reached persistent state"

# 4. Traversal entry is rejected before archive bytes are materialized.
python3 - "$TMP/traversal.zip" <<'PY'
import zipfile, sys
p = sys.argv[1]
with zipfile.ZipFile(p, 'w') as z:
    z.writestr('module.prop', 'id=traversal\nname=Traversal\nversion=1\nautoLoad=true\n')
    z.writestr('module.kpm', b'not-important')
    z.writestr('../../escape.txt', b'escape')
PY
set +e
sh "$MOD/install_kpm.sh" "$TMP/traversal.zip" >/dev/null 2>&1
traversal_rc=$?
set -e
[ "$traversal_rc" -ne 0 ] || fail "traversal archive was accepted"
[ ! -e "$TMP/escape.txt" ] || fail "traversal archive wrote outside workspace"
[ ! -e "$STATE/kpm/traversal.kpm" ] || fail "traversal package reached persistent state"

# 5. Ambiguous multiple-binary package is rejected instead of arbitrary choice.
MULTI="$TMP/multi"
mkdir -p "$MULTI"
cat > "$MULTI/module.prop" <<'EOF'
id=multi
name=Multi
version=1
autoLoad=true
EOF
make_elf "$MULTI/a.kpm" 0xb7
make_elf "$MULTI/b.kpm" 0xb7
(cd "$MULTI" && zip -q "$TMP/multi.zip" module.prop a.kpm b.kpm)
set +e
sh "$MOD/install_kpm.sh" "$TMP/multi.zip" >/dev/null 2>&1
multi_rc=$?
set -e
[ "$multi_rc" -ne 0 ] || fail "multi-binary package was accepted"
[ ! -e "$STATE/kpm/multi.kpm" ] || fail "multi-binary package reached persistent state"

# 6. Physical FR-014 candidate refuses persistent KPM install entirely.
printf '%s\n' candidate > "$MOD/FR014_DEVICE_CANDIDATE"
set +e
sh "$MOD/install_kpm.sh" "$TMP/safe.zip" >/dev/null 2>&1
candidate_rc=$?
set -e
[ "$candidate_rc" -eq 3 ] || fail "FR-014 candidate did not reject persistent KPM install with rc=3"

echo "KPM install security contract: PASS"
