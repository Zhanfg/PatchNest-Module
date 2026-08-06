#!/system/bin/sh
# PatchNest early-boot state and KPM admission preparation.
#
# This script never flashes or restores a boot image. Before service.sh runs,
# it ensures only explicitly autoload-enabled `.kpm` files remain in the live
# KPM directory. Disabled/unsigned-review modules are preserved in quarantine;
# Linux `.ko/.o` objects are preserved under failed/ for manual inspection.

set -eu
umask 077

MODDIR=${0%/*}
SERVICE_D=/data/adb/service.d
STATUS_SH="$SERVICE_D/patchnest.sh"
PNDIR=/data/adb/patchnest
BOOT_COUNT_FILE="$PNDIR/boot_count"
RECOVERY_MARKER="$PNDIR/autorecovery_active"
RECOVERY_REQUEST="$PNDIR/auto_unpatch_requested"
RECOVERY_STATE="$PNDIR/recovery_state.json"
KPM_DIR="$PNDIR/kpm"
KPM_EVENT_DIR="$PNDIR/kpm_events"
KPM_QUARANTINE_DIR="$PNDIR/kpm_quarantine"
KPM_FAILED_DIR="$KPM_DIR/failed"
KPM_ADMISSION_LOG="$PNDIR/kpm_admission.log"
THRESHOLD=3

mkdir -p "$SERVICE_D" "$PNDIR" "$KPM_DIR" "$KPM_EVENT_DIR" "$KPM_QUARANTINE_DIR" "$KPM_FAILED_DIR"
chmod 0700 "$PNDIR" "$KPM_DIR" "$KPM_EVENT_DIR" "$KPM_QUARANTINE_DIR" "$KPM_FAILED_DIR" 2>/dev/null || true
if cp "$MODDIR/status.sh" "$STATUS_SH"; then
  chmod 0755 "$STATUS_SH"
fi

admission_log() {
  printf '[%s] %s\n' "$(date)" "$*" >>"$KPM_ADMISSION_LOG" 2>/dev/null || true
}

move_with_sidecars() {
  _source=$1
  _destination_dir=$2
  _base=$(basename "$_source")
  _stem=${_base%.*}
  _destination="$_destination_dir/$_base"
  _suffix=$(date +%s 2>/dev/null || printf '0')
  if [ -e "$_destination" ]; then
    _destination="$_destination_dir/${_base}.${_suffix}.$$"
  fi
  mv "$_source" "$_destination" 2>/dev/null || return 1

  for _sidecar in \
    "$KPM_DIR/${_stem}.kpm.sig" \
    "$KPM_EVENT_DIR/${_stem}.events" \
    "$KPM_EVENT_DIR/${_stem}.args" \
    "$KPM_EVENT_DIR/${_stem}.autoload"; do
    [ -e "$_sidecar" ] || continue
    _sidecar_base=$(basename "$_sidecar")
    mv "$_sidecar" "$_destination_dir/${_sidecar_base}.${_suffix}.$$" 2>/dev/null || true
  done
  return 0
}

# service.sh historically scans every .kpm/.ko/.o in KPM_DIR. Enforce the
# intended admission decision before that broad loop executes.
for _object in "$KPM_DIR"/*.ko "$KPM_DIR"/*.o; do
  [ -e "$_object" ] || continue
  admission_log "rejected non-KPM object: $(basename "$_object")"
  move_with_sidecars "$_object" "$KPM_FAILED_DIR" || admission_log "failed to move rejected object: $_object"
done

for _kpm in "$KPM_DIR"/*.kpm; do
  [ -e "$_kpm" ] || continue
  _name=$(basename "$_kpm" .kpm)
  if [ ! -f "$KPM_EVENT_DIR/${_name}.autoload" ]; then
    admission_log "quarantined non-autoload KPM: ${_name}.kpm"
    move_with_sidecars "$_kpm" "$KPM_QUARANTINE_DIR" || admission_log "failed to quarantine: $_kpm"
  fi
done

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
  "required_next_step": "select_target_bound_verified_backup"
}
EOF
mv "$state_tmp" "$RECOVERY_STATE"

exit 0
