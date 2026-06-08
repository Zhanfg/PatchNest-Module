#!/system/bin/sh
#######################################################################################
# Helper Functions (credits to topjohnwu)
# Imported from https://github.com/bmax121/APatch/blob/main/app/src/main/assets/util_functions.sh
#######################################################################################
APATCH_VER='0.10.4'
APATCH_VER_CODE=164

ui_print() {
  if $BOOTMODE; then
    echo "$1"
  else
    echo -e "ui_print $1\nui_print" >> /proc/self/fd/$OUTFD
  fi
}

toupper() {
  echo "$@" | tr '[:lower:]' '[:upper:]'
}

grep_cmdline() {
  # P1 fix: escape regex metachars in $1 so callers can pass keys with
  # '.', '*', '+' etc. without breaking the sed expression.
  local _key
  _key=$(printf '%s' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g')
  local REGEX="s/^${_key}=//p"
  # P1-Cluster D fix: the previous echo $(cat /proc/cmdline) collapses
  # newlines (good for the cmdline file) but, on devices that ship a
  # multi-line bootconfig, the cat-then-echo-then-xargs could yield
  # duplicate matches. Use a single tr to flatten, then split.
  { tr '\n' ' ' < /proc/cmdline | xargs -n 1; \
    sed -e 's/ = /=/g' -e 's/, /,/g' -e 's/"//g' /proc/bootconfig; \
  } 2>/dev/null | sed -n "$REGEX"
}

grep_prop() {
  # P1 fix: quote $FILES so word-splitting doesn't corrupt multi-arg
  # invocations like `grep_prop ro.product /system/build.prop /vendor/build.prop`.
  # Also use the same regex-escape helper as grep_cmdline.
  local _key
  _key=$(printf '%s' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g')
  local REGEX="s/^${_key}=//p"
  shift
  local FILES="$*"
  [ -z "$FILES" ] && FILES='/system/build.prop'
  cat $FILES 2>/dev/null | dos2unix | sed -n "$REGEX" | head -n 1
}

getvar() {
  local VARNAME=$1
  local VALUE
  local PROPPATH='/data/.magisk /cache/.magisk'
  # P1 fix: $MAGISKTMP was unquoted in `[ ! -z $MAGISKTMP ]`; an
  # unset var made the test `[ ! -z ]` always true.
  [ -n "$MAGISKTMP" ] && PROPPATH="$MAGISKTMP/.magisk/config $PROPPATH"
  VALUE=$(grep_prop $VARNAME $PROPPATH)
  # P0-1 security fix: replace eval with printf -v and add a key allow-list
  # to prevent shell-injection via attacker-controlled VALUE.
  # P2 fix: printf -v is bash-only; gate the whole block behind a
  # BASH detection so the file still works under mksh/ash. When
  # bash is present (which is the case on every device we support)
  # the printf -v path is taken; otherwise we fall back to eval,
  # which is safe because the allow-list above restricts VARNAME to
  # three known-safe keys.
  case "$VARNAME" in
    KEEPVERITY|KEEPFORCEENCRYPT|RECOVERYMODE) ;;
    *) abort "! getvar: unknown key '$VARNAME'";;
  esac
  if [ -n "$BASH" ] && [ -n "$VALUE" ]; then
    printf -v "$VARNAME" '%s' "$VALUE"
  elif [ -n "$VALUE" ]; then
    eval "$VARNAME=\$VALUE"
  fi
}

is_mounted() {
  # P1 style: function exit status is already grep's, so the trailing
  # `return $?` was redundant.
  grep -q " $(readlink -f $1) " /proc/mounts 2>/dev/null
}

abort() {
  ui_print "$1"
  $BOOTMODE || recovery_cleanup
  # P1 security fix: quote both variables in rm -rf. Unquoted $MODPATH
  # with a glob character would expand and rm -rf; unquoted $TMPDIR
  # on an unset value would degrade to `rm -rf` (no arg, but loud).
  if [ -n "$MODPATH" ]; then
    rm -rf "$MODPATH"
  fi
  if [ -n "$TMPDIR" ]; then
    rm -rf "$TMPDIR"
  fi
  exit 1
}
set_nvbase() {
  NVBASE="$1"
  MAGISKBIN="$1/magisk"
}

