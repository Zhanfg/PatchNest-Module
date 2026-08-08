#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CUSTOMIZE="$ROOT/module/customize.sh"

fail() {
    echo "installer contract: FAIL: $*" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Production installer must never hard-code the final module directory or copy
# the extracted module tree into another location. MODPATH is the install root.
! grep -Fq '/data/adb/modules/PatchNest' "$CUSTOMIZE" \
    || fail "installer hard-codes /data/adb/modules/PatchNest"
! grep -Eq 'cp[[:space:]].*\$MODPATH/(bin|patch|webroot).*\/data\/adb\/modules' "$CUSTOMIZE" \
    || fail "installer copies extracted module tree to a second manager path"
grep -Fq 'set_perm_recursive "$MODPATH/bin"' "$CUSTOMIZE" || fail "installer does not permission binaries in MODPATH"
grep -Fq 'set_perm_recursive "$MODPATH/patch"' "$CUSTOMIZE" || fail "installer does not permission patch helpers in MODPATH"

make_fake_module() {
    _pn_dir=$1
    mkdir -p "$_pn_dir/bin" "$_pn_dir/patch"
    for _pn_bin in kpatch kptools magiskboot; do
        printf '%s\n' '#!/bin/sh' 'exit 0' > "$_pn_dir/bin/$_pn_bin"
        chmod 0644 "$_pn_dir/bin/$_pn_bin"
    done
    printf '%s\n' 'fake-kpimg' > "$_pn_dir/bin/kpimg"
    chmod 0644 "$_pn_dir/bin/kpimg"

    for _pn_script in \
        boot_patch.sh boot_extract.sh boot_unpatch.sh flash_safety.sh \
        transaction_safety.sh transactional_flash.sh superkey_safety.sh; do
        printf '%s\n' '#!/bin/sh' 'exit 0' > "$_pn_dir/patch/$_pn_script"
        chmod 0644 "$_pn_dir/patch/$_pn_script"
    done
    for _pn_tool in device_validation.sh arm_auto_recovery.sh verify_auto_recovery.sh; do
        printf '%s\n' '#!/bin/sh' 'exit 0' > "$_pn_dir/$_pn_tool"
        chmod 0644 "$_pn_dir/$_pn_tool"
    done
    printf '%s\n' '{"repos":[]}' > "$_pn_dir/repos.json"
}

run_installer() {
    _pn_mod=$1
    _pn_state=$2
    _pn_manager=$3
    _pn_expected=$4
    _pn_log=$5

    (
        ui_print() { printf 'UI:%s\n' "$*" >> "$_pn_log"; }
        abort() { printf 'ABORT:%s\n' "$*" >> "$_pn_log"; exit 99; }
        set_perm() {
            # target owner group mode [context]
            chmod "$4" "$1"
        }
        set_perm_recursive() {
            # dir owner group dirmode filemode [context]
            _d=$1; _dm=$4; _fm=$5
            find "$_d" -type d -exec chmod "$_dm" {} +
            find "$_d" -type f -exec chmod "$_fm" {} +
        }

        MODPATH=$_pn_mod
        ARCH=arm64
        PATCHNEST_INSTALL_TEST=1
        PATCHNEST_STATE_DIR=$_pn_state
        APATCH=''
        KSU=''
        MAGISK_VER=''
        case "$_pn_manager" in
            magisk) MAGISK_VER='v30.0' ;;
            ksu) KSU='true'; MAGISK_VER='v25.2' ;;
            apatch) APATCH='true' ;;
            *) exit 98 ;;
        esac
        export MODPATH ARCH PATCHNEST_INSTALL_TEST PATCHNEST_STATE_DIR APATCH KSU MAGISK_VER
        # shellcheck disable=SC1090
        . "$CUSTOMIZE"
    )
    _pn_rc=$?
    [ "$_pn_rc" -eq 0 ] || return "$_pn_rc"
    [ -f "$_pn_state/root_manager" ] || return 90
    [ "$(cat "$_pn_state/root_manager")" = "$_pn_expected" ] || return 91
    [ "$(stat -c '%a' "$_pn_state/root_manager")" = "600" ] || return 92
    [ "$(stat -c '%a' "$_pn_mod/bin/kpatch")" = "755" ] || return 93
    [ "$(stat -c '%a' "$_pn_mod/patch/boot_patch.sh")" = "755" ] || return 94
    [ "$(stat -c '%a' "$_pn_mod/device_validation.sh")" = "755" ] || return 95
    [ ! -e "$_pn_mod/module.prop.bak" ] || return 96
    return 0
}

# Review marker must abort before the state directory is created.
BLOCKED="$TMP/blocked-module"
BLOCKED_STATE="$TMP/blocked-state"
make_fake_module "$BLOCKED"
touch "$BLOCKED/FLASH_REVIEW_BLOCKED"
set +e
run_installer "$BLOCKED" "$BLOCKED_STATE" magisk magisk "$TMP/blocked.log"
blocked_rc=$?
set -e
[ "$blocked_rc" -eq 99 ] || fail "review blocker did not terminate installer (rc=$blocked_rc)"
[ ! -e "$BLOCKED_STATE" ] || fail "review blocker allowed persistent state creation"
grep -Fq 'ABORT:! FLASH_REVIEW_BLOCKED' "$TMP/blocked.log" || fail "review blocker abort reason missing"

# Candidate behavior: the same already-extracted MODPATH must work under each
# manager convention without copying to a hard-coded final module directory.
for spec in 'magisk:magisk' 'ksu:ksu' 'apatch:apatch'; do
    manager=${spec%%:*}
    expected=${spec#*:}
    mod="$TMP/module-$manager"
    state="$TMP/state-$manager"
    make_fake_module "$mod"
    if ! run_installer "$mod" "$state" "$manager" "$expected" "$TMP/$manager.log"; then
        fail "$manager installer simulation failed"
    fi
    grep -Fq 'UI:- Installation complete' "$TMP/$manager.log" || fail "$manager install did not complete"
done

echo "installer contract: PASS"
