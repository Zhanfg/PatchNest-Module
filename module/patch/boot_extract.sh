#!/system/bin/sh

#######################################################################################
# PatchNest boot target discovery
# Based on APatch boot_extract.sh with strict KernelPatch target validation.
#######################################################################################

MODPATH=${0%/*}
IS_INSTALL_NEXT_SLOT=${1:-false}

. "$MODPATH/util_functions.sh"
. "$MODPATH/flash_guard.sh"

case "$IS_INSTALL_NEXT_SLOT" in
  true) get_next_slot ;;
  false|'') get_current_slot ;;
  *)
    echo "! install-next-slot must be true or false" >&2
    exit 2
    ;;
esac

find_boot_image
if [ -z "${BOOTIMAGE:-}" ] || [ ! -e "$BOOTIMAGE" ]; then
  echo "! Cannot find a boot image containing the kernel" >&2
  exit 1
fi
if ! assert_kernel_boot_target "$BOOTIMAGE"; then
  echo "! Discovered partition is not a supported KernelPatch boot target" >&2
  exit 1
fi

# get_current_slot/get_next_slot and find_boot_image already emit SLOT/BOOTIMAGE.
exit 0
