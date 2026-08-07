# PatchNest offline hardening audit — 2026-08-07

This document records the work performed without GitHub Actions and without a
physical device. It distinguishes source-level guarantees from checks that
still require real boot, rollback, and recovery evidence.

## Scope

Reviewed paths:

- `module/patch/boot_extract.sh`
- `module/patch/boot_patch.sh`
- `module/patch/boot_unpatch.sh`
- `module/patch/util_functions.sh`
- `module/post-fs-data.sh`
- `module/service.sh`
- `webui/page/patch.js`
- `webui/page/boot_unpatch.js`

Added offline tooling:

- `scripts/offline_audit.py`
- `tests/test_offline_audit.py`
- `tests/validate_boot_hardening.py`
- `scripts/collect_device_evidence.sh`

## Confirmed defects in the previous main branch

### 1. Wrong-partition fallback

`find_boot_image()` could fall back to `vendor_boot` or `init_boot` when no
`boot` partition was found. KernelPatch expects a boot image that actually
contains the kernel payload. Silently accepting the other partitions can lead
to an unpack without `kernel`, patching the wrong object, or writing the wrong
partition.

**Remediation:** `boot_extract.sh`, `boot_patch.sh`, and `boot_unpatch.sh` now
source `flash_guard.sh`. Discovered/direct-flash targets are resolved through
by-name links or sysfs `PARTNAME`; `vendor_boot*` and `init_boot*` are rejected.

### 2. No block-device readback proof

The prior flash helper checked the write command's exit status but did not read
the exact source length back from the block device and compare its digest.

**Remediation:** direct block writes now require:

1. existing non-empty source;
2. supported boot target;
3. target capacity check;
4. successful `blockdev --setrw` and `--getro=0`;
5. `dd ... conv=notrunc,fsync` success;
6. exact-length SHA-256 readback equality.

Character-device NAND writes are disabled because the same verification proof
has not yet been implemented for that path.

### 3. Backup collision and incomplete manifest

Backup filenames had minute-only resolution. Repeated operations could replace
one another. The manifest did not persist the backup file's digest.

**Remediation:** backup names include UTC-like seconds and the shell PID. A
backup is retained only after an independent `magiskboot unpack` succeeds. Its
SHA-256 is stored as both `original_sha256` and `backup_sha256`, and
`backup_verified` is set only in the final atomic manifest.

### 4. Recovery selected newest file rather than correct file

The previous `auto_unpatch()` selected the newest `boot_backup_*.img` by mtime.
It accepted manifest-less legacy backups and did not bind the selected image to
the active target partition or a stored digest.

**Remediation:** recovery selection now requires all of the following:

- non-empty image;
- sidecar manifest;
- `backup_verified=true`;
- manifest target matching the current boot target;
- valid 64-character `backup_sha256`;
- current file digest matching the manifest;
- successful independent unpack with a non-empty kernel payload.

No legacy or ambiguous fallback remains.

### 5. Stale `new-boot.img` reuse

Normal unpatch could see a `new-boot.img` left by an interrupted prior run,
skip regeneration, and flash it.

**Remediation:** patch and unpatch remove all work artifacts before unpacking.
Unpatch always generates a new kernel, confirms `patched=true` is gone, repacks,
re-opens the exact output image, and only then flashes it.

### 6. Sensitive `set -x` around kptools

The previous patcher enabled shell tracing around the complete `kptools`
command. Arguments may include a superkey, so logs could expose sensitive
material.

**Remediation:** tracing is removed. Error reporting records only the exit
status and safe phase name.

### 7. Embedded KPM verification failed open

An embedded KPM that `kptools` could not parse produced a warning and continued.

**Remediation:** every `-M <path>` must be non-empty and pass `kptools -l -M`.
Missing arguments and unverifiable modules stop the patch before kernel output
is generated.

### 8. “Automatic recovery” was only a marker

`post-fs-data.sh` incremented a counter and created marker files, but no early
boot path invoked verified restoration. The previous comments could therefore
imply an automatic write that did not occur.

**Remediation:** the script now explicitly records a recovery request and
`automatic_flash_performed=false`. It never writes a block device. A future
early-boot executor must still select a target-bound verified backup.

## Source-level guarantees added

The offline branch now enforces these source contracts:

- no stale work artifact reuse;
- no direct `vendor_boot/init_boot` target;
- no unverified character-device flash;
- no direct block flash without readback digest equality;
- no retained backup without unpack validation and SHA-256;
- no auto recovery from a manifest-less or target-mismatched image;
- no repacked image flash without an independent unpack check;
- no embedded KPM continuation after verification failure;
- no shell tracing of patch arguments.

## Explicitly not proven

Static review cannot establish:

- that every supported ROM exposes a usable sysfs `PARTNAME` or by-name link;
- that the active slot mapping remains stable across OTA transitions;
- that `dd` + `fsync` behavior is correct on every boot block driver;
- that boot image repacking preserves OEM-specific headers and signatures;
- successful boot on A/B and non-A/B devices;
- rollback after a failed boot;
- safe handling of NAND character-device boot storage;
- KPM load/control/unload behavior after reboot;
- compatibility with every Magisk, KernelSU, APatch, and recovery environment.

No release should be produced from this branch until the device matrix is
completed and evidence is attached to the exact tested commit.
