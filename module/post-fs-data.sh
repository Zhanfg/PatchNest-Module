#!/system/bin/sh
# PatchNest early-boot state and KPM admission preparation.
#
# This script never flashes or restores a boot image. Before service.sh runs,
# it narrows the live KPM directory to explicitly autoload-enabled `.kpm`
# files and guarantees one unambiguous signature-policy value.

set -eu
umask 077

MODDIR=${0%/*}
SERVICE_D=/data/adb/service.d
STATUS_SH="$SERVICE_D/patchnest.sh"
PNDIR=/data/adb/patchnest
CONFIG_FILE="$PNDIR/config"
BOOT_COUNT_FILE="$PNDIR/boot_count"
RECOVERY_MARKER="$PNDIR/autorecovery_active"
RECOVERY_REQUEST="$PNDIR/auto_unpatch_requested"
RECOVERY_STATE="$PNDIR/recovery_state.json"
KPM_DIR="$PNDIR/kpm"
KPM_EVENT_DIR="$PNDIR/kpm_events"
KPM_QUARANTINE_DIR="$PNDIR/kpm_quarantine"
KPM_FAILED_DIR="$PNDIR/kpm_failed"
KPM_ADMISSION_LOG="$PNDIR/kpm_admission.log"
THRESHOLD=3
POLICY_READY=true

. "$MODDIR/patch/recovery_state.sh"

mkdir -p "$SERVICE_D" "$PNDIR" "$KPM_DIR" "$KPM_EVENT_DIR" "$KPM_QUARANTINE_DIR" "$KPM_FAILED_DIR"
chmod 0700 "$PNDIR" "$KPM_DIR" "$KPM_EVENT_DIR" "$KPM_QUARANTINE_DIR" "$KPM_FAILED_DIR" 2>/dev/null || true
if cp "$MODDIR/status.sh" "$STATUS_SH"; then
  chmod 0755 "$STATUS_SH"
fi

admission_log() {
  printf '[%s] %s\n' "$(date)" "$*" >>"$KPM_ADMISSION_LOG" 2>/dev/null || true
}

normalize_signature_policy() {
  _policy=""
  _policy_count=0
  if [ -f "$CONFIG_FILE" ]; then
    _policy_count=$(grep -c '^KPM_SIGNATURE_POLICY=' "$CONFIG_FILE" 2>/dev/null || true)
    _policy=$(sed -n 's/^KPM_SIGNATURE_POLICY=//p' "$CONFIG_FILE" 2>/dev/null | head -n 1 | tr -d ' \t\r\n')
  fi
  if [ "$_policy_count" = "1" ]; then
    case "$_policy" in
      off|warn|strict)
        admission_log "signature policy preserved: $_policy"
        return 0
        ;;
    esac
  fi

  _config_tmp="${CONFIG_FILE}.tmp.$$"
  if [ -f "$CONFIG_FILE" ]; then
    awk 'index($0, "KPM_SIGNATURE_POLICY=") != 1 { print }' "$CONFIG_FILE" >"$_config_tmp" \
      || { rm -f "$_config_tmp"; return 1; }
  else
    : >"$_config_tmp" || return 1
  fi
  printf '%s\n' 'KPM_SIGNATURE_POLICY=strict' >>"$_config_tmp" \
    || { rm -f "$_config_tmp"; return 1; }
  chmod 0600 "$_config_tmp" 2>/dev/null || true
  mv "$_config_tmp" "$CONFIG_FILE" || { rm -f "$_config_tmp"; return 1; }
  admission_log "missing, duplicate, or invalid signature policy replaced with strict"
  return 0
}

safe_module_id() {
  _candidate=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9_.-')
  [ -n "$_candidate" ] || _candidate=unknown
  printf '%.64s' "$_candidate"
}

# Move one primary object and all of its sidecars into a single transaction
# directory. The manifest and checksums are finalized before state=complete;
# management tools ignore interrupted entries.
move_with_sidecars() {
  _source=$1
  _destination_root=$2
  _reason=$3
  _base=$(basename "$_source")
  _stem=${_base%.*}
  _module_id=$(safe_module_id "$_stem")
  _epoch=$(date +%s 2>/dev/null || printf '0')
  _entry_id="${_module_id}-${_epoch}-$$"
  _entry="$_destination_root/$_entry_id"

  case "$_base" in
    *.kpm) _primary_name=module.kpm; _safe_source="${_module_id}.kpm" ;;
    *.ko) _primary_name=module.ko; _safe_source="${_module_id}.ko" ;;
    *.o) _primary_name=module.o; _safe_source="${_module_id}.o" ;;
    *) return 1 ;;
  esac

  mkdir -p "$_destination_root" || return 1
  [ ! -e "$_entry" ] || return 1
  mkdir "$_entry" || return 1
  chmod 0700 "$_entry" 2>/dev/null || true
  printf '%s\n' 'state=staging' >"$_entry/state" || { rmdir "$_entry" 2>/dev/null || true; return 1; }

  if ! mv "$_source" "$_entry/$_primary_name"; then
    rm -rf "$_entry"
    return 1
  fi

  if [ -e "$KPM_DIR/${_stem}.kpm.sig" ]; then
    mv "$KPM_DIR/${_stem}.kpm.sig" "$_entry/module.kpm.sig" \
      || admission_log "could not move signature sidecar for $_base"
  fi
  if [ -e "$KPM_EVENT_DIR/${_stem}.events" ]; then
    mv "$KPM_EVENT_DIR/${_stem}.events" "$_entry/events" \
      || admission_log "could not move event sidecar for $_base"
  fi
  if [ -e "$KPM_EVENT_DIR/${_stem}.args" ]; then
    mv "$KPM_EVENT_DIR/${_stem}.args" "$_entry/args" \
      || admission_log "could not move argument sidecar for $_base"
  fi
  if [ -e "$KPM_EVENT_DIR/${_stem}.autoload" ]; then
    mv "$KPM_EVENT_DIR/${_stem}.autoload" "$_entry/autoload" \
      || admission_log "could not move autoload sidecar for $_base"
  fi

  _created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  _manifest_tmp="$_entry/manifest.properties.tmp"
  cat >"$_manifest_tmp" <<EOF
schema_version=1
state=complete
entry_id=$_entry_id
module_id=$_module_id
reason=$_reason
created_at=$_created_at
primary=$_primary_name
source_basename=$_safe_source
EOF
  chmod 0600 "$_manifest_tmp" 2>/dev/null || true
  mv "$_manifest_tmp" "$_entry/manifest.properties" || {
    admission_log "quarantine manifest finalization failed for $_entry_id"
    return 1
  }

  _checksums_tmp="$_entry/checksums.sha256.tmp"
  if ! (
    cd "$_entry" || exit 1
    for _tracked in manifest.properties module.kpm module.ko module.o module.kpm.sig events args autoload; do
      [ -f "$_tracked" ] || continue
      sha256sum "$_tracked" || exit 1
    done >"checksums.sha256.tmp"
  ); then
    admission_log "quarantine checksum generation failed for $_entry_id"
    return 1
  fi
  chmod 0600 "$_checksums_tmp" 2>/dev/null || true
  mv "$_checksums_tmp" "$_entry/checksums.sha256" || {
    admission_log "quarantine checksum finalization failed for $_entry_id"
    return 1
  }

  printf '%s\n' 'state=complete' >"$_entry/state"
  admission_log "stored transaction entry=$_entry_id module=$_module_id reason=$_reason"
  return 0
}

if ! normalize_signature_policy; then
  POLICY_READY=false
  admission_log "ERROR: signature policy could not be repaired; all KPMs will be quarantined"
fi

# service.sh historically scans every .kpm/.ko/.o in KPM_DIR. Enforce the
# intended admission decision before that broad loop executes.
for _object in "$KPM_DIR"/*.ko "$KPM_DIR"/*.o; do
  [ -e "$_object" ] || continue
  admission_log "rejected non-KPM object: $(basename "$_object")"
  move_with_sidecars "$_object" "$KPM_FAILED_DIR" non-kpm-object \
    || admission_log "failed to store rejected object transaction: $_object"
done

for _kpm in "$KPM_DIR"/*.kpm; do
  [ -e "$_kpm" ] || continue
  _name=$(basename "$_kpm" .kpm)
  if [ "$POLICY_READY" != "true" ]; then
    admission_log "quarantined KPM because signature policy is unavailable: ${_name}.kpm"
    move_with_sidecars "$_kpm" "$KPM_QUARANTINE_DIR" signature-policy-unavailable \
      || admission_log "failed to quarantine: $_kpm"
  elif [ ! -f "$KPM_EVENT_DIR/${_name}.autoload" ]; then
    admission_log "quarantined non-autoload KPM: ${_name}.kpm"
    move_with_sidecars "$_kpm" "$KPM_QUARANTINE_DIR" autoload-disabled \
      || admission_log "failed to quarantine: $_kpm"
  fi
done

# A successful current-image unpatch or verified-backup restore leaves the
# module installed while the kernel is intentionally no longer PatchNest-
# patched. Keep admission housekeeping active, but do not treat those boots as
# failed patch boots. A healthy kpatch handshake later clears this suspension.
if [ -e "$PATCHNEST_SUSPEND_FILE" ]; then
  if patchnest_recovery_monitoring_suspended; then
    printf '%s\n' 0 >"$BOOT_COUNT_FILE" 2>/dev/null || true
    rm -f "$RECOVERY_MARKER" "$RECOVERY_REQUEST" 2>/dev/null || true
    admission_log "recovery monitoring remains suspended after intentional unpatch/restore"
    exit 0
  fi
  admission_log "invalid recovery suspension state removed; normal monitoring resumed"
  rm -f "$PATCHNEST_SUSPEND_FILE" 2>/dev/null || true
fi

current_count=0
if [ -f "$BOOT_COUNT_FILE" ]; then
  current_count=$(printf '%s' "$(cat "$BOOT_COUNT_FILE" 2>/dev/null || true)" | tr -cd '0-9' | head -c 6)
  [ -n "$current_count" ] || current_count=0
fi
case "$current_count" in *[!0-9]*|'') current_count=0 ;; esac
if [ "$current_count" -lt "$THRESHOLD" ]; then current_count=$((current_count + 1)); fi
printf '%s\n' "$current_count" >"$BOOT_COUNT_FILE"

requested=false
if [ "$current_count" -ge "$THRESHOLD" ]; then
  requested=true
  : >"$RECOVERY_MARKER"
  : >"$RECOVERY_REQUEST"
else
  rm -f "$RECOVERY_MARKER" "$RECOVERY_REQUEST"
fi

requested_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
state_tmp="${RECOVERY_STATE}.tmp.$$"
cat >"$state_tmp" <<EOF
{
  "schema_version": 1,
  "boot_count": $current_count,
  "threshold": $THRESHOLD,
  "recovery_requested": $requested,
  "requested_at": "$requested_at",
  "automatic_flash_performed": false,
  "monitoring_suspended": false,
  "required_next_step": "select_target_bound_verified_backup"
}
EOF
mv "$state_tmp" "$RECOVERY_STATE"

exit 0
