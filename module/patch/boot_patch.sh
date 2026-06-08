#!/system/bin/sh
#######################################################################################
# APatch Boot Image Patcher
# Imported from https://github.com/bmax121/APatch/blob/main/app/src/main/assets/boot_patch.sh
#######################################################################################
#
# Usage: boot_patch.sh <superkey> <bootimage> [ARGS_PASS_TO_KPTOOLS]
#
# Optional environment variables / flags:
#   KP_REBACKUP=1    Force a fresh backup of the current boot image, even if
#                    a backup already exists. Use this when the WebUI knows
#                    the user re-flashed a known root tool (AK3 / Magisk /
#                    KSU) and the existing backup is stale.
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
PNDIR="/data/adb/patchnest"
BACKUP_DIR="$PNDIR/backup"
# Caller may set KP_REBACKUP=1 to force re-backing up even when a
# backup already exists. Default off so an unset var is harmless.
KP_REBACKUP="${KP_REBACKUP:-0}"

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
	echo "! PatchNest is not compatible alongside built-in KPM."
	exit 1
fi

if [ -z "$(kptools -i kernel -f 2>/dev/null | grep CONFIG_KALLSYMS_ALL=y)" ]; then
	echo "! Patcher has Aborted."
	echo "! PatchNest requires CONFIG_KALLSYMS_ALL to be Enabled."
	echo "! But your kernel seems NOT enabled it."
	exit 1
fi

