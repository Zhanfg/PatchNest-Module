#!/system/bin/sh
#######################################################################################
# APatch Boot Image Unpatcher
# Imported from https://github.com/bmax121/APatch/blob/main/app/src/main/assets/boot_unpatch.sh
#######################################################################################

MODPATH=${0%/*}
ARCH=$(getprop ro.product.cpu.abi)
PNDIR="/data/adb/patchnest"
BACKUP_DIR="$PNDIR/backup"
AUTORECOVERY_MARKER="$PNDIR/autorecovery_active"

# Load utility functions
. "$MODPATH/util_functions.sh"

BOOTIMAGE=$1

# ============================================================
# auto_unpatch()
# Bootloop Auto-Recovery entry point.
# Flashes back the LATEST backup boot image from
# /data/adb/patchnest/backup/ to the active boot slot.
# Leaves the autorecovery_active marker in place until a
# healthy boot clears it (so the WebUI can show the status).
# Returns 0 on success, non-zero on failure.
# ============================================================
auto_unpatch() {
    if [ -z "$BOOTIMAGE" ] || [ ! -e "$BOOTIMAGE" ]; then
        >&2 echo "! auto_unpatch: BOOTIMAGE not set or missing ($BOOTIMAGE)"
        return 1
    fi

    command -v flash_image >/dev/null 2>&1 || {
        >&2 echo "! auto_unpatch: flash_image function not available"
        return 2
    }

    if [ ! -d "$BACKUP_DIR" ]; then
        >&2 echo "! auto_unpatch: backup dir not found: $BACKUP_DIR"
        return 3
    fi

    # Pick the newest backup by modification time.
    latest_backup=$(ls -1t "$BACKUP_DIR"/boot_backup_*.img 2>/dev/null | head -n 1)
    if [ -z "$latest_backup" ] || [ ! -f "$latest_backup" ]; then
        >&2 echo "! auto_unpatch: no backup images in $BACKUP_DIR"
        return 4
    fi

    # ============================================================
    # If a JSON manifest accompanies the backup, surface a one-line
    # summary so service.sh / WebUI can show "preserved: AK3 27.0".
    # If the manifest is missing (legacy backup) we don't fail —
    # auto_unpatch must still work for old users.
    # ============================================================
    latest_manifest="${latest_backup%.img}.json"
    if [ -f "$latest_manifest" ]; then
        manifest_kpstate=$(grep -o '"kp_state"[[:space:]]*:[[:space:]]*"[^"]*"' "$latest_manifest" 2>/dev/null \
            | head -n 1 | sed -E 's/.*"kp_state"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
        manifest_magver=$(grep -o '"magisk_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$latest_manifest" 2>/dev/null \
            | head -n 1 | sed -E 's/.*"magisk_version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
        manifest_ksuver=$(grep -o '"ksu_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$latest_manifest" 2>/dev/null \
            | head -n 1 | sed -E 's/.*"ksu_version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
        manifest_verified=$(grep -o '"backup_verified"[[:space:]]*:[[:space:]]*[a-z]*' "$latest_manifest" 2>/dev/null \
            | head -n 1 | sed -E 's/.*"backup_verified"[[:space:]]*:[[:space:]]*([a-z]*).*/\1/')
        echo "- auto_unpatch: manifest kp_state=${manifest_kpstate:-unknown} magisk=${manifest_magver:-null} ksu=${manifest_ksuver:-null} verified=${manifest_verified:-unknown}"
    else
        echo "- auto_unpatch: no manifest for $latest_backup (legacy backup)"
    fi

    echo "- auto_unpatch: using latest backup: $latest_backup"

    if ! flash_image "$latest_backup" "$BOOTIMAGE"; then
        >&2 echo "! auto_unpatch: flash failed"
        return 5
    fi

    # Best-effort cleanup of the counter so we don't immediately
    # re-trigger on the next boot. Keep the marker so the WebUI
    # can show that auto-recovery was activated.
    echo "0" > "$PNDIR/boot_count" 2>/dev/null
    echo "- auto_unpatch: flash successful"
    return 0
}

[ -e "$BOOTIMAGE" ] || { echo "- $BOOTIMAGE does not exist!"; exit 1; }

echo "- Target image: $BOOTIMAGE"

  # Check for dependencies
command -v magiskboot >/dev/null 2>&1 || { echo "- Command magiskboot not found!"; exit 1; }
command -v kptools >/dev/null 2>&1 || { echo "- Command kptools not found!"; exit 1; }

if [ ! -f kernel ]; then
echo "- Unpacking boot image"
magiskboot unpack "$BOOTIMAGE" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    >&2 echo "! Unpack error: $?"
    exit 1
  fi
fi

if [ -n "$(kptools -i kernel -l 2>/dev/null | grep patched=true)" ]; then
	echo "- kernel has been patched "
  if [ -f "new-boot.img" ]; then
    echo "- found backup boot.img ,use it for recovery"
  else
    mv kernel kernel.ori
    echo "- Unpatching kernel"
    kptools -u --image kernel.ori --out kernel
    if [ $? -ne 0 ]; then
      >&2 echo "! Unpatch error: $?"
      exit 1
    fi
    echo "- Repacking boot image"
    magiskboot repack "$BOOTIMAGE" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
      >&2 echo "! Repack error: $?"
      exit 1
    fi
  fi

else
  echo "- no need unpatch"
  exit 0
fi

if [ -f "new-boot.img" ]; then
  echo "- Flashing boot image"
  flash_image new-boot.img "$BOOTIMAGE"

  if [ $? -ne 0 ]; then
    >&2 echo "! Flash error: $?"
    save_image_to_storage "new-boot.img"
    exit 1
  fi
fi

echo "- Flash successful"

# Reset any error code
true
