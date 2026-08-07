#!/system/bin/sh
# PatchNest KPM quarantine manager.
#
# Commands:
#   manage_kpm_quarantine.sh list
#   manage_kpm_quarantine.sh inspect <entry-id>
#   manage_kpm_quarantine.sh activate <entry-id>
#
# `activate` is intentionally strict: the transaction must contain one valid
# .kpm and a valid Ed25519 signature. Existing live files are never replaced.
# There is no delete command; quarantine remains a recovery boundary.

set -u
umask 077

MODDIR=${0%/*}
PNDIR=/data/adb/patchnest
QUARANTINE_DIR="$PNDIR/kpm_quarantine"
KPM_DIR="$PNDIR/kpm"
EVENT_DIR="$PNDIR/kpm_events"
LOG="$PNDIR/kpm_admission.log"
LOCK_DIR="$PNDIR/.quarantine-manager.lock"
PATH="$MODDIR/bin:/system/bin:$PATH"

usage() {
  cat <<'EOF'
Usage:
  manage_kpm_quarantine.sh list
  manage_kpm_quarantine.sh inspect <entry-id>
  manage_kpm_quarantine.sh activate <entry-id>

activate requires a valid KPM signature and refuses to overwrite live files.
EOF
}

log() {
  printf '[%s] quarantine-manager: %s\n' "$(date)" "$*" >>"$LOG" 2>/dev/null || true
}

fail() {
  echo "! $*" >&2
  exit 1
}

safe_entry_id() {
  _value=$1
  case "$_value" in
    ''|*[!A-Za-z0-9_.-]*|.|..) return 1 ;;
  esac
  [ "${#_value}" -le 128 ] || return 1
  printf '%s' "$_value"
}

read_field() {
  _manifest=$1
  _key=$2
  _count=$(grep -c "^${_key}=" "$_manifest" 2>/dev/null || true)
  [ "$_count" = "1" ] || return 1
  sed -n "s/^${_key}=//p" "$_manifest" | head -n 1
}

resolve_entry() {
  _requested=$(safe_entry_id "$1") || return 1
  _entry="$QUARANTINE_DIR/$_requested"
  [ -d "$_entry" ] && [ ! -L "$_entry" ] || return 1
  _manifest="$_entry/manifest.properties"
  [ -f "$_manifest" ] && [ ! -L "$_manifest" ] || return 1
  [ "$(read_field "$_manifest" state 2>/dev/null)" = "complete" ] || return 1
  [ "$(read_field "$_manifest" entry_id 2>/dev/null)" = "$_requested" ] || return 1
  printf '%s' "$_entry"
}

list_entries() {
  printf 'entry_id\tmodule_id\treason\tcreated_at\tsigned\n'
  [ -d "$QUARANTINE_DIR" ] || return 0
  for _entry in "$QUARANTINE_DIR"/*; do
    [ -d "$_entry" ] && [ ! -L "$_entry" ] || continue
    _manifest="$_entry/manifest.properties"
    [ -f "$_manifest" ] && [ ! -L "$_manifest" ] || continue
    [ "$(read_field "$_manifest" state 2>/dev/null)" = "complete" ] || continue
    _entry_id=$(read_field "$_manifest" entry_id 2>/dev/null || true)
    _module_id=$(read_field "$_manifest" module_id 2>/dev/null || true)
    _reason=$(read_field "$_manifest" reason 2>/dev/null || true)
    _created_at=$(read_field "$_manifest" created_at 2>/dev/null || true)
    _signed=no
    [ -s "$_entry/module.kpm.sig" ] && _signed=yes
    printf '%s\t%s\t%s\t%s\t%s\n' "$_entry_id" "$_module_id" "$_reason" "$_created_at" "$_signed"
  done
}

inspect_entry() {
  _entry=$(resolve_entry "$1") || fail "Invalid or incomplete quarantine entry: $1"
  cat "$_entry/manifest.properties"
  echo "files:"
  for _file in "$_entry"/*; do
    [ -f "$_file" ] && [ ! -L "$_file" ] || continue
    _size=$(wc -c <"$_file" 2>/dev/null || printf '?')
    _sha=$(sha256sum "$_file" 2>/dev/null | awk '{print $1}')
    printf '  %s size=%s sha256=%s\n' "$(basename "$_file")" "$_size" "${_sha:-unavailable}"
  done
}

validate_optional_sidecar() {
  _path=$1
  _max_size=$2
  [ -e "$_path" ] || return 0
  [ -f "$_path" ] && [ ! -L "$_path" ] || return 1
  _size=$(wc -c <"$_path" 2>/dev/null || true)
  case "$_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_size" -le "$_max_size" ]
}

activate_entry() {
  _entry=$(resolve_entry "$1") || fail "Invalid or incomplete quarantine entry: $1"
  _manifest="$_entry/manifest.properties"
  _module_id=$(read_field "$_manifest" module_id 2>/dev/null) || fail "Entry has no unique module_id"
  case "$_module_id" in
    ''|*[!A-Za-z0-9_.-]*|.|..) fail "Entry has unsafe module_id" ;;
  esac
  [ "${#_module_id}" -le 64 ] || fail "Entry module_id is too long"
  [ "$(read_field "$_manifest" primary 2>/dev/null)" = "module.kpm" ] \
    || fail "Only quarantined .kpm transactions can be activated"

  _kpm="$_entry/module.kpm"
  _sig="$_entry/module.kpm.sig"
  [ -s "$_kpm" ] && [ ! -L "$_kpm" ] || fail "Quarantine entry has no valid module.kpm"
  [ -s "$_sig" ] && [ ! -L "$_sig" ] || fail "Activation requires module.kpm.sig"
  validate_optional_sidecar "$_entry/events" 1024 || fail "Event sidecar is invalid or too large"
  validate_optional_sidecar "$_entry/args" 4096 || fail "Argument sidecar is invalid or too large"

  command -v kptools >/dev/null 2>&1 || fail "kptools is unavailable"
  kptools -l -M "$_kpm" >/dev/null 2>&1 || fail "Quarantined KPM failed kptools validation"

  [ -f "$MODDIR/kpm_verify.sh" ] || fail "KPM signature verifier is unavailable"
  # shellcheck disable=SC1091
  . "$MODDIR/kpm_verify.sh"
  verify_kpm_sig "$_kpm" "$_sig" || fail "Quarantined KPM signature is invalid"

  mkdir "$LOCK_DIR" 2>/dev/null || fail "Another quarantine operation is already running"
  _stage="$PNDIR/.quarantine-activate.$$"
  cleanup() {
    rm -rf "$_stage" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
  }
  trap cleanup EXIT INT TERM HUP

  [ ! -e "$KPM_DIR/${_module_id}.kpm" ] || fail "Live KPM already exists: $_module_id"
  [ ! -e "$KPM_DIR/${_module_id}.kpm.sig" ] || fail "Live signature already exists: $_module_id"
  [ ! -e "$EVENT_DIR/${_module_id}.events" ] || fail "Live event config already exists: $_module_id"
  [ ! -e "$EVENT_DIR/${_module_id}.args" ] || fail "Live argument config already exists: $_module_id"
  [ ! -e "$EVENT_DIR/${_module_id}.autoload" ] || fail "Live autoload marker already exists: $_module_id"

  mkdir -p "$KPM_DIR" "$EVENT_DIR" || fail "Cannot create live KPM directories"
  mkdir "$_stage" || fail "Cannot create activation staging directory"
  chmod 0700 "$_stage" 2>/dev/null || true
  cp "$_kpm" "$_stage/module.kpm" || fail "Cannot stage KPM"
  cp "$_sig" "$_stage/module.kpm.sig" || fail "Cannot stage signature"
  [ ! -f "$_entry/events" ] || cp "$_entry/events" "$_stage/events" || fail "Cannot stage events"
  [ ! -f "$_entry/args" ] || cp "$_entry/args" "$_stage/args" || fail "Cannot stage arguments"
  chmod 0600 "$_stage"/* 2>/dev/null || true

  kptools -l -M "$_stage/module.kpm" >/dev/null 2>&1 || fail "Staged KPM failed validation"
  verify_kpm_sig "$_stage/module.kpm" "$_stage/module.kpm.sig" \
    || fail "Staged KPM signature failed validation"

  rollback=false
  mv "$_stage/module.kpm.sig" "$KPM_DIR/${_module_id}.kpm.sig" || rollback=true
  if [ "$rollback" = "false" ] && [ -f "$_stage/events" ]; then
    mv "$_stage/events" "$EVENT_DIR/${_module_id}.events" || rollback=true
  fi
  if [ "$rollback" = "false" ] && [ -f "$_stage/args" ]; then
    mv "$_stage/args" "$EVENT_DIR/${_module_id}.args" || rollback=true
  fi
  if [ "$rollback" = "false" ]; then
    mv "$_stage/module.kpm" "$KPM_DIR/${_module_id}.kpm" || rollback=true
  fi
  if [ "$rollback" = "false" ]; then
    : >"$EVENT_DIR/${_module_id}.autoload" || rollback=true
    chmod 0600 "$EVENT_DIR/${_module_id}.autoload" 2>/dev/null || true
  fi

  if [ "$rollback" = "true" ]; then
    rm -f \
      "$KPM_DIR/${_module_id}.kpm" \
      "$KPM_DIR/${_module_id}.kpm.sig" \
      "$EVENT_DIR/${_module_id}.events" \
      "$EVENT_DIR/${_module_id}.args" \
      "$EVENT_DIR/${_module_id}.autoload"
    fail "Activation commit failed and was rolled back"
  fi

  rm -rf "$_entry" || fail "Activated KPM but could not remove quarantine transaction"
  log "activated signed transaction entry=$1 module=$_module_id"
  echo "- Activated signed KPM: $_module_id"
  echo "- Reboot to load it through the normal admission path"
}

case "${1:-}" in
  list)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    list_entries
    ;;
  inspect)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    inspect_entry "$2"
    ;;
  activate)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    activate_entry "$2"
    ;;
  -h|--help|help|'')
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