# ============================================================
# AK3 / Magisk / KSU / APatch root-chain detection
# Writes a small JSON manifest next to the backup image so that
# auto_unpatch (and the WebUI) know what was preserved vs. lost
# at recovery time. This is the "what's in this backup" record.
#
# The manifest is intentionally simple — pure shell + getprop —
# so it can be parsed by the WebUI without any kpatch-side helper.
# ============================================================
detect_root_chain() {
    local BOOT_FILE="$1"
    local MANIFEST_PATH="$2"

    # 1. Kp marker: patched=true|false in kptools output
    local KP_STATE="stock"
    if kptools -i kernel -l 2>/dev/null | grep -q "patched=true"; then
        KP_STATE="patched"
    fi

    # 2. Magisk: presence of /data/adb/magisk or `magisk --version`
    local MAGISK_VER="null"
    if [ -d /data/adb/magisk ] || ls /data/adb/magisk >/dev/null 2>&1; then
        KP_STATE="magisk"
        # `magisk --version` prints e.g. "27.0:topjohnwu:15000"
        MAGISK_VER=$(magisk --version 2>/dev/null | head -n 1 | cut -d: -f1)
        [ -z "$MAGISK_VER" ] && MAGISK_VER="null"
    fi

    # 3. KSU: /data/adb/ksu dir or /sys/module/ksu loaded
    local KSU_VER="null"
    if [ -d /data/adb/ksu ] || [ -d /sys/module/ksu ] || ls /data/adb/ksu >/dev/null 2>&1; then
        KSU_VER=$(ksu --version 2>/dev/null | head -n 1 | tr -d '\r\n')
        [ -z "$KSU_VER" ] && KSU_VER="null"
        # Magisk + KSU together is unusual; if KSU is the primary root,
        # # upgrade the state. Don't overwrite "magisk" precedence — the
        # WebUI displays both fields.
    fi

    # 4. APatch: /data/adb/ap
    if [ -d /data/adb/ap ] || ls /data/adb/ap >/dev/null 2>&1; then
        KP_STATE="apatch"
    fi

    # 5. Kernel cmdline hint (verified boot state) — used by the WebUI
    # to warn the user if the backup is from a green→yellow→red flip.
    local CMDLINE_HINT=$(getprop ro.boot.vbmeta.device_state)
    [ -z "$CMDLINE_HINT" ] && CMDLINE_HINT="unknown"

    # 6. kpimg size, if present alongside this script
    local KPIMG_SIZE=0
    if [ -f "$MODPATH/kpimg" ]; then
        KPIMG_SIZE=$(wc -c < "$MODPATH/kpimg" 2>/dev/null | tr -d ' ')
        [ -z "$KPIMG_SIZE" ] && KPIMG_SIZE=0
    fi

    # 7. Original (current) boot image SHA256 — used by
    # is_boot_modified_externally() to detect re-flashes.
    local ORIG_SHA="null"
    if [ -f "$BOOT_FILE" ]; then
        if command -v sha256sum >/dev/null 2>&1; then
            ORIG_SHA=$(sha256sum "$BOOT_FILE" 2>/dev/null | awk '{print $1}')
        elif command -v magiskboot >/dev/null 2>&1; then
            # magiskboot supports `magiskboot sha256 <file>` on newer builds.
            ORIG_SHA=$(magiskboot sha256 "$BOOT_FILE" 2>/dev/null | head -n 1 | tr -d ' ')
        fi
    fi
    [ -z "$ORIG_SHA" ] && ORIG_SHA="null"

    # 8. ISO-ish timestamp (UTC, no colons — POSIX-safe filename suffix).
    local TAKEN_AT
    TAKEN_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

    # 9. Sanitize string fields: replace " with \", strip control chars.
    # (We never let user-supplied data flow into these fields, but be
    # defensive — this manifest is parsed by the WebUI as JSON.)
    # P0-8: sed substitution order was inverted. The previous form
    # escaped `"` first, producing `\\"` for an input like `foo"`,
    # and then escaped `\` — but the `\` we just inserted for the
    # quote escape got re-doubled to `\\\\"`, yielding a literal
    # backslash followed by a quote in the output JSON, which is
    # invalid (`"foo\"bar"`, not `"foo\\"bar"`). Escape the
    # backslash FIRST so any later quote-escape produces a clean
    # `\"` rather than a doubled `\\\"`.
    json_escape() {
        printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
    }

    local SAFE_KPSTATE KPSTATE_ESC
    KPSTATE_ESC=$(json_escape "$KP_STATE")
    local SAFE_MAGVER
    SAFE_MAGVER=$(json_escape "$MAGISK_VER")
    local SAFE_KSUVER
    SAFE_KSUVER=$(json_escape "$KSU_VER")
    local SAFE_HINT
    SAFE_HINT=$(json_escape "$CMDLINE_HINT")
    local SAFE_SHA
    SAFE_SHA=$(json_escape "$ORIG_SHA")

    cat > "$MANIFEST_PATH" <<EOF
{
  "boot_image": "$(json_escape "$(basename "$BOOT_FILE")")",
  "taken_at": "$TAKEN_AT",
  "kp_state": "$KPSTATE_ESC",
  "magisk_version": "$SAFE_MAGVER",
  "ksu_version": "$SAFE_KSUVER",
  "kpimg_size": $KPIMG_SIZE,
  "kernel_cmdline_hint": "$SAFE_HINT",
  "original_sha256": "$SAFE_SHA",
  "backup_verified": false
}
EOF
}

# ============================================================
# is_boot_modified_externally()
# Compares the SHA256 of the current BOOTIMAGE against the
# `original_sha256` field in the latest manifest. Returns 0
# (true) if they differ, 1 (false) if they match, 2 if the
# inputs are missing.
#
# This is the "user re-flashed AK3" detector. The WebUI calls
# us via KP_REBACKUP=1 when the user explicitly re-flashes a
# known root tool.
# ============================================================
is_boot_modified_externally() {
    local BOOT_FILE="$1"
    local LATEST_MANIFEST="$2"

    [ -f "$BOOT_FILE" ] || return 2
    [ -f "$LATEST_MANIFEST" ] || return 2

    local CUR_SHA
    if command -v sha256sum >/dev/null 2>&1; then
        CUR_SHA=$(sha256sum "$BOOT_FILE" 2>/dev/null | awk '{print $1}')
    else
        CUR_SHA=$(magiskboot sha256 "$BOOT_FILE" 2>/dev/null | head -n 1 | tr -d ' ')
    fi
    [ -n "$CUR_SHA" ] || return 2

    # Naive JSON value extraction — our writer controls the format
    # and the field is always a 64-char hex string, so this is safe.
    local REC_SHA
    REC_SHA=$(grep -o '"original_sha256"[[:space:]]*:[[:space:]]*"[^"]*"' "$LATEST_MANIFEST" 2>/dev/null \
        | head -n 1 | sed -E 's/.*"original_sha256"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')

    [ -n "$REC_SHA" ] && [ "$REC_SHA" != "null" ] || return 2
    [ "$CUR_SHA" = "$REC_SHA" ] && return 1
    return 0
}

