#!/system/bin/sh
# PatchNest uninstall safety policy.
#
# Removing a root-manager module does not restore the boot partition. Therefore
# deleting /data/adb/patchnest here could destroy the exact rollback backup,
# Public1158 superkey, transaction binding and recovery evidence while the
# device is still booting a PatchNest-patched kernel. Preserve that state so a
# reinstall can still authenticate and perform the reviewed bound restore.
# State may be explicitly removed only after the original boot has been
# transaction-bound restored and independently verified.

rm -f /data/adb/service.d/patchnest.sh 2>/dev/null || true

if [ -d /data/adb/patchnest ]; then
    printf '%s\n' 'module_removed_state_preserved=1' > /data/adb/patchnest/module_removed_state_preserved 2>/dev/null || true
    chmod 0600 /data/adb/patchnest/module_removed_state_preserved 2>/dev/null || true
fi

exit 0
