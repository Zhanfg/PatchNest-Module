# KPatch Next Module

## Changelog

### v0.1.1

**Embedded KPM Crash Protection (KernelPatch fork):**
- boot_patch.sh: pre-embed validation (ELF magic, aarch64 arch, kptools verify)
  Refuses to patch if any embedded KPM fails validation
- Early boot counter: /dev/.kp_bootcount (tmpfs, works before /data mount)
  Embedded KPM crash → reboot → count++ → 3 reboots → safe mode

### v0.1.0

**KPM Crash Protection System (KernelPatch fork):**
- Boot counter: auto safe mode after 3 failed boots
- Pre-load ELF validation (magic, class, arch, type)
- Faulty KPM blacklist (auto + explicit via supercall)
- Supercalls: SAFETY_BL_CLEAR (0x1181), SAFETY_BL_ADD (0x1182)
- All state persisted via /data/adb/kp-next/ files

### v0.0.9

**Kernel Version Compatibility Fix (KernelPatch fork):**
- SELinux context hiding: replaced security_getprocattr hook (changed at 4.11)
  with proc_pid_attr_read hook (stable 3.18 - 6.12+)
- Post-processing approach: reads output buffer, replaces root context strings
- All hooks now kernel-version-agnostic

**Compatibility matrix (3.18 - 6.12+):**
- sel_read_enforce: stable ✅
- proc_pid_attr_read: stable ✅
- ksys_umount: 4.17+ (do_umount fallback for older)
- cred_offset/task_struct_offset: runtime detected ✅

### v0.0.8

**KPM User Experience Parity with APM:**

Phase 1 — ZIP Packaging + One-Click Install:
- KPM ZIP format: module.prop + .kpm/.ko/.o/.c in a zip
- install_kpm.sh: validate, extract, install, auto-load
- WebUI: FAB button now accepts .kpm AND .zip files
- module.prop format (APM-compatible with KPM extensions):
  id, name, version, event=, args=, autoLoad=true

Phase 2 — Event Auto-Registration:
- service.sh reads event= from saved module.prop configs
- Dispatches POST_FS_DATA and BOOT_COMPLETED events
- Loads modules with saved args on boot

Phase 3 — Source Code Compilation:
- compile_kpm.sh: TCC/clang/gcc wrapper for on-device compilation
- Auto-generates minimal kpmodule.h if not present
- install_kpm.sh detects .c sources and compiles automatically

Phase 4 — KPM Online Repository:
- kpm_repo.js: repository browser in WebUI
- JSON format for module index (kpm_repo.json)
- Download + install from repository
- Settings → Repository to access
- Default repo URL: GitHub raw content

### v0.0.7

**Complete Root/Module Detection Hiding (KernelPatch fork):**
- SELinux context hiding: hook security_getprocattr for /proc/self/attr/current
- Process hiding: proc_hide_rename_current() + SUPERCALL_PROC_RENAME (0x1170)
- Auto-rename kpatch/kptools processes to kworker names
- All 6 hiding mechanisms now active

### v0.0.6

**.ko Format Full Compatibility (KernelPatch fork):**
- Parse .modinfo section for metadata (MODULE_LICENSE, MODULE_AUTHOR, etc.)
- Per-module allocated metadata buffer (supports multiple .ko modules)
- Fix NULL pointer crash when .kpm.info absent
- Null-safe get_module_info() for all string fields
- Safe exit callback check in unload_module()

### v0.0.5

**SELinux Status Hiding (KernelPatch fork):**
- Hook sel_read_enforce to hide policy modifications from apps
- Original enforcing state saved at boot, shown to non-privileged processes
- Root/system processes see real state
- Prevents detection of AVC denial bypasses and context changes

### v0.0.4

**Root/Module Detection Hiding (KernelPatch fork):**
- Configurable filesystem hiding: runtime add/remove umount paths via supercall
- Default hidden paths: /data/adb/modules, /data/adb/kp-next, /data/adb/kp, etc.
- MNT_DETACH lazy unmount for safe unmounting
- UID-aware: checks app profile umount_modules flag
- Supercalls: UMOUNT_ADD (0x1160), UMOUNT_REMOVE (0x1161), UMOUNT_ENABLE (0x1162), UMOUNT_LIST (0x1163)
- KPM modules can add paths via compact_find_symbol("umount_add_path")

### v0.0.3

**KPM Event System & Format Extension (KernelPatch fork):**
- Structured event system: KPM_EVENT(fn) macro for event callbacks
- Events: POST_FS_DATA, BOOT_COMPLETED, MODULE_LOADED/UNLOADED, PRE/POST_KERNEL_INIT
- Boot events auto-dispatch to all loaded KPM modules
- SUPERCALL_KPM_EVENT (0x1150) for userspace event trigger
- Compact symbol resolver (compact_find_symbol): curated KP + kernel symbols for KPM
- Super access API: runtime struct member access by name (cred, etc.)
- .o format support: auto-load without .kpm.info section
- .ko format support: accept .init.text/.exit.text, kallsyms resolution via compact
- All features from KernelPatch fork: App Profile, SELinux ops, umount, safe mode

### v0.0.2

**Improvements:**
- Updated Magiskboot dependency to v30.7
- service.sh: Added retry logic (3 attempts) for kpatch hello on boot
- service.sh: Failed KPM modules now moved to `failed/` directory instead of being deleted
- service.sh: Added service.log for boot-time diagnostics
- boot_patch.sh: Boot image backup now saved persistently to `/data/adb/kp-next/backup/`
- util_functions.sh: Added vendor_boot and init_boot partition fallback for GKI devices
- Added KernelPatch (original) as alternative binary source alongside KPatch-Next
- Binary source selection via volume keys at install time
- Binary source switching via WebUI Settings (requires reboot)

**WebUI:**
- Added Log viewer page (accessible from Settings)
- Added Backup management page (accessible from Settings)
- Added Binary Source selector in Settings
- Added i18n strings for all new features (en, zh-CN)

