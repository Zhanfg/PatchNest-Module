# PatchNest flash-readiness review

Status: **NOT FLASH READY**

This document is the live release gate for `review/flash-readiness-hardening`. A green source/package CI run is necessary but is not sufficient to remove this gate.

## P0 blockers

### FR-001 — Packaged kernel and CLI belong to different supercall ABI families

Current `version.properties` combines:

- `Zhanfg/KernelPatch-Public` `0.13.3` (`hello1158`, magic `0x11581158`, key/su authentication, KPM event/safemode extensions);
- `Zhanfg/PatchNest` `0.13.5-2`, reproduced from the KPatch-Next userspace snapshot (`hello2026`, magic `0x20262026`, NULL-key userspace call convention, no matching event command).

KernelPatch-Public masks the packed command to the low 16 bits, so the high token alone is not the blocker. The handshake magic, authentication convention, and extension command surface are different. Package-level compatibility has not been demonstrated.

**Gate:** one reviewed ABI profile must own `kpimg`, `kptools`, `kpatch`, safemode and lifecycle-event behavior. Mixed profiles are forbidden unless an explicit compatibility layer is implemented and tested.

### FR-002 — Shared patch working directory can reuse stale images

`boot_patch.sh` / `boot_unpatch.sh` currently use shared names such as `kernel`, `kernel.ori`, `ori.img` and `new-boot.img`, and may skip unpacking when `kernel` already exists.

**Gate:** each patch/unpatch operation must use a fresh private `mktemp -d` workspace, unpack the requested boot image unconditionally, and remove the workspace with a trap.

### FR-003 — Recovery selection is not bound to the flash target

`auto_unpatch()` currently chooses the newest backup by mtime. Older manifests are optional and `backup_verified=false` is not a hard rejection. Slot/partition/device identity is not bound to the selected backup.

**Gate:** automatic restore may only select a backup whose manifest is present, `backup_verified=true`, digest-valid, and bound to the exact target partition/slot/device identity. Otherwise it must refuse to flash.

### FR-004 — Destructive flash has no mandatory readback verification

A successful write syscall/pipeline is currently treated as a successful boot flash.

**Gate:** block-device flash must hash the exact bytes being written, write and sync them, read back the same byte range, and compare the digest. Targets for which reliable readback is unavailable require a separately validated device-specific strategy and are excluded from the general release baseline.

## P1 blockers

### FR-005 — Root shell `eval` remains in `getvar()`

The fallback `eval "$VARNAME=\$VALUE"` still evaluates attacker-controlled VALUE content under Android `/system/bin/sh`. Allow-listing only VARNAME does not make VALUE safe.

**Gate:** replace with explicit case assignments; no `eval` in root-owned config parsing.

### FR-006 — Boot partition discovery can guess the wrong target

When the active slot is unresolved, the current fallback searches `boot_a` / `boot_b` and can also fall back to `vendor_boot` / `init_boot` as though they were interchangeable with boot.

**Gate:** A/B devices require a resolved active slot. `vendor_boot` / `init_boot` require explicit separate support; they are never generic boot fallbacks.

### FR-007 — Backup identity/hash logic does not cover normal block-device targets

Several checks use `[ -f "$BOOT_FILE" ]`, while a real boot target is normally a block device. `original_sha256` can therefore remain null and external-change detection becomes ineffective.

**Gate:** capture/hash the actual boot bytes used to create the backup, independent of whether the source path is a regular file or block device.

### FR-008 — Backup names can collide within one minute

Backup names currently have minute precision and can overwrite a previous good backup.

**Gate:** no-clobber unique name (seconds + PID/random or `mktemp`) followed by atomic manifest/image promotion.

### FR-009 — Embedded-KPM validation can fail open

If `kptools -l -M` cannot verify an embedded KPM, patching currently proceeds with a warning.

**Gate:** release path fails closed. Any development override must be explicit, off by default, and visibly mark the output non-release.

### FR-010 — KPM load argument contract was wrong

Module scripts called `kpatch kpm load PATH -- ARGS`, while the current C CLI accepts `PATH [ARGS]`; literal `--` became the KPM argument and the intended string was ignored.

**Status:** fixed on this review branch in `service.sh` and `install_kpm.sh`. Rust parser foundation supports both call shapes for migration compatibility.

### FR-011 — Lifecycle event dispatch is not implemented by the packaged CLI

`service.sh` called `kpatch event ...` even though the KPatch-Next-derived PatchNest CLI has no `event` command. Failures were hidden.

**Status:** review branch now records the capability as unavailable instead of silently claiming dispatch success. Final behavior depends on FR-001 ABI unification.

### FR-012 — `kpatch hello` previously returned process success on handshake failure

The C CLI printed the expected echo only on a matching magic but `main()` always returned 0.

**Status:** fixed on `PatchNest/fix/cli-contract-hardening`; syscall failure and foreign hello magic now produce a stable non-zero exit code.

## Release-only blockers

### FR-013 — Package output is not proven byte-reproducible

The same source tree produced a successful Actions module ZIP whose SHA-256 differed from the existing `v0.4.1-rc2` release asset. Normal `zip -r` metadata/timestamps are a likely cause.

**Gate:** deterministic file order/timestamps/ZIP metadata and two-build byte comparison before publishing a hash-pinned update.

### FR-014 — Physical device lifecycle evidence is still missing

Required before declaring fully flash-ready:

1. read-only preflight and target-slot identity;
2. backup capture + manifest binding;
3. patch without flash and image inspection;
4. flash + exact readback verification;
5. cold boot / warm reboot;
6. KPM load/control/unload/reload;
7. exclusion + rehook behavior;
8. root-manager coexistence for each supported manager;
9. rollback to the bound backup;
10. deliberate failed-boot recovery test;
11. second reboot after rollback;
12. evidence bundle bound to component SHAs and flashed image hashes.

## Branch policy

`module/FLASH_REVIEW_BLOCKED` intentionally prevents installation of this branch until all P0 blockers are closed. Removing that marker requires a dedicated final review commit with evidence links; it must not be deleted as part of an unrelated change.