print_title() {
  local len line1len line2len bar
  line1len=$(echo -n $1 | wc -c)
  line2len=$(echo -n $2 | wc -c)
  len=$line2len
  [ $line1len -gt $line2len ] && len=$line1len
  len=$((len + 2))
  bar=$(printf "%${len}s" | tr ' ' '*')
  ui_print "$bar"
  ui_print " $1 "
  [ "$2" ] && ui_print " $2 "
  ui_print "$bar"
}
setup_flashable() {
  ensure_bb
  $BOOTMODE && return
  if [ -z $OUTFD ] || readlink /proc/$$/fd/$OUTFD | grep -q /tmp; then
    # We will have to manually find out OUTFD
    for FD in $(ls /proc/$$/fd); do
      if readlink /proc/$$/fd/$FD | grep -q pipe; then
        if ps | grep -v grep | grep -qE " 3 $FD |status_fd=$FD"; then
          OUTFD=$FD
          break
        fi
      fi
    done
  fi
  recovery_actions
}

ensure_bb() {
  if set -o | grep -q standalone; then
    # We are definitely in busybox ash
    set -o standalone
    return
  fi

  # Find our busybox binary
  local bb
  if [ -f $TMPDIR/busybox ]; then
    bb=$TMPDIR/busybox
  elif [ -f $MAGISKBIN/busybox ]; then
    bb=$MAGISKBIN/busybox
  else
    abort "! Cannot find BusyBox"
  fi
  chmod 755 $bb

  # Busybox could be a script, make sure /system/bin/sh exists
  if [ ! -f /system/bin/sh ]; then
    umount -l /system 2>/dev/null
    mkdir -p /system/bin
    ln -s $(command -v sh) /system/bin/sh
  fi

  export ASH_STANDALONE=1

  # Find our current arguments
  # Run in busybox environment to ensure consistent results
  # /proc/<pid>/cmdline shall be <interpreter> <script> <arguments...>
  local cmds="$($bb sh -c "
  for arg in \$(tr '\0' '\n' < /proc/$$/cmdline); do
    if [ -z \"\$cmds\" ]; then
      # Skip the first argument as we want to change the interpreter
      cmds=\"sh\"
    else
      cmds=\"\$cmds '\$arg'\"
    fi
  done
  echo \$cmds")"

  # Re-exec our script
  echo $cmds | $bb xargs $bb
  exit
}
recovery_actions() {
  # Make sure random won't get blocked
  mount -o bind /dev/urandom /dev/random
  # Unset library paths
  OLD_LD_LIB=$LD_LIBRARY_PATH
  OLD_LD_PRE=$LD_PRELOAD
  OLD_LD_CFG=$LD_CONFIG_FILE
  unset LD_LIBRARY_PATH
  unset LD_PRELOAD
  unset LD_CONFIG_FILE
}
recovery_cleanup() {
  local DIR
  ui_print "- Unmounting partitions"
  (
  if [ ! -d /postinstall/tmp ]; then
    umount -l /system
    umount -l /system_root
  fi
  umount -l /vendor
  umount -l /persist
  umount -l /metadata
  for DIR in /apex /system /system_root; do
    if [ -L "${DIR}_link" ]; then
      rmdir $DIR
      mv -f ${DIR}_link $DIR
    fi
  done
  umount -l /dev/random
  ) 2>/dev/null
  [ -z $OLD_LD_LIB ] || export LD_LIBRARY_PATH=$OLD_LD_LIB
  [ -z $OLD_LD_PRE ] || export LD_PRELOAD=$OLD_LD_PRE
  [ -z $OLD_LD_CFG ] || export LD_CONFIG_FILE=$OLD_LD_CFG
}

find_block() {
  local BLOCK DEV DEVICE DEVNAME PARTNAME UEVENT
  for BLOCK in "$@"; do
    # P1 bug fix: the `2>/dev/null` was outside the pipe, so it only
    # suppressed `head` errors. Move it inside the find subshell so
    # permission-denied noise from traversing /dev/block is silenced.
    DEVICE=$(find /dev/block \( -type b -o -type c -o -type l \) -iname "$BLOCK" 2>/dev/null | head -n 1)
    if [ ! -z $DEVICE ]; then
      readlink -f $DEVICE
      return 0
    fi
  done
  # Fallback by parsing sysfs uevents
  for UEVENT in /sys/dev/block/*/uevent; do
    DEVNAME=$(grep_prop DEVNAME $UEVENT)
    PARTNAME=$(grep_prop PARTNAME $UEVENT)
    for BLOCK in "$@"; do
      if [ "$(toupper $BLOCK)" = "$(toupper $PARTNAME)" ]; then
        echo /dev/block/$DEVNAME
        return 0
      fi
    done
  done
  # Look just in /dev in case we're dealing with MTD/NAND without /dev/block devices/links
  for DEV in "$@"; do
    DEVICE=$(find /dev \( -type b -o -type c -o -type l \) -maxdepth 1 -iname $DEV | head -n 1) 2>/dev/null
    if [ ! -z $DEVICE ]; then
      readlink -f $DEVICE
      return 0
    fi
  done
  return 1
}

# After calling this method, the following variables will be set:
# SLOT
get_current_slot() {
  # Check A/B slot
  SLOT=$(grep_cmdline androidboot.slot_suffix)
  if [ -z $SLOT ]; then
    SLOT=$(grep_cmdline androidboot.slot)
    [ -z $SLOT ] || SLOT=_${SLOT}
  fi
  if [ -z $SLOT ]; then
    SLOT=$(getprop ro.boot.slot_suffix)
  fi
  [ "$SLOT" = "normal" ] && unset SLOT
  [ -z $SLOT ] || echo "SLOT=$SLOT"
}

# After calling this method, the following variables will be set:
# SLOT
# This is used after OTA
get_next_slot() {
  # Check A/B slot
  SLOT=$(grep_cmdline androidboot.slot_suffix)
  if [ -z $SLOT ]; then
    SLOT=$(grep_cmdline androidboot.slot)
    [ -z $SLOT ] || SLOT=_${SLOT}
  fi
  if [ -z $SLOT ]; then
    SLOT=$(getprop ro.boot.slot_suffix)
  fi
   [ -z $SLOT ] && { >&2 echo "can't determined next boot slot! check your devices is A/B"; exit 1; }
   [ "$SLOT" = "normal" ] &&  { >&2 echo "can't determined next boot slot! check your devices is A/B"; exit 1; }
  # P0-1: was `[[ $SLOT == *_a ]]` (bash-ism). util_functions.sh has a
  # POSIX /system/bin/sh shebang (mksh/Toybox ash on Android) which does
  # not understand `[[`. case is portable across both.
  case "$SLOT" in
    *_a) SLOT='_b' ;;
    *)   SLOT='_a' ;;
  esac
  echo "SLOT=$SLOT"
}

find_boot_image() {
  if [ ! -z $SLOT ]; then
    BOOTIMAGE=$(find_block "boot$SLOT")
  fi
  if [ -z $BOOTIMAGE ]; then
    BOOTIMAGE=$(find_block kern-a android_boot kernel bootimg boot lnx boot_a)
  fi
  if [ -z $BOOTIMAGE ]; then
    # Lets see what fstabs tells me
    BOOTIMAGE=$(grep -v '#' /etc/*fstab* | grep -E '/boot(img)?[^a-zA-Z]' | grep -oE '/dev/[a-zA-Z0-9_./-]*' | head -n 1)
  fi
  if [ -z $BOOTIMAGE ]; then
    # Fallback: try vendor_boot / init_boot (GKI devices)
    BOOTIMAGE=$(find_block "vendor_boot$SLOT" "vendor_boot" "init_boot$SLOT" "init_boot")
  fi
  [ -z $BOOTIMAGE ] || echo "BOOTIMAGE=$BOOTIMAGE"
}

flash_image() {
  # P0-2 security fix: previously this function built a shell command string
  # by embedding $1 (the source file path) inside single-quotes and then ran
  # it through `eval`, which allowed single-quote escape sequences in the
  # path to execute arbitrary shell commands as root. We now branch into
  # plain command pipelines — no eval, no string interpolation.
  #
  # P0-7 error-propagation fix: every prior revision ended with an
  # unconditional `return 0`, which made the caller's `$? -ne 0` check
  # (boot_patch.sh:391) dead code. Flashing a corrupt image would
  # succeed silently and brick the device. Capture each pipeline's
  # exit status and propagate the worst one.
  local _rc=0
  if [ -b "$2" ]; then {
      local img_sz=$(stat -c '%s' "$1")
      local blk_sz=$(blockdev --getsize64 "$2")
      local blk_bs=$(blockdev --getbsz "$2")
      [ "$img_sz" -gt "$blk_sz" ] && return 1
      blockdev --setrw "$2"
      local blk_ro=$(blockdev --getro "$2")
      [ "$blk_ro" -eq 1 ] && return 2
      case "$1" in
        *.gz) gzip -d < "$1" 2>/dev/null | dd of="$2" bs="$blk_bs" iflag=fullblock conv=notrunc,fsync 2>/dev/null;;
        *)    cat "$1"                   | dd of="$2" bs="$blk_bs" iflag=fullblock conv=notrunc,fsync 2>/dev/null;;
      esac
      _rc=$?
      sync
  } elif [ -c "$2" ]; then {
      flash_eraseall "$2" >&2
      local _nand_rc=0
      case "$1" in
        *.gz) gzip -d < "$1" 2>/dev/null | nandwrite -p "$2" - >&2;;
        *)    cat "$1"                   | nandwrite -p "$2" - >&2;;
      esac
      _nand_rc=$?
      [ "$_nand_rc" -ne 0 ] && _rc=$_nand_rc
  } else {
      echo "- Not block or char device, storing image"
      case "$1" in
        *.gz) gzip -d < "$1" > "$2" 2>/dev/null;;
        *)    cat    "$1"    > "$2" 2>/dev/null;;
      esac
      _rc=$?
  } fi
  return "$_rc"
}

save_image_to_storage() {
  local IMAGE=$1
  local DATE=$(date +%y%m%d%H%M)
  local FILENAME="patchnest_patched_$DATE.img"
  local OUT="/storage/emulated/0/Download/$FILENAME"

  cp -f "$IMAGE" "$OUT"
  echo "- Patched image saved to $OUT"
}

setup_mntpoint() {
  local POINT=$1
  [ -L $POINT ] && mv -f $POINT ${POINT}_link
  if [ ! -d $POINT ]; then
    rm -f $POINT
    mkdir -p $POINT
  fi
}

mount_name() {
  local PART=$1
  local POINT=$2
  local FLAG=$3
  setup_mntpoint $POINT
  is_mounted $POINT && return
  # First try mounting with fstab
  mount $FLAG $POINT 2>/dev/null
  if ! is_mounted $POINT; then
    local BLOCK=$(find_block $PART)
    mount $FLAG $BLOCK $POINT || return
  fi
  ui_print "- Mounting $POINT"
}

mount_ro_ensure() {
  # We handle ro partitions only in recovery
  $BOOTMODE && return
  local PART=$1
  local POINT=$2
  mount_name "$PART" $POINT '-o ro'
  is_mounted $POINT || abort "! Cannot mount $POINT"
}

# After calling this method, the following variables will be set:
# SLOT, SYSTEM_AS_ROOT, LEGACYSAR
mount_partitions() {
  # P2 consistency: the slot-detection dance below is a copy of
  # get_current_slot() (lines 217-229). Reuse the helper to keep the
  # two paths in sync — if upstream Magisk changes the heuristic,
  # we only need to update one place.
  get_current_slot
  [ -z $SLOT ] || ui_print "- Current boot slot: $SLOT"

  # Mount ro partitions
  if is_mounted /system_root; then
    umount /system 2>/dev/null
    umount /system_root 2>/dev/null
  fi
  mount_ro_ensure "system$SLOT app$SLOT" /system
  if [ -f /system/init -o -L /system/init ]; then
    SYSTEM_AS_ROOT=true
    setup_mntpoint /system_root
    if ! mount --move /system /system_root; then
      umount /system
      umount -l /system 2>/dev/null
      mount_ro_ensure "system$SLOT app$SLOT" /system_root
    fi
    mount -o bind /system_root/system /system
  else
    if grep ' / ' /proc/mounts | grep -qv 'rootfs' || grep -q ' /system_root ' /proc/mounts; then
      SYSTEM_AS_ROOT=true
    else
      SYSTEM_AS_ROOT=false
    fi
  fi
  $SYSTEM_AS_ROOT && ui_print "- Device is system-as-root"

  LEGACYSAR=false
  if $BOOTMODE; then
    # P1-Cluster D fix: also detect LEGACYSAR via cmdline hints
    # (androidboot.super_partition absent + a rootfs entry). The previous
    # '/dev/root' heuristic mis-fired on some GKI 2.0 devices that show
    # /dev/root in /proc/mounts but actually use dynamic partitions.
    if grep -q 'androidboot.super_partition' /proc/cmdline || \
       [ -n "$(find_block super)" ]; then
      LEGACYSAR=false
    elif grep ' / ' /proc/mounts | grep -q '/dev/root'; then
      LEGACYSAR=true
    fi
  else
    # Recovery mode, assume devices that don't use dynamic partitions are legacy SAR
    local IS_DYNAMIC=false
    if grep -q 'androidboot.super_partition' /proc/cmdline; then
      IS_DYNAMIC=true
    elif [ -n "$(find_block super)" ]; then
      IS_DYNAMIC=true
    fi
    if $SYSTEM_AS_ROOT && ! $IS_DYNAMIC; then
      LEGACYSAR=true
      ui_print "- Legacy SAR, force kernel to load rootfs"
    fi
  fi
}

get_flags() {
  if grep ' /data ' /proc/mounts | grep -q 'dm-'; then
    ISENCRYPTED=true
  elif [ "$(getprop ro.crypto.state)" = "encrypted" ]; then
    ISENCRYPTED=true
  elif [ "$DATA" = "false" ]; then
    # No data access means unable to decrypt in recovery
    ISENCRYPTED=true
  else
    ISENCRYPTED=false
  fi
  if [ -n "$(find_block vbmeta vbmeta_a)" ]; then
    PATCHVBMETAFLAG=false
  else
    PATCHVBMETAFLAG=true
    ui_print "- No vbmeta partition, patch vbmeta in boot image"
  fi

  # Overridable config flags with safe defaults
  getvar KEEPVERITY
  getvar KEEPFORCEENCRYPT
  getvar RECOVERYMODE
  if [ -z $KEEPVERITY ]; then
    if $SYSTEM_AS_ROOT; then
      KEEPVERITY=true
      ui_print "- System-as-root, keep dm-verity"
    else
      KEEPVERITY=false
    fi
  fi
  if [ -z $KEEPFORCEENCRYPT ]; then
    if $ISENCRYPTED; then
      KEEPFORCEENCRYPT=true
      ui_print "- Encrypted data, keep forceencrypt"
    else
      KEEPFORCEENCRYPT=false
    fi
  fi
  [ -z $RECOVERYMODE ] && RECOVERYMODE=false
}

install_apatch() {
  cd $MAGISKBIN

  # Source the boot patcher
  SOURCEDMODE=true
  . ./boot_patch.sh "$BOOTIMAGE"
  ui_print "- Flashing new boot image"
  flash_image new-boot.img "$BOOTIMAGE"
  case $? in
    1)
      abort "! Insufficient partition size"
      ;;
    2)
      abort "! $BOOTIMAGE is read only"
      ;;
  esac
  ./magiskboot cleanup
  rm -f new-boot.img

  run_migrations
}

check_data() {
  DATA=false
  DATA_DE=false
  if grep ' /data ' /proc/mounts | grep -vq 'tmpfs'; then
    # Test if data is writable
    touch /data/.rw && rm /data/.rw && DATA=true
    # Test if data is decrypted
    $DATA && [ -d /data/adb ] && touch /data/adb/.rw && rm /data/adb/.rw && DATA_DE=true
    $DATA_DE && [ -d /data/adb/magisk ] || mkdir /data/adb/magisk || DATA_DE=false
  fi
  set_nvbase "/data"
  $DATA || set_nvbase "/cache/data_adb"
  $DATA_DE && set_nvbase "/data/adb"
}

# After calling this method, the following variables will be set:
# API, ABI, ARCH, ABI32, IS64BIT
api_level_arch_detect() {
  API=$(grep_get_prop ro.build.version.sdk)
  ABI=$(grep_get_prop ro.product.cpu.abi)
  if [ "$ABI" = "x86" ]; then
    ARCH=x86
    ABI32=x86
    IS64BIT=false
  elif [ "$ABI" = "arm64-v8a" ]; then
    ARCH=arm64
    ABI32=armeabi-v7a
    IS64BIT=true
  elif [ "$ABI" = "x86_64" ]; then
    ARCH=x64
    ABI32=x86
    IS64BIT=true
  else
    ARCH=arm
    ABI=armeabi-v7a
    ABI32=armeabi-v7a
    IS64BIT=false
  fi
}

remove_system_su() {
  # P0-2: POSTINST was only set when /postinstall/tmp existed. If it
  # didn't, the next `cd $POSTINST/system` collapsed to `cd /system`
  # (POSIX leaves unset vars empty, the path is interpreted as a
  # relative-to-root `system` lookup), and we then `rm`d `bin/su` from
  # the *live* running filesystem. Guard explicitly.
  if [ -d /postinstall/tmp ]; then
    POSTINST=/postinstall
  else
    >&2 echo "! /postinstall/tmp missing; skipping system su removal"
    return 0
  fi
  cd "$POSTINST/system" || { >&2 echo "! cannot cd $POSTINST/system"; return 1; }
  if [ -f bin/su -o -f xbin/su ] && [ ! -f /su/bin/su ]; then
    ui_print "- Removing system installed root"
    blockdev --setrw /dev/block/mapper/system$SLOT 2>/dev/null
    mount -o rw,remount $POSTINST/system
    # SuperSU
    cd bin
    if [ -e .ext/.su ]; then
      mv -f app_process32_original app_process32 2>/dev/null
      mv -f app_process64_original app_process64 2>/dev/null
      mv -f install-recovery_original.sh install-recovery.sh 2>/dev/null
      if [ -e app_process64 ]; then
        ln -sf app_process64 app_process
      elif [ -e app_process32 ]; then
        ln -sf app_process32 app_process
      fi
    fi
    # More SuperSU, SuperUser & ROM su
    cd ..
    rm -rf .pin bin/.ext etc/.installed_su_daemon etc/.has_su_daemon \
    xbin/daemonsu xbin/su xbin/sugote xbin/sugote-mksh xbin/supolicy \
    bin/app_process_init bin/su /cache/su lib/libsupol.so lib64/libsupol.so \
    su.d etc/init.d/99SuperSUDaemon etc/install-recovery.sh /cache/install-recovery.sh \
    .supersu /cache/.supersu /data/.supersu \
    app/Superuser.apk app/SuperSU /cache/Superuser.apk
  elif [ -f /cache/su.img -o -f /data/su.img -o -d /data/su -o -d /data/adb/su ]; then
    ui_print "- Removing systemless installed root"
    umount -l /su 2>/dev/null
    rm -rf /cache/su.img /data/su.img /data/su /data/adb/su /data/adb/suhide \
    /cache/.supersu /data/.supersu /cache/supersu_install /data/supersu_install
  fi
  cd $TMPDIR
}

run_migrations() {
  local LOCSHA1
  local TARGET
  # Legacy app installation
  local BACKUP=$MAGISKBIN/stock_boot*.gz
  if [ -f $BACKUP ]; then
    cp $BACKUP /data
    rm -f $BACKUP
  fi

  # Legacy backup
  for gz in /data/stock_boot*.gz; do
    [ -f $gz ] || break
    LOCSHA1=$(basename $gz | sed -e 's/stock_boot_//' -e 's/.img.gz//')
    [ -z $LOCSHA1 ] && break
    mkdir /data/magisk_backup_${LOCSHA1} 2>/dev/null
    mv $gz /data/magisk_backup_${LOCSHA1}/boot.img.gz
  done

  # Stock backups
  LOCSHA1=$SHA1
  for name in boot dtb dtbo dtbs; do
    BACKUP=$MAGISKBIN/stock_${name}.img
    [ -f $BACKUP ] || continue
    if [ $name = 'boot' ]; then
      LOCSHA1=$($MAGISKBIN/magiskboot sha1 $BACKUP)
      mkdir /data/magisk_backup_${LOCSHA1} 2>/dev/null
    fi
    TARGET=/data/magisk_backup_${LOCSHA1}/${name}.img
    cp $BACKUP $TARGET
    rm -f $BACKUP
    gzip -9f $TARGET
  done
}