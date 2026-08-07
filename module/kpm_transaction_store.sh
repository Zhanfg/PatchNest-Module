#!/system/bin/sh
# Shared transactional storage for KPM quarantine and runtime failures.
# Intended to be sourced by early-boot admission and service loading paths.

PATCHNEST_STATE_DIR=${PATCHNEST_STATE_DIR:-/data/adb/patchnest}
PATCHNEST_KPM_DIR=${PATCHNEST_KPM_DIR:-$PATCHNEST_STATE_DIR/kpm}
PATCHNEST_EVENT_DIR=${PATCHNEST_EVENT_DIR:-$PATCHNEST_STATE_DIR/kpm_events}
PATCHNEST_TRANSACTION_LOG=${PATCHNEST_TRANSACTION_LOG:-$PATCHNEST_STATE_DIR/kpm_admission.log}

patchnest_transaction_log() {
  printf '[%s] transaction-store: %s\n' "$(date)" "$*" >>"$PATCHNEST_TRANSACTION_LOG" 2>/dev/null || true
}

patchnest_safe_module_id() {
  _pt_candidate=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9_.-')
  [ -n "$_pt_candidate" ] || _pt_candidate=unknown
  printf '%.64s' "$_pt_candidate"
}

patchnest_valid_transaction_reason() {
  case "$1" in
    autoload-disabled|signature-policy-unavailable|non-kpm-object|unsigned-strict|invalid-signature|load-failed)
      return 0
      ;;
    *) return 1 ;;
  esac
}

patchnest_valid_transaction_root() {
  case "$1" in
    "$PATCHNEST_STATE_DIR/kpm_quarantine"|"$PATCHNEST_STATE_DIR/kpm_failed") return 0 ;;
    *) return 1 ;;
  esac
}

patchnest_restore_moved_sidecar() {
  _pt_stored=$1
  _pt_original=$2
  [ -e "$_pt_stored" ] || return 0
  # Never overwrite a file that appeared while the transaction was running.
  # Such a conflict may be an external recovery attempt or a concurrent writer;
  # preserve the stored original as evidence instead of destroying either copy.
  [ ! -e "$_pt_original" ] && [ ! -L "$_pt_original" ] || return 1
  mv "$_pt_stored" "$_pt_original" 2>/dev/null
}

patchnest_mark_rollback_failed() {
  _pt_entry=$1
  _pt_entry_id=$2
  _pt_module_id=$3
  _pt_reason=$4

  printf '%s\n' 'state=rollback-failed' >"$_pt_entry/state.tmp" 2>/dev/null \
    && mv "$_pt_entry/state.tmp" "$_pt_entry/state" 2>/dev/null \
    || rm -f "$_pt_entry/state.tmp" 2>/dev/null || true
  chmod 0600 "$_pt_entry/state" 2>/dev/null || true
  patchnest_transaction_log \
    "transaction rollback incomplete; preserved entry=$_pt_entry_id module=$_pt_module_id reason=$_pt_reason"
}

# patchnest_rollback_transaction <entry> <entry-id> <module-id> <reason>
#   <primary-name> <primary-original> <sig-original> <events-original>
#   <args-original> <autoload-original>
#
# Restore files only into absent destinations. A complete rollback removes the
# staging entry. Any conflict or move failure preserves the remaining payload
# under state=rollback-failed for explicit inspection and manual recovery.
patchnest_rollback_transaction() {
  _pt_entry=$1
  _pt_entry_id=$2
  _pt_module_id=$3
  _pt_reason=$4
  _pt_primary_name=$5
  _pt_primary_original=$6
  _pt_sig_original=$7
  _pt_events_original=$8
  _pt_args_original=$9
  shift 9
  _pt_autoload_original=$1

  _pt_rollback_failed=false
  patchnest_restore_moved_sidecar "$_pt_entry/module.kpm.sig" "$_pt_sig_original" \
    || _pt_rollback_failed=true
  patchnest_restore_moved_sidecar "$_pt_entry/events" "$_pt_events_original" \
    || _pt_rollback_failed=true
  patchnest_restore_moved_sidecar "$_pt_entry/args" "$_pt_args_original" \
    || _pt_rollback_failed=true
  patchnest_restore_moved_sidecar "$_pt_entry/autoload" "$_pt_autoload_original" \
    || _pt_rollback_failed=true
  patchnest_restore_moved_sidecar "$_pt_entry/$_pt_primary_name" "$_pt_primary_original" \
    || _pt_rollback_failed=true

  if [ "$_pt_rollback_failed" = "true" ]; then
    patchnest_mark_rollback_failed \
      "$_pt_entry" "$_pt_entry_id" "$_pt_module_id" "$_pt_reason"
    return 1
  fi

  rm -rf "$_pt_entry" 2>/dev/null || {
    patchnest_mark_rollback_failed \
      "$_pt_entry" "$_pt_entry_id" "$_pt_module_id" "$_pt_reason"
    return 1
  }
  patchnest_transaction_log \
    "transaction rolled back entry=$_pt_entry_id module=$_pt_module_id reason=$_pt_reason"
  return 0
}

