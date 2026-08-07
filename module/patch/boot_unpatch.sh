#!/system/bin/sh
#######################################################################################
# PatchNest Boot Image Unpatcher
# Derived from APatch boot_unpatch.sh, hardened for fail-closed recovery.
#######################################################################################

MODPATH=${0%/*}
PNDIR="/data/adb/patchnest"
BACKUP_DIR="$PNDIR/backup"
AUTORECOVERY_MARKER="$PNDIR/autorecovery_active"

# shellcheck disable=SC1091
. "$MODPATH/util_functions.sh"
# shellcheck disable=SC1091
. "$MODPATH/flash_safety.sh"

BOOTIMAGE=${1:-}
[ -n "$BOOTIMAGE" ] || { >&2 echo "! BOOTIMAGE is required"; exit 1; }
[ -e "$BOOTIMAGE" ] || { >&2 echo "! $BOOTIMAGE does not exist"; exit 1; }
BOOT_TARGET=$(readlink -f "$BOOTIMAGE" 2>/dev/null || printf '%s' "$BOOTIMAGE")

command -v magiskboot >/dev/null 2>&1 || { >&2 echo "! Command magiskboot not found"; exit 1; }
command -v kptools >/dev/null 2>&1 || { >&2 echo "! Command kptools not found"; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { >&2 echo "! Command sha256sum not found"; exit 1; }

WORKDIR=$(mktemp -d /data/local/tmp/patchnest_unpatch.XXXXXX) || {
    >&2 echo "! Cannot create private unpatch workspace"
    exit 1
}
cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT HUP INT TERM

json_string() {
    key="$1"
    file="$2"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
        | head -n 1 \
        | sed -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/"
}

json_bool() {
    key="$1"
    file="$2"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*(true|false)" "$file" 2>/dev/null \
        | head -n 1 \
        | sed -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*(true|false).*/\\1/"
}

# Select only a backup that is cryptographically bound to this exact target.
# Glob expansion is lexical; timestamp-prefixed backup names therefore let the
# last valid entry replace earlier ones without parsing `ls` or using non-POSIX -nt.
select_verified_backup() {
    [ -d "$BACKUP_DIR" ] || return 1

    best_backup=""
    for manifest in "$BACKUP_DIR"/boot_backup_*.json; do
        [ -f "$manifest" ] || continue
        [ "$(json_bool backup_verified "$manifest")" = "true" ] || continue

        recorded_target=$(json_string boot_target "$manifest")
        recorded_sha=$(json_string backup_sha256 "$manifest")
        backup="${manifest%.json}.img"

        [ -n "$recorded_target" ] || continue
        [ "$recorded_target" = "$BOOT_TARGET" ] || continue
        printf '%s' "$recorded_sha" | grep -Eq '^[0-9a-f]{64}$' || continue
        [ -f "$backup" ] || continue

        actual_sha=$(sha256sum "$backup" 2>/dev/null | awk '{print $1}')
        [ "$actual_sha" = "$recorded_sha" ] || continue

        best_backup="$backup"
    done

    [ -n "$best_backup" ] || return 1
    printf '%s\n' "$best_backup"
}

auto_unpatch() {
    command -v flash_image >/dev/null 2>&1 || {
        >&2 echo "! auto_unpatch: flash_image function not available"
        return 2
    }

    verified_backup=$(select_verified_backup) || {
        >&2 echo "! auto_unpatch: no verified backup is bound to $BOOT_TARGET"
        >&2 echo "! Legacy/newest-by-time fallback is disabled for safety"
        return 3
    }

    echo "- auto_unpatch: verified backup: $verified_backup"
    echo "- auto_unpatch: target: $BOOT_TARGET"
    flash_image "$verified_backup" "$BOOT_TARGET"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        >&2 echo "! auto_unpatch: verified flash failed: $rc"
        return 4
    fi

    echo "0" > "$PNDIR/boot_count" 2>/dev/null
    touch "$AUTORECOVERY_MARKER" 2>/dev/null || true
    echo "- auto_unpatch: verified restore completed"
    return 0
}

echo "- Target image: $BOOT_TARGET"
cd "$WORKDIR" || exit 1

echo "- Unpacking current boot image into private workspace"
if ! magiskboot unpack "$BOOT_TARGET" >/dev/null 2>&1; then
    >&2 echo "! Unpack failed"
    exit 1
fi
[ -s kernel ] || { >&2 echo "! Unpack produced no kernel; refusing to continue"; exit 1; }

if ! kptools -i kernel -l 2>/dev/null | grep -q 'patched=true'; then
    echo "- Kernel is not PatchNest-patched; no unpatch required"
    exit 0
fi

echo "- Unpatching kernel"
mv kernel kernel.patched
if ! kptools -u --image kernel.patched --out kernel; then
    >&2 echo "! Unpatch failed"
    exit 1
fi
[ -s kernel ] || { >&2 echo "! Unpatch produced an empty kernel"; exit 1; }

echo "- Repacking from the current target image"
if ! magiskboot repack "$BOOT_TARGET" >/dev/null 2>&1; then
    >&2 echo "! Repack failed"
    exit 1
fi
[ -s new-boot.img ] || { >&2 echo "! Repack produced no new-boot.img"; exit 1; }

echo "- Flashing unpatched boot image"
flash_image "$WORKDIR/new-boot.img" "$BOOT_TARGET"
rc=$?
if [ "$rc" -ne 0 ]; then
    >&2 echo "! Flash failed: $rc"
    save_image_to_storage "$WORKDIR/new-boot.img"
    exit 1
fi

echo "- Flash successful"
exit 0