# Pick the most recent manifest path under BACKUP_DIR (or empty).
latest_manifest() {
    ls -1t "$BACKUP_DIR"/boot_backup_*.json 2>/dev/null | head -n 1
}

# ============================================================
# Step 1: detect root chain & write manifest-draft.json
# This is "what we *think* is in the current boot image" — it
# becomes the draft manifest that follows the backup through
# validation. If the backup step is skipped (e.g. we already
# have a backup) the draft is dropped; otherwise it is promoted
# to the final manifest after magiskboot validates the backup.
# ============================================================
mkdir -p "$BACKUP_DIR"
TMP_DATE=$(date +%y%m%d%H%M)
TMP_BACKUP="$BACKUP_DIR/boot_backup_${TMP_DATE}.img"
TMP_MANIFEST="$BACKUP_DIR/boot_backup_${TMP_DATE}.json"

echo "- Detecting root chain (Kp / Magisk / KSU / APatch)…"
detect_root_chain "$BOOTIMAGE" "$TMP_MANIFEST"
echo "- Manifest draft: $TMP_MANIFEST"

# ============================================================
# Step 2: take backup + decide re-backup
# The original behaviour is: only back up when kptools reports
# patched=false (i.e. the user is patching a stock / already-
# rooted boot for the first time). We preserve that as the
# *default*, but allow two re-backup triggers:
#
#   1. KP_REBACKUP=1 was passed by the WebUI (user explicitly
#      re-flashed a known root tool, e.g. a newer AK3 build).
#   2. The current boot image SHA256 differs from the
#      `original_sha256` stored in the *latest* manifest AND
#      that manifest records kp_state="patched" (i.e. the user
#      was rootful and the boot was modified after the last
#      backup). This is the silent re-backup path.
# ============================================================
SHOULD_BACKUP=0
# Validate that 'kernel' is a readable, non-empty file before relying on
# the patched=false check. If 'kernel' is missing or empty (e.g. from a
# previous failed run), kptools -l would silently produce empty output
# and we'd skip the backup.
if [ -s kernel ]; then
  if [ -n "$(kptools -i kernel -l 2>/dev/null | grep patched=false)" ]; then
    SHOULD_BACKUP=1
  fi
else
  >&2 echo "! kernel file missing or empty before backup check"
  exit 1
fi

if [ "$SHOULD_BACKUP" -eq 0 ] && [ "$KP_REBACKUP" = "1" ]; then
    echo "- KP_REBACKUP=1: forcing fresh backup"
    SHOULD_BACKUP=1
fi