# patchnest_store_kpm_transaction <primary> <destination-root> <reason>
#
# Moves a KPM/object and its known sidecars into a canonical transaction
# directory. On any sidecar/manifest/checksum failure, moved files are restored
# only when their original destinations remain absent. Rollback conflicts keep
# the surviving original payload in a rollback-failed transaction directory.
patchnest_store_kpm_transaction() {
  _pt_source=$1
  _pt_destination_root=$2
  _pt_reason=$3

  patchnest_valid_transaction_root "$_pt_destination_root" || return 1
  patchnest_valid_transaction_reason "$_pt_reason" || return 1
  [ -d "$PATCHNEST_STATE_DIR" ] && [ ! -L "$PATCHNEST_STATE_DIR" ] || return 1
  [ -f "$_pt_source" ] && [ ! -L "$_pt_source" ] || return 1

  _pt_base=$(basename "$_pt_source")
  _pt_stem=${_pt_base%.*}
  _pt_module_id=$(patchnest_safe_module_id "$_pt_stem")
  _pt_epoch=$(date +%s 2>/dev/null || printf '0')
  _pt_entry_id="${_pt_module_id}-${_pt_epoch}-$$"
  _pt_entry="$_pt_destination_root/$_pt_entry_id"

  case "$_pt_base" in
    *.kpm) _pt_primary_name=module.kpm; _pt_safe_source="${_pt_module_id}.kpm" ;;
    *.ko) _pt_primary_name=module.ko; _pt_safe_source="${_pt_module_id}.ko" ;;
    *.o) _pt_primary_name=module.o; _pt_safe_source="${_pt_module_id}.o" ;;
    *) return 1 ;;
  esac

  _pt_sig_source="$PATCHNEST_KPM_DIR/${_pt_stem}.kpm.sig"
  _pt_events_source="$PATCHNEST_EVENT_DIR/${_pt_stem}.events"
  _pt_args_source="$PATCHNEST_EVENT_DIR/${_pt_stem}.args"
  _pt_autoload_source="$PATCHNEST_EVENT_DIR/${_pt_stem}.autoload"

  mkdir -p "$_pt_destination_root" || return 1
  [ -d "$_pt_destination_root" ] && [ ! -L "$_pt_destination_root" ] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  [ ! -e "$_pt_entry" ] && [ ! -L "$_pt_entry" ] || return 1
  mkdir "$_pt_entry" || return 1
  chmod 0700 "$_pt_entry" 2>/dev/null || true
  printf '%s\n' 'state=staging' >"$_pt_entry/state" || {
    rmdir "$_pt_entry" 2>/dev/null || true
    return 1
  }
  chmod 0600 "$_pt_entry/state" 2>/dev/null || true

  if ! mv "$_pt_source" "$_pt_entry/$_pt_primary_name"; then
    rm -rf "$_pt_entry"
    return 1
  fi

  _pt_failed=false
  if [ -e "$_pt_sig_source" ] || [ -L "$_pt_sig_source" ]; then
    [ -f "$_pt_sig_source" ] && [ ! -L "$_pt_sig_source" ] \
      && mv "$_pt_sig_source" "$_pt_entry/module.kpm.sig" \
      || _pt_failed=true
  fi
  if [ -e "$_pt_events_source" ] || [ -L "$_pt_events_source" ]; then
    [ -f "$_pt_events_source" ] && [ ! -L "$_pt_events_source" ] \
      && mv "$_pt_events_source" "$_pt_entry/events" \
      || _pt_failed=true
  fi
  if [ -e "$_pt_args_source" ] || [ -L "$_pt_args_source" ]; then
    [ -f "$_pt_args_source" ] && [ ! -L "$_pt_args_source" ] \
      && mv "$_pt_args_source" "$_pt_entry/args" \
      || _pt_failed=true
  fi
  if [ -e "$_pt_autoload_source" ] || [ -L "$_pt_autoload_source" ]; then
    [ -f "$_pt_autoload_source" ] && [ ! -L "$_pt_autoload_source" ] \
      && mv "$_pt_autoload_source" "$_pt_entry/autoload" \
      || _pt_failed=true
  fi

  if [ "$_pt_failed" = "true" ]; then
    patchnest_rollback_transaction \
      "$_pt_entry" "$_pt_entry_id" "$_pt_module_id" "$_pt_reason" \
      "$_pt_primary_name" "$_pt_source" "$_pt_sig_source" \
      "$_pt_events_source" "$_pt_args_source" "$_pt_autoload_source" || true
    return 1
  fi

  _pt_created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  _pt_manifest_tmp="$_pt_entry/manifest.properties.tmp"
  if ! cat >"$_pt_manifest_tmp" <<EOF
