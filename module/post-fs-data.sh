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
. "$MODDIR/kpm_transaction_store.sh"

mkdir -p "$SERVICE_D" "$PNDIR" "$KPM_DIR" "$KPM_EVENT_DIR" "$KPM_QUARANTINE_DIR" "$KPM_FAILED_DIR"
chmod 0700 "$PNDIR" "$KPM_DIR" "$KPM_EVENT_DIR" "$KPM_QUARANTINE_DIR" "$KPM_FAILED_DIR" 2>/dev/null || true
if cp "$MODDIR/status.sh" "$STATUS_SH"; then
  chmod 0755 "$STATUS_SH"
else
  printf '[%s] ERROR: could not install status helper\n' "$(date)" >>"$KPM_ADMISSION_LOG" 2>/dev/null || true
fi

admission_log() {
  printf '[%s] %s\n' "$(date)" "$*" >>"$KPM_ADMISSION_LOG" 2>/dev/null || true
}

normalize_signature_policy() {
  _policy=""
  _policy_count=0
  if [ -L "$CONFIG_FILE" ]; then
    admission_log "signature policy symlink removed"
    rm -f "$CONFIG_FILE" || return 1
  elif [ -f "$CONFIG_FILE" ]; then
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

store_admission_transaction() {
  _source=$1
  _destination=$2
  _reason=$3
  _entry=$(patchnest_store_kpm_transaction "$_source" "$_destination" "$_reason" 2>/dev/null) || {
    admission_log "ERROR: could not store transaction source=$_source reason=$_reason"
    return 1
  }
  admission_log "stored admission transaction entry=$_entry reason=$_reason"
  return 0
}

if ! normalize_signature_policy; then
  POLICY_READY=false
  admission_log "ERROR: signature policy could not be repaired; all KPMs will be quarantined"
fi

# Reject Linux objects before the late service can attempt to parse them.
for _object in "$KPM_DIR"/*.ko "$KPM_DIR"/*.o; do
  [ -e "$_object" ] || continue
  if [ ! -f "$_object" ] || [ -L "$_object" ]; then
    admission_log "ERROR: unsafe non-KPM object left untouched: $_object"
    continue
  fi
  admission_log "rejected non-KPM object: $(basename "$_object")"
  store_admission_transaction "$_object" "$KPM_FAILED_DIR" non-kpm-object || true
done

# Only a regular, non-symlink autoload marker allows a KPM to remain live.
for _kpm in "$KPM_DIR"/*.kpm; do
  [ -e "$_kpm" ] || continue
  if [ ! -f "$_kpm" ] || [ -L "$_kpm" ] || [ ! -s "$_kpm" ]; then
    admission_log "ERROR: unsafe or empty KPM left untouched: $_kpm"
    continue
  fi
  _name=$(basename "$_kpm" .kpm)
  case "$_name" in
    ''|.|..|*[!A-Za-z0-9_.-]*)
      admission_log "ERROR: unsafe KPM basename left untouched: $_name"
      continue
      ;;
  esac

  if [ "$POLICY_READY" != "true" ]; then
    admission_log "quarantined KPM because signature policy is unavailable: ${_name}.kpm"
    store_admission_transaction "$_kpm" "$KPM_QUARANTINE_DIR" signature-policy-unavailable || true
  elif [ ! -f "$KPM_EVENT_DIR/${_name}.autoload" ] \
      || [ -L "$KPM_EVENT_DIR/${_name}.autoload" ]; then
    admission_log "quarantined non-autoload KPM: ${_name}.kpm"
    store_admission_transaction "$_kpm" "$KPM_QUARANTINE_DIR" autoload-disabled || true
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
if [ -f "$BOOT_COUNT_FILE" ] && [ ! -L "$BOOT_COUNT_FILE" ]; then
  current_count=$(printf '%s' "$(cat "$BOOT_COUNT_FILE" 2>/dev/null || true)" | tr -cd '0-9' | head -c 6)
  [ -n "$current_count" ] || current_count=0
fi
case "$current_count" in *[!0-9]*|'') current_count=0 ;; esac
if [ "$current_count" -lt "$THRESHOLD" ]; then current_count=$((current_count + 1)); fi
printf '%s\n' "$current_count" >"$BOOT_COUNT_FILE"
chmod 0600 "$BOOT_COUNT_FILE" 2>/dev/null || true

requested=false
if [ "$current_count" -ge "$THRESHOLD" ]; then
  requested=true
  : >"$RECOVERY_MARKER"
  : >"$RECOVERY_REQUEST"
  chmod 0600 "$RECOVERY_MARKER" "$RECOVERY_REQUEST" 2>/dev/null || true
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
chmod 0600 "$state_tmp" 2>/dev/null || true
mv "$state_tmp" "$RECOVERY_STATE"

exit 0
