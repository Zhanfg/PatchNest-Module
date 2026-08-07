#!/system/bin/sh

#######################################################################################
# Imported from https://github.com/bmax121/APatch/blob/main/app/src/main/assets/boot_extract.sh
#######################################################################################

MODPATH=${0%/*}
ARCH=$(getprop ro.product.cpu.abi)

IS_INSTALL_NEXT_SLOT=$1

# shellcheck disable=SC1091
. "$MODPATH/util_functions.sh"
# PatchNest fail-closed slot/partition resolution overrides.
# shellcheck disable=SC1091
. "$MODPATH/flash_safety.sh"

if [ "$IS_INSTALL_NEXT_SLOT" = "true" ]; then
  get_next_slot
else
  get_current_slot
fi

find_boot_image

[ -e "$BOOTIMAGE" ] || { >&2 echo "- can't find boot.img!"; exit 1; }

true
