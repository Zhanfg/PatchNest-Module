#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
    echo "candidate prepatch idle contract: FAIL: $*" >&2
    exit 1
}

# ---- post-fs-data: stock prepatch candidate boots never count as failures ----
POSTMOD="$TMP/postmod"
POSTSTATE="$TMP/poststate"
SERVICED="$TMP/service.d"
mkdir -p "$POSTMOD" "$POSTSTATE" "$SERVICED"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$POSTMOD/status.sh"
chmod 0755 "$POSTMOD/status.sh"
printf '%s\n' candidate > "$POSTMOD/FR014_DEVICE_CANDIDATE"
sed \
  -e "s#SERVICE_D=\"/data/adb/service.d\"#SERVICE_D=\"$SERVICED\"#" \
  -e "s#PNDIR=\"/data/adb/patchnest\"#PNDIR=\"$POSTSTATE\"#" \
  "$ROOT/module/post-fs-data.sh" > "$POSTMOD/post-fs-data.sh"
chmod 0755 "$POSTMOD/post-fs-data.sh"

for _pn_i in 1 2 3 4; do
    sh "$POSTMOD/post-fs-data.sh"
    [ "$(cat "$POSTSTATE/boot_count")" = "0" ] || fail "prepatch candidate boot incremented failure counter"
    [ ! -e "$POSTSTATE/auto_unpatch_requested" ] || fail "prepatch candidate armed auto rollback"
    [ ! -e "$POSTSTATE/autorecovery_active" ] || fail "prepatch candidate surfaced autorecovery marker"
done

# Durable patch evidence immediately re-enables the bootloop counter.
printf '%s\n' '{}' > "$POSTSTATE/last_flash.json"
sh "$POSTMOD/post-fs-data.sh"
[ "$(cat "$POSTSTATE/boot_count")" = "1" ] || fail "patched-evidence boot did not increment counter"

# ---- service: prepatch idle must not even probe kernel ABI ------------------
MOD="$TMP/service-module"
STATE="$TMP/service-state"
mkdir -p "$MOD/bin" "$MOD/patch" "$STATE"
printf '%s\n' candidate > "$MOD/FR014_DEVICE_CANDIDATE"
cat > "$MOD/bin/kpatch" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/kpatch.calls"
exit 1
EOF
chmod 0755 "$MOD/bin/kpatch"
cat > "$MOD/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$MOD/bin/sleep"
printf '%s\n' '#!/bin/sh' > "$MOD/kpm_verify.sh"
printf '%s\n' '#!/bin/sh' > "$MOD/patch/superkey_safety.sh"
printf '%s\n' '#!/bin/sh' > "$MOD/patch/transaction_safety.sh"
sed "s#PNDIR=\"/data/adb/patchnest\"#PNDIR=\"$STATE\"#" "$ROOT/module/service.sh" > "$MOD/service.sh"
chmod 0755 "$MOD/service.sh"

PATH="$MOD/bin:$PATH" sh "$MOD/service.sh"
[ ! -e "$TMP/kpatch.calls" ] || fail "prepatch idle service probed kpatch ABI"
[ ! -e "$MOD/unresolved" ] || fail "prepatch idle service marked module unresolved"
grep -Fq 'FR-014 candidate pre-patch idle' "$STATE/service.log" || fail "prepatch idle state was not logged"
[ "$(cat "$STATE/boot_count")" = "0" ] || fail "service did not keep prepatch counter at zero"

# Once durable patch evidence exists, hello failure is a real unresolved state.
printf '%s\n' '{}' > "$STATE/last_flash.json"
rm -f "$TMP/kpatch.calls" "$MOD/unresolved"
PATH="$MOD/bin:$PATH" sh "$MOD/service.sh"
[ -s "$TMP/kpatch.calls" ] || fail "patched-evidence service skipped ABI probe"
[ -e "$MOD/unresolved" ] || fail "patched-evidence hello failure was not marked unresolved"

echo "candidate prepatch idle contract: PASS"
