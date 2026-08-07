#!/system/bin/sh
# KernelPatch boot target discovery.
# Source after util_functions.sh and flash_guard.sh.

find_kernel_boot_image() {
  BOOTIMAGE=""

  if [ -n "${SLOT:-}" ]; then
    BOOTIMAGE=$(find_block "boot$SLOT" 2>/dev/null || true)
  fi

  if [ -z "$BOOTIMAGE" ]; then
    # Keep historical boot aliases used by supported devices, but never search
    # vendor_boot or init_boot: neither is a valid KernelPatch kernel target.
    BOOTIMAGE=$(find_block \
      kern-a kern_a kern-b kern_b \
      android_boot kernel bootimg boot lnx \
      boot_a boot_b 2>/dev/null || true)
  fi

  if [ -z "$BOOTIMAGE" ]; then
    # Some recoveries expose only an fstab path. Accept it only after the same
    # logical partition validation used by direct flashing.
    _fstab_target=$(grep -h -v '^[[:space:]]*#' /etc/*fstab* 2>/dev/null \
      | grep -E '[[:space:]]/boot(img)?([[:space:]]|$)' \
      | grep -oE '/dev/[A-Za-z0-9_./-]+' \
      | head -n 1)
    if [ -n "$_fstab_target" ] && [ -e "$_fstab_target" ] \
       && assert_kernel_boot_target "$_fstab_target"; then
      BOOTIMAGE=$_fstab_target
    fi
  fi

  [ -n "$BOOTIMAGE" ] && [ -e "$BOOTIMAGE" ] || return 1
  assert_kernel_boot_target "$BOOTIMAGE" || {
    BOOTIMAGE=""
    return 1
  }
  echo "BOOTIMAGE=$BOOTIMAGE"
  return 0
}

# util_functions.sh historically exported find_boot_image() with a fallback to
# vendor_boot/init_boot. Override that legacy public name after sourcing the
# upstream helper so any remaining caller receives the boot-only resolver.
find_boot_image() {
  find_kernel_boot_image
}
