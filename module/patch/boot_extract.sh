#!/system/bin/sh

#######################################################################################
# PatchNest boot target discovery
#######################################################################################

MODPATH=${0%/*}
IS_INSTALL_NEXT_SLOT=${1:-false}

. "$MODPATH/util_functions.sh"
. "$MODPATH/flash_guard.sh"
. "$MODPATH/boot_target.sh"

case "$IS_INSTALL_NEXT_SLOT" in
  true) get_next_slot ;;
  false|'') get_current_slot ;;
  *)
    echo "! install-next-slot must be true or false" >&2
    exit 2
    ;;
esac

if ! find_kernel_boot_image; then
  echo "! Cannot find a supported boot image containing the kernel" >&2
  exit 1
fi

exit 0
