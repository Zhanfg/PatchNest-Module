#!/system/bin/sh
# Durable KPM install journal and stale-lock recovery helpers.
# This file is sourced by install_kpm.sh.

PATCHNEST_STATE_DIR=${PATCHNEST_STATE_DIR:-/data/adb/patchnest}
PATCHNEST_KPM_DIR=${PATCHNEST_KPM_DIR:-$PATCHNEST_STATE_DIR/kpm}
PATCHNEST_KPM_ZIP_DIR=${PATCHNEST_KPM_ZIP_DIR:-$PATCHNEST_STATE_DIR/kpm_zips}
PATCHNEST_EVENT_DIR=${PATCHNEST_EVENT_DIR:-$PATCHNEST_STATE_DIR/kpm_events}
PATCHNEST_INSTALL_LOCK="$PATCHNEST_STATE_DIR/.kpm-install.lock"
PATCHNEST_INSTALL_LOG=${PATCHNEST_INSTALL_LOG:-$PATCHNEST_STATE_DIR/service.log}

patchnest_install_log() {
  printf '[%s] install-recovery: %s\n' "$(date)" "$*" >>"$PATCHNEST_INSTALL_LOG" 2>/dev/null || true
}

patchnest_valid_module_id() {
  _pir_id=$1
  [ -n "$_pir_id" ] && [ "${#_pir_id}" -le 64 ] || return 1
  case "$_pir_id" in .|..|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  return 0
}

patchnest_valid_journal_state() {
  case "$1" in preparing|backup|writing|complete) return 0 ;; *) return 1 ;; esac
}

patchnest_write_install_journal() {
  _pir_stage=$1
  _pir_state=$2
  _pir_module_id=$3
  patchnest_valid_journal_state "$_pir_state" || return 1
  patchnest_valid_module_id "$_pir_module_id" || return 1
  [ -d "$_pir_stage" ] && [ ! -L "$_pir_stage" ] || return 1
  case "$_pir_stage" in "$PATCHNEST_STATE_DIR"/.kpm-stage.*) ;; *) return 1 ;; esac

  _pir_tmp="$_pir_stage/journal.properties.tmp.$$"
  cat >"$_pir_tmp" <<EOF
schema_version=1
state=$_pir_state
module_id=$_pir_module_id
updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
EOF
  chmod 0600 "$_pir_tmp" 2>/dev/null || true
  mv "$_pir_tmp" "$_pir_stage/journal.properties"
}

patchnest_read_journal_field() {
  _pir_journal=$1
  _pir_key=$2
  _pir_count=$(grep -c "^${_pir_key}=" "$_pir_journal" 2>/dev/null || true)
  [ "$_pir_count" = "1" ] || return 1
  sed -n "s/^${_pir_key}=//p" "$_pir_journal" | head -n 1
}

patchnest_remove_destinations() {
  _pir_id=$1
  rm -f \
    "$PATCHNEST_KPM_DIR/${_pir_id}.kpm" \
    "$PATCHNEST_KPM_DIR/${_pir_id}.kpm.sig" \
    "$PATCHNEST_KPM_ZIP_DIR/${_pir_id}.zip" \
    "$PATCHNEST_KPM_ZIP_DIR/${_pir_id}.zip.sha256" \
    "$PATCHNEST_KPM_ZIP_DIR/${_pir_id}.prop" \
    "$PATCHNEST_EVENT_DIR/${_pir_id}.events" \
    "$PATCHNEST_EVENT_DIR/${_pir_id}.args" \
    "$PATCHNEST_EVENT_DIR/${_pir_id}.autoload" \
    2>/dev/null || true
}

patchnest_restore_previous_item() {
  _pir_previous=$1
  _pir_destination=$2
  [ -e "$_pir_previous" ] || return 0
  [ -f "$_pir_previous" ] && [ ! -L "$_pir_previous" ] || return 1
  rm -f "$_pir_destination" 2>/dev/null || true
  mv "$_pir_previous" "$_pir_destination"
}

patchnest_restore_previous_set() {
  _pir_stage=$1
  _pir_id=$2
  _pir_previous="$_pir_stage/previous"
  [ -d "$_pir_previous" ] && [ ! -L "$_pir_previous" ] || return 1

  _pir_failed=false
  patchnest_restore_previous_item "$_pir_previous/kpm" "$PATCHNEST_KPM_DIR/${_pir_id}.kpm" || _pir_failed=true
  patchnest_restore_previous_item "$_pir_previous/sig" "$PATCHNEST_KPM_DIR/${_pir_id}.kpm.sig" || _pir_failed=true
  patchnest_restore_previous_item "$_pir_previous/zip" "$PATCHNEST_KPM_ZIP_DIR/${_pir_id}.zip" || _pir_failed=true
  patchnest_restore_previous_item "$_pir_previous/zip-digest" "$PATCHNEST_KPM_ZIP_DIR/${_pir_id}.zip.sha256" || _pir_failed=true
  patchnest_restore_previous_item "$_pir_previous/prop" "$PATCHNEST_KPM_ZIP_DIR/${_pir_id}.prop" || _pir_failed=true
  patchnest_restore_previous_item "$_pir_previous/events" "$PATCHNEST_EVENT_DIR/${_pir_id}.events" || _pir_failed=true
  patchnest_restore_previous_item "$_pir_previous/args" "$PATCHNEST_EVENT_DIR/${_pir_id}.args" || _pir_failed=true
  patchnest_restore_previous_item "$_pir_previous/autoload" "$PATCHNEST_EVENT_DIR/${_pir_id}.autoload" || _pir_failed=true
  [ "$_pir_failed" = "false" ]
}

