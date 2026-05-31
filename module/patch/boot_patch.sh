#!/system/bin/sh
#######################################################################################
# APatch Boot Image Patcher
# Imported from https://github.com/bmax121/APatch/blob/main/app/src/main/assets/boot_patch.sh
#######################################################################################
#
# Usage: boot_patch.sh <superkey> <bootimage> [ARGS_PASS_TO_KPTOOLS]
#
# This script should be placed in a directory with the following files:
#
# File name          Type          Description
#
# boot_patch.sh      script        A script to patch boot image for APatch.
#                  (this file)      The script will use files in its same
#                                  directory to complete the patching process.
# bootimg            binary        The target boot image
# kpimg              binary        KernelPatch core Image
# kptools            executable    The KernelPatch tools binary to inject kpimg to kernel Image
# magiskboot         executable    Magisk tool to unpack boot.img.
#
#######################################################################################

MODPATH=${0%/*}
ARCH=$(getprop ro.product.cpu.abi)

# Load utility functions
. "$MODPATH/util_functions.sh"

BOOTIMAGE=$1
FLASH_TO_DEVICE=$2
shift 2

[ -e "$BOOTIMAGE" ] || { >&2 echo "! $BOOTIMAGE does not exist"; exit 1; }

# Check for dependencies
command -v magiskboot >/dev/null 2>&1 || { >&2 echo "! Command magiskboot not found"; exit 1; }
command -v kptools >/dev/null 2>&1 || { >&2 echo "! Command kptools not found"; exit 1; }

if [ ! -f kernel ]; then
echo "- Unpacking boot image"
magiskboot unpack "$BOOTIMAGE" >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    >&2 echo "! Unpack error: $?"
    exit 1
  fi
fi

if kptools -i kernel -f | grep -q "CONFIG_KPM=y"; then
	echo "! Patcher has Aborted."
	echo "! Detected built-in KPM (CONFIG_KPM=y)."
	echo "! KPatch-Next is not compatible alongside built-in KPM."
	exit 1
fi

if [ ! $(kptools -i kernel -f | grep CONFIG_KALLSYMS_ALL=y) ]; then
	echo "! Patcher has Aborted."
	echo "! KPatch-Next requires CONFIG_KALLSYMS_ALL to be Enabled."
	echo "! But your kernel seems NOT enabled it."
	exit 1
fi

if [  $(kptools -i kernel -l | grep patched=false) ]; then
	echo "- Backing boot.img "
  cp "$BOOTIMAGE" "ori.img" >/dev/null 2>&1
  # Persistent backup
  BACKUP_DIR="/data/adb/kp-next/backup"
  mkdir -p "$BACKUP_DIR"
  DATE=$(date +%y%m%d%H%M)
  cp "$BOOTIMAGE" "$BACKUP_DIR/boot_backup_${DATE}.img"
  echo "- Boot backup saved to $BACKUP_DIR/boot_backup_${DATE}.img"
fi

mv kernel kernel.ori

# ============================================================
# Validate embedded KPMs before patching
# Parse -M <kpm_file> from args and validate each one
# ============================================================
echo "- Validating embedded modules..."
validate_failed=0
for arg in "$@"; do
    case "$prev_flag" in
        -M)
            kpm_file="$arg"
            if [ ! -f "$kpm_file" ]; then
                echo "! Embedded KPM not found: $kpm_file"
                validate_failed=1
                continue
            fi
            # Check ELF magic (7f 45 4c 46)
            magic=$(xxd -l 4 -p "$kpm_file" 2>/dev/null)
            if [ "$magic" != "7f454c46" ]; then
                echo "! Invalid ELF: $kpm_file (magic=$magic)"
                validate_failed=1
                continue
            fi
            # Check aarch64 (e_machine = 0xB7 at offset 18)
            machine=$(xxd -s 18 -l 2 -e "$kpm_file" 2>/dev/null | awk '{print $2}')
            if [ "$machine" != "000000b7" ] && [ "$machine" != "b700" ]; then
                echo "! Not aarch64: $kpm_file"
                validate_failed=1
                continue
            fi
            # Try kptools validation if available
            if kptools -l -M "$kpm_file" >/dev/null 2>&1; then
                kpm_name=$(kptools -l -M "$kpm_file" 2>/dev/null | grep "^name=" | cut -d= -f2)
                echo "  ✓ Valid: ${kpm_name:-$kpm_file}"
            else
                # kptools -l might not work for all formats, just warn
                echo "  ⚠ Cannot verify with kptools: $kpm_file (proceeding)"
            fi
            ;;
    esac
    prev_flag="$arg"
done

if [ $validate_failed -ne 0 ]; then
    echo "! Embedded KPM validation failed. Aborting patch."
    echo "! Remove invalid KPM files and try again."
    mv kernel.ori kernel
    exit 1
fi

echo "- Patching kernel"

set -x
kptools -p -i kernel.ori -k kpimg -o kernel "$@"
patch_rc=$?
set +x

if [ $patch_rc -ne 0 ]; then
  >&2 echo "! Patch kernel error: $patch_rc"
  exit 1
fi

echo "- Repacking boot image"
magiskboot repack "$BOOTIMAGE" >/dev/null 2>&1

if [ $? -ne 0 ]; then
  >&2 echo "! Repack error: $?"
  exit 1
fi

if [ "$FLASH_TO_DEVICE" = "true" ]; then
  # flash
  if [ -b "$BOOTIMAGE" ] || [ -c "$BOOTIMAGE" ] && [ -f "new-boot.img" ]; then
    echo "- Flashing new boot image"
    flash_image new-boot.img "$BOOTIMAGE"
    if [ $? -ne 0 ]; then
      >&2 echo "! Flash error: $?"
      save_image_to_storage "new-boot.img"
      exit 1
    fi
  fi

  echo "- Successfully Flashed!"
else
  save_image_to_storage "new-boot.img"
  echo "- Successfully Patched!"
fi