if [ "$SHOULD_BACKUP" -eq 0 ]; then
    LATEST=$(latest_manifest)
    if [ -n "$LATEST" ] && is_boot_modified_externally "$BOOTIMAGE" "$LATEST"; then
        LATEST_KPSTATE=$(grep -o '"kp_state"[[:space:]]*:[[:space:]]*"[^"]*"' "$LATEST" 2>/dev/null \
            | head -n 1 | sed -E 's/.*"kp_state"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
        if [ "$LATEST_KPSTATE" = "patched" ]; then
            echo "- Boot image SHA256 differs from last backup (kp_state=patched) — taking re-backup"
            SHOULD_BACKUP=1
        fi
    fi
fi

if [ "$SHOULD_BACKUP" -eq 1 ]; then
    echo "- Backing boot.img"
    cp "$BOOTIMAGE" "ori.img" >/dev/null 2>&1
    cp "$BOOTIMAGE" "$TMP_BACKUP"
    echo "- Boot backup saved to $TMP_BACKUP"

    # ============================================================
    # Step 3: validate the backup BEFORE patching.
    # A corrupt/empty backup is worse than no backup at all —
    # auto_unpatch would brick the device. Refuse and bail out.
    # ============================================================
    echo "- Validating backup with magiskboot unpack…"
    VALIDATE_TMP=$(mktemp -d)
    if ! (cd "$VALIDATE_TMP" && magiskboot unpack "$TMP_BACKUP" >/dev/null 2>&1); then
        >&2 echo "! Backup validation FAILED — refusing to patch."
        >&2 echo "! The captured boot image is corrupt or empty."
        >&2 echo "! Removing bad backup: $TMP_BACKUP"
        rm -f "$TMP_BACKUP" "$TMP_MANIFEST"
        rm -rf "$VALIDATE_TMP"
        exit 1
    fi
    rm -rf "$VALIDATE_TMP"
    echo "- Backup verified."

    # ============================================================
    # Step 5: promote the draft manifest to the final manifest.
    # We use sed to flip backup_verified:false → true. This avoids
    # re-running detect_root_chain() (which would re-evaluate the
    # now-flashed state and yield a different kp_state).
    # ============================================================
    sed 's/"backup_verified"[[:space:]]*:[[:space:]]*false/"backup_verified": true/' "$TMP_MANIFEST" > "$TMP_MANIFEST.final"
    mv "$TMP_MANIFEST.final" "$TMP_MANIFEST"
    echo "- Manifest finalized: $TMP_MANIFEST"
else
    # No new backup → drop the draft manifest; the previous one
    # remains authoritative.
    rm -f "$TMP_MANIFEST"
fi

mv kernel kernel.ori

# ============================================================
# Validate embedded KPMs before patching
# Parse -M <kpm_file> from args and validate each one
# ============================================================
echo "- Validating embedded modules..."
validate_failed=0
# Use a positional parse so the first -M <file> is also captured.
# prev_flag is initialized to a sentinel that will never match a real flag.
prev_flag="__start__"
for arg in "$@"; do
    case "$prev_flag" in
        -M)
            kpm_file="$arg"
            if [ ! -f "$kpm_file" ]; then
                echo "! Embedded KPM not found: $kpm_file"
                validate_failed=1
                prev_flag="$arg"
                continue
            fi
            # Check ELF magic (7f 45 4c 46)
            magic=$(xxd -l 4 -p "$kpm_file" 2>/dev/null)
            if [ "$magic" != "7f454c46" ]; then
                echo "! Invalid ELF: $kpm_file (magic=$magic)"
                validate_failed=1
                prev_flag="$arg"
                continue
            fi
            # Check aarch64 (e_machine = 0xB7 at offset 18, little-endian)
            machine=$(xxd -s 18 -l 2 -e "$kpm_file" 2>/dev/null | awk '{print $2}')
            if [ "$machine" != "000000b7" ]; then
                echo "! Not aarch64: $kpm_file"
                validate_failed=1
                prev_flag="$arg"
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
if ! magiskboot repack "$BOOTIMAGE" >/dev/null 2>&1; then
  >&2 echo "! Repack error"
  exit 1
fi

if [ "$FLASH_TO_DEVICE" = "true" ]; then
  # flash
  if [ -b "$BOOTIMAGE" ] || [ -c "$BOOTIMAGE" ]; then
    if [ -f "new-boot.img" ]; then
      echo "- Flashing new boot image"
      flash_image new-boot.img "$BOOTIMAGE"
      if [ $? -ne 0 ]; then
        >&2 echo "! Flash error"
        save_image_to_storage "new-boot.img"
        exit 1
      fi
    else
      >&2 echo "! new-boot.img missing — refusing to flash"
      exit 1
    fi
  fi

  echo "- Successfully Flashed!"
else
  save_image_to_storage "new-boot.img"
  echo "- Successfully Patched!"
fi

