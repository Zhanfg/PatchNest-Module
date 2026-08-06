#!/system/bin/sh
# PatchNest module uninstall cleanup.
#
# Removing the user-space module does not prove that the boot image has been
# unpatched. Never delete verified boot backups or pretend an automatic restore
# happened. Users must run the normal verified unpatch flow before uninstalling
# when they want the kernel patch removed.

set -u
umask 077

STATE_DIR=/data/adb/patchnest
SERVICE_SCRIPT=/data/adb/service.d/patchnest.sh

rm -f "$SERVICE_SCRIPT"

if [ -d "$STATE_DIR" ]; then
    # Remove transient runtime/request files only. Preserve backup images,
    # manifests, repository policy, package policy and user-installed KPM data.
    rm -f \
      "$STATE_DIR/boot_count" \
      "$STATE_DIR/autorecovery_active" \
      "$STATE_DIR/auto_unpatch_requested" \
      "$STATE_DIR/recovery_state.json" \
      "$STATE_DIR/process_state.json" \
      "$STATE_DIR/process_monitor_state" \
      "$STATE_DIR/startup_error" \
      "$STATE_DIR/.running"

    _timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    _notice_tmp="$STATE_DIR/UNINSTALL_NOTICE.txt.tmp.$$"
    cat >"$_notice_tmp" <<EOF
PatchNest user-space module removed at $_timestamp.

Verified boot backups and persistent user configuration were intentionally
retained. Module removal did not flash or unpatch the boot image. Reinstall the
same or a compatible PatchNest version to use the verified recovery/unpatch
flow, or follow the documented manual rollback procedure.
EOF
    mv "$_notice_tmp" "$STATE_DIR/UNINSTALL_NOTICE.txt" 2>/dev/null || true
    chmod 0600 "$STATE_DIR/UNINSTALL_NOTICE.txt" 2>/dev/null || true
fi

exit 0
