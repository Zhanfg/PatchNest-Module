#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
POSTFS="$ROOT/module/post-fs-data.sh"
SERVICE="$ROOT/module/service.sh"

fail() {
    echo "bootloop recovery contract: FAIL: $*" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# ---- Phase 1: three unconfirmed boots must arm recovery ---------------------
POSTDIR="$TMP/postfs-module"
POSTSTATE="$TMP/postfs-state"
SERVICED="$TMP/service.d"
mkdir -p "$POSTDIR" "$POSTSTATE" "$SERVICED"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$POSTDIR/status.sh"
chmod 0755 "$POSTDIR/status.sh"

# Redirect only hard-coded persistent paths; execute production logic otherwise.
sed \
  -e "s#SERVICE_D=\"/data/adb/service.d\"#SERVICE_D=\"$SERVICED\"#" \
  -e "s#PNDIR=\"/data/adb/patchnest\"#PNDIR=\"$POSTSTATE\"#" \
  "$POSTFS" > "$POSTDIR/post-fs-data.sh"
chmod 0755 "$POSTDIR/post-fs-data.sh"

sh "$POSTDIR/post-fs-data.sh"
[ "$(cat "$POSTSTATE/boot_count")" = "1" ] || fail "first boot did not increment counter to 1"
[ ! -e "$POSTSTATE/auto_unpatch_requested" ] || fail "recovery armed too early after first boot"
sh "$POSTDIR/post-fs-data.sh"
[ "$(cat "$POSTSTATE/boot_count")" = "2" ] || fail "second boot did not increment counter to 2"
[ ! -e "$POSTSTATE/auto_unpatch_requested" ] || fail "recovery armed too early after second boot"
sh "$POSTDIR/post-fs-data.sh"
[ "$(cat "$POSTSTATE/boot_count")" = "3" ] || fail "third boot did not reach threshold 3"
[ -e "$POSTSTATE/auto_unpatch_requested" ] || fail "third failed boot did not arm auto rollback"
[ -e "$POSTSTATE/autorecovery_active" ] || fail "third failed boot did not surface recovery marker"

# ---- Phase 2: service must restore before any normal mutation ---------------
MOD="$TMP/runtime-module"
STATE="$TMP/runtime-state"
TARGET="$TMP/boot-target.img"
mkdir -p "$MOD/bin" "$MOD/patch" "$STATE/kpm/failed" "$STATE/kpm_events"
printf '%s\n' 'patched boot' > "$TARGET"
touch "$STATE/auto_unpatch_requested"
printf '3\n' > "$STATE/boot_count"

# service requires an executable kpatch, but auto-recovery must exit before it
# is invoked. Any invocation is recorded as a contract failure.
cat > "$MOD/bin/kpatch" <<EOF
#!/bin/sh
printf 'kpatch-called:%s\n' "\$*" >> "$TMP/kpatch.calls"
exit 99
EOF
chmod 0755 "$MOD/bin/kpatch"

# Fake Android power-control command: record reboot request without rebooting CI.
cat > "$MOD/bin/setprop" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/setprop.calls"
exit 0
EOF
chmod 0755 "$MOD/bin/setprop"

cat > "$MOD/patch/boot_extract.sh" <<EOF
#!/bin/sh
printf 'BOOTIMAGE=%s\n' "$TARGET"
EOF
chmod 0755 "$MOD/patch/boot_extract.sh"

cat > "$MOD/patch/boot_unpatch.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/restore.calls"
[ "\${1:-}" = '--restore-bound-backup' ] || exit 91
[ "\${2:-}" = '$TARGET' ] || exit 92
exit 0
EOF
chmod 0755 "$MOD/patch/boot_unpatch.sh"

# Optional sourced helpers may be absent on the success path; create no-op
# files to keep this harness explicit and close to package layout.
printf '%s\n' '#!/bin/sh' > "$MOD/kpm_verify.sh"
printf '%s\n' '#!/bin/sh' > "$MOD/patch/superkey_safety.sh"
printf '%s\n' '#!/bin/sh' > "$MOD/patch/transaction_safety.sh"

sed "s#PNDIR=\"/data/adb/patchnest\"#PNDIR=\"$STATE\"#" "$SERVICE" > "$MOD/service.sh"
chmod 0755 "$MOD/service.sh"

PATH="$MOD/bin:$PATH" sh "$MOD/service.sh"

[ -s "$TMP/restore.calls" ] || fail "service did not invoke transaction-bound restore"
grep -Fxq -- "--restore-bound-backup $TARGET" "$TMP/restore.calls" \
    || fail "service restore did not bind exact target"
[ ! -e "$TMP/kpatch.calls" ] || fail "service invoked kpatch before automatic rollback"
[ -e "$STATE/auto_recovery_restored" ] || fail "service did not record successful auto recovery"
[ ! -e "$STATE/auto_unpatch_requested" ] || fail "service left auto-unpatch request armed after restore"
grep -Fxq 'sys.powerctl reboot' "$TMP/setprop.calls" || fail "service did not request reboot after rollback"

# The boot counter may only be reset inside the boot_completed branch, never
# immediately after hello. Keep this ordering assertion alongside execution.
complete_line=$(grep -n 'if \[ "$(getprop sys.boot_completed)" = "1" \]; then' "$SERVICE" | tail -n1 | cut -d: -f1)
reset_line=$(grep -n 'echo "0" > "$BOOT_COUNT_FILE"' "$SERVICE" | tail -n1 | cut -d: -f1)
[ -n "$complete_line" ] && [ -n "$reset_line" ] || fail "healthy-boot reset structure missing"
[ "$reset_line" -gt "$complete_line" ] || fail "boot counter resets before boot_completed proof"

# Auto-recovery handling must precede the normal hello retry loop.
auto_line=$(grep -n 'handle_requested_auto_recovery' "$SERVICE" | tail -n1 | cut -d: -f1)
hello_loop_line=$(grep -n '^while \[ "$retries" -lt "$max_retries" \]; do' "$SERVICE" | head -n1 | cut -d: -f1)
[ "$auto_line" -lt "$hello_loop_line" ] || fail "normal ABI probing can run before auto-recovery gate"

echo "bootloop recovery contract: PASS"