# Recover one journaled staging directory. `writing` means new destination
# files may exist and are removed before the old set is restored. `backup`
# means only some old files may have moved, so only matching previous files are
# restored. `complete` means the new set was committed and staging is stale.
patchnest_recover_install_stage() {
  _pir_stage=$1
  [ -d "$_pir_stage" ] && [ ! -L "$_pir_stage" ] || return 1
  case "$_pir_stage" in "$PATCHNEST_STATE_DIR"/.kpm-stage.*) ;; *) return 1 ;; esac
  _pir_journal="$_pir_stage/journal.properties"
  [ -f "$_pir_journal" ] && [ ! -L "$_pir_journal" ] || return 1
  _pir_size=$(wc -c <"$_pir_journal" 2>/dev/null || true)
  case "$_pir_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_pir_size" -le 1024 ] || return 1

  _pir_state=$(patchnest_read_journal_field "$_pir_journal" state) || return 1
  _pir_id=$(patchnest_read_journal_field "$_pir_journal" module_id) || return 1
  patchnest_valid_journal_state "$_pir_state" || return 1
  patchnest_valid_module_id "$_pir_id" || return 1

  case "$_pir_state" in
    preparing)
      rm -rf "$_pir_stage" || return 1
      patchnest_install_log "removed abandoned preparing stage for $_pir_id"
      ;;
    backup)
      patchnest_restore_previous_set "$_pir_stage" "$_pir_id" || return 1
      rm -rf "$_pir_stage" || return 1
      patchnest_install_log "restored partial backup stage for $_pir_id"
      ;;
    writing)
      patchnest_remove_destinations "$_pir_id"
      patchnest_restore_previous_set "$_pir_stage" "$_pir_id" || return 1
      rm -rf "$_pir_stage" || return 1
      patchnest_install_log "rolled back interrupted write stage for $_pir_id"
      ;;
    complete)
      rm -rf "$_pir_stage" || return 1
      patchnest_install_log "removed committed stale stage for $_pir_id"
      ;;
  esac
  return 0
}

patchnest_install_lock_active() {
  [ -d "$PATCHNEST_INSTALL_LOCK" ] && [ ! -L "$PATCHNEST_INSTALL_LOCK" ] || return 1
  _pir_pid=$(cat "$PATCHNEST_INSTALL_LOCK/pid" 2>/dev/null || true)
  case "$_pir_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "/proc/$_pir_pid" ] || return 1
  _pir_cmd=$(tr '\000' ' ' <"/proc/$_pir_pid/cmdline" 2>/dev/null || true)
  case "$_pir_cmd" in *install_kpm.sh*) return 0 ;; *) return 1 ;; esac
}

patchnest_recover_abandoned_installs() {
  mkdir -p "$PATCHNEST_STATE_DIR" || return 1
  for _pir_stage in "$PATCHNEST_STATE_DIR"/.kpm-stage.*; do
    [ -e "$_pir_stage" ] || continue
    patchnest_recover_install_stage "$_pir_stage" || {
      patchnest_install_log "ERROR: could not recover stale stage $_pir_stage"
      return 1
    }
  done
  return 0
}

patchnest_acquire_install_lock() {
  mkdir -p "$PATCHNEST_STATE_DIR" || return 1
  if [ -e "$PATCHNEST_INSTALL_LOCK" ]; then
    if patchnest_install_lock_active; then
      return 2
    fi
    [ -d "$PATCHNEST_INSTALL_LOCK" ] && [ ! -L "$PATCHNEST_INSTALL_LOCK" ] || return 1
    patchnest_recover_abandoned_installs || return 1
    rm -rf "$PATCHNEST_INSTALL_LOCK" || return 1
  else
    patchnest_recover_abandoned_installs || return 1
  fi

  mkdir "$PATCHNEST_INSTALL_LOCK" || return 2
  chmod 0700 "$PATCHNEST_INSTALL_LOCK" 2>/dev/null || true
  printf '%s\n' "$$" >"$PATCHNEST_INSTALL_LOCK/pid" || {
    rm -rf "$PATCHNEST_INSTALL_LOCK"
    return 1
  }
  chmod 0600 "$PATCHNEST_INSTALL_LOCK/pid" 2>/dev/null || true
  return 0
}

patchnest_release_install_lock() {
  [ -d "$PATCHNEST_INSTALL_LOCK" ] && [ ! -L "$PATCHNEST_INSTALL_LOCK" ] || return 0
  _pir_pid=$(cat "$PATCHNEST_INSTALL_LOCK/pid" 2>/dev/null || true)
  [ "$_pir_pid" = "$$" ] || return 1
  rm -rf "$PATCHNEST_INSTALL_LOCK"
}
