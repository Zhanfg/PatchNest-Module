#!/system/bin/sh
#######################################################################################
# PatchNest Boot Image Unpatcher / bound-backup restorer
#######################################################################################
# Usage:
#   boot_unpatch.sh <bootimage>
#   boot_unpatch.sh --restore-bound-backup <bootimage>
#######################################################################################

MODPATH=${0%/*}
PNDIR="/data/adb/patchnest"
BACKUP_DIR="$PNDIR/backup"
AUTORECOVERY_MARKER="$PNDIR/autorecovery_active"

# shellcheck disable=SC1091
. "$MODPATH/util_functions.sh"
# shellcheck disable=SC1091
. "$MODPATH/flash_safety.sh"

RESTORE_BOUND=0
if [ "${1:-}" = "--restore-bound-backup" ]; then
    RESTORE_BOUND=1
    shift
fi

BOOTIMAGE=${1:-}
[ -n "$BOOTIMAGE" ] || { >&2 echo "! BOOTIMAGE is required"; exit 1; }
[ -e "$BOOTIMAGE" ] || { >&2 echo "! $BOOTIMAGE does not exist"; exit 1; }
BOOT_TARGET=$(readlink -f "$BOOTIMAGE" 2>/dev/null || printf '%s' "$BOOTIMAGE")

command -v magiskboot >/dev/null 2>&1 || { >&2 echo "! Command magiskboot not found"; exit 1; }
command -v kptools >/dev/null 2>&1 || { >&2 echo "! Command kptools not found"; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { >&2 echo "! Command sha256sum not found"; exit 1; }
command -v patchnest_device_binding_sha256 >/dev/null 2>&1 || {
    >&2 echo "! Transaction identity helper is unavailable"
    exit 1
}

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

json_number() {
    key="$1"
    file="$2"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" "$file" 2>/dev/null \
        | head -n 1 \
        | sed -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*([0-9][0-9]*).*/\\1/"
}

hash_target_prefix() {
    target="$1"
    size="$2"
    printf '%s' "$size" | grep -Eq '^[1-9][0-9]*$' || return 1
    blocks=$(((size + 1048575) / 1048576))
    digest=$(dd if="$target" bs=1048576 count="$blocks" 2>/dev/null \
        | head -c "$size" \
        | sha256sum \
        | awk '{print $1}')
    printf '%s' "$digest" | grep -Eq '^[0-9a-f]{64}$' || return 1
    printf '%s\n' "$digest"
}

# Resolve exactly the rollback image committed by the last successful verified
# PatchNest write. No mtime/lexical/newest fallback exists here.
resolve_bound_backup() {
    binding=${PATCHNEST_ROLLBACK_BINDING_FILE:-$PNDIR/rollback_binding.json}
    [ -f "$binding" ] || {
        >&2 echo "! No committed rollback transaction"
        return 1
    }
    [ "$(json_bool verified_readback "$binding")" = "true" ] || {
        >&2 echo "! Rollback transaction has no verified readback"
        return 2
    }

    recorded_target=$(json_string boot_target "$binding")
    recorded_device=$(json_string device_binding_sha256 "$binding")
    backup_name=$(json_string rollback_backup "$binding")
    backup_sha=$(json_string rollback_backup_sha256 "$binding")
    patched_sha=$(json_string patched_image_sha256 "$binding")
    patched_size=$(json_number patched_image_size "$binding")

    [ "$recorded_target" = "$BOOT_TARGET" ] || {
        >&2 echo "! Rollback target mismatch"
        return 3
    }
    printf '%s' "$recorded_device" | grep -Eq '^[0-9a-f]{64}$' || return 3
    printf '%s' "$backup_sha" | grep -Eq '^[0-9a-f]{64}$' || return 3
    printf '%s' "$patched_sha" | grep -Eq '^[0-9a-f]{64}$' || return 3
    printf '%s' "$patched_size" | grep -Eq '^[1-9][0-9]*$' || return 3

    current_device=$(patchnest_device_binding_sha256) || {
        >&2 echo "! Cannot establish current device identity"
        return 4
    }
    [ "$current_device" = "$recorded_device" ] || {
        >&2 echo "! Rollback binding belongs to another device/slot/target context"
        return 4
    }

    case "$backup_name" in
        boot_backup_*.img) ;;
        *) >&2 echo "! Unsafe rollback backup name"; return 5 ;;
    esac
    case "$backup_name" in
        */*|*..*) >&2 echo "! Unsafe rollback backup path"; return 5 ;;
    esac

    backup="$BACKUP_DIR/$backup_name"
    [ -f "$backup" ] || {
        >&2 echo "! Bound rollback backup is missing: $backup"
        return 5
    }
    actual_backup_sha=$(sha256sum "$backup" 2>/dev/null | awk '{print $1}')
    [ "$actual_backup_sha" = "$backup_sha" ] || {
        >&2 echo "! Bound rollback backup digest mismatch"
        return 6
    }

    # Refuse stale rollback after an external flash or a later transaction.
    current_prefix_sha=$(hash_target_prefix "$BOOT_TARGET" "$patched_size") || return 7
    [ "$current_prefix_sha" = "$patched_sha" ] || {
        >&2 echo "! Current boot bytes no longer match the committed PatchNest transaction"
        >&2 echo "! Refusing stale automatic rollback"
        return 7
    }

    printf '%s\n' "$backup"
}

restore_bound_backup() {
    verified_backup=$(resolve_bound_backup) || return $?

    echo "- restore: transaction-bound backup: $verified_backup"
    echo "- restore: target: $BOOT_TARGET"
    flash_image "$verified_backup" "$BOOT_TARGET"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        >&2 echo "! restore: verified flash failed: $rc"
        return 8
    fi

    patchnest_remove_rollback_binding || {
        >&2 echo "! restore completed but rollback binding could not be cleared"
        return 9
    }
    echo "0" > "$PNDIR/boot_count" 2>/dev/null
    touch "$AUTORECOVERY_MARKER" 2>/dev/null || true
    echo "- restore: transaction-bound rollback verified"
    return 0
}

if [ "$RESTORE_BOUND" -eq 1 ]; then
    restore_bound_backup
    exit $?
fi

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

echo "- Flashing unpatched boot image with readback verification"
flash_image "$WORKDIR/new-boot.img" "$BOOT_TARGET"
rc=$?
if [ "$rc" -ne 0 ]; then
    >&2 echo "! Flash failed: $rc"
    save_image_to_storage "$WORKDIR/new-boot.img"
    exit 1
fi

# The current target no longer corresponds to the previously committed patched
# transaction, so that rollback authorization must not remain live.
patchnest_remove_rollback_binding || true

echo "- Flash successful"
exit 0
