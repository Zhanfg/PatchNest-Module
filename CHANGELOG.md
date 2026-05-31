# KPatch Next Module

## Changelog

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

