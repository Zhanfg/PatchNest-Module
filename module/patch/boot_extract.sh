#!/system/bin/sh

#######################################################################################
# Imported from https://github.com/bmax121/APatch/blob/main/app/src/main/assets/boot_extract.sh
#######################################################################################

MODPATH=${0%/*}
ARCH=$(getprop ro.product.cpu.abi)

IS_INSTALL_NEXT_SLOT=${1:-false}

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

# PatchNest find_boot_image returns non-zero on every ambiguous/unsupported
# target condition. Never route those failures through util_functions.sh
# abort(), because that upstream installer helper removes $MODPATH.
find_boot_image || {
  >&2 echo "! Safe boot target resolution failed"
  exit 1
}

[ -n "${BOOTIMAGE:-}" ] && [ -e "$BOOTIMAGE" ] || {
  >&2 echo "! Resolved boot image is missing"
  exit 1
}

exit 0