schema_version=1
state=complete
entry_id=$_pt_entry_id
module_id=$_pt_module_id
reason=$_pt_reason
created_at=$_pt_created_at
primary=$_pt_primary_name
source_basename=$_pt_safe_source
EOF
  then
    _pt_failed=true
  fi
  chmod 0600 "$_pt_manifest_tmp" 2>/dev/null || true
  if [ "$_pt_failed" = "false" ] \
     && ! mv "$_pt_manifest_tmp" "$_pt_entry/manifest.properties"; then
    _pt_failed=true
  fi

  if [ "$_pt_failed" = "false" ]; then
    if ! (
      cd "$_pt_entry" || exit 1
      for _pt_tracked in manifest.properties module.kpm module.ko module.o module.kpm.sig events args autoload; do
        [ -f "$_pt_tracked" ] || continue
        sha256sum "$_pt_tracked" || exit 1
      done >checksums.sha256.tmp
    ); then
      _pt_failed=true
    elif ! mv "$_pt_entry/checksums.sha256.tmp" "$_pt_entry/checksums.sha256"; then
      _pt_failed=true
    fi
  fi

  if [ "$_pt_failed" = "true" ]; then
    patchnest_rollback_transaction \
      "$_pt_entry" "$_pt_entry_id" "$_pt_module_id" "$_pt_reason" \
      "$_pt_primary_name" "$_pt_source" "$_pt_sig_source" \
      "$_pt_events_source" "$_pt_args_source" "$_pt_autoload_source" || true
    return 1
  fi

  chmod 0600 "$_pt_entry/manifest.properties" "$_pt_entry/checksums.sha256" 2>/dev/null || true
  if ! printf '%s\n' 'state=complete' >"$_pt_entry/state.tmp" \
     || ! mv "$_pt_entry/state.tmp" "$_pt_entry/state"; then
    rm -f "$_pt_entry/state.tmp" 2>/dev/null || true
    patchnest_rollback_transaction \
      "$_pt_entry" "$_pt_entry_id" "$_pt_module_id" "$_pt_reason" \
      "$_pt_primary_name" "$_pt_source" "$_pt_sig_source" \
      "$_pt_events_source" "$_pt_args_source" "$_pt_autoload_source" || true
    return 1
  fi
  chmod 0600 "$_pt_entry/state" 2>/dev/null || true
  patchnest_transaction_log "stored entry=$_pt_entry_id module=$_pt_module_id reason=$_pt_reason"
  printf '%s\n' "$_pt_entry_id"
  return 0
}
