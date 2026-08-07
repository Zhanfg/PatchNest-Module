#!/system/bin/sh
# Shared PatchNest recovery-monitoring state helpers.
# This file is sourced by unpatch, restore, post-fs-data, and status paths.

PATCHNEST_STATE_DIR=${PATCHNEST_STATE_DIR:-/data/adb/patchnest}
PATCHNEST_SUSPEND_FILE="$PATCHNEST_STATE_DIR/recovery_suspended"
PATCHNEST_RECOVERY_STATE="$PATCHNEST_STATE_DIR/recovery_state.json"
PATCHNEST_BOOT_COUNT="$PATCHNEST_STATE_DIR/boot_count"
PATCHNEST_RECOVERY_MARKER="$PATCHNEST_STATE_DIR/autorecovery_active"
PATCHNEST_RECOVERY_REQUEST="$PATCHNEST_STATE_DIR/auto_unpatch_requested"

patchnest_state_escape() {
  printf '%s' "$1" | tr -d '\000-\037\177' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

patchnest_valid_suspend_reason() {
  case "$1" in
    current-image-unpatched|verified-backup-restored) return 0 ;;
    *) return 1 ;;
  esac
}

patchnest_recovery_monitoring_suspended() {
  [ -f "$PATCHNEST_SUSPEND_FILE" ] && [ ! -L "$PATCHNEST_SUSPEND_FILE" ] || return 1
  _pn_size=$(wc -c <"$PATCHNEST_SUSPEND_FILE" 2>/dev/null || true)
  case "$_pn_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_pn_size" -le 512 ] || return 1
  [ "$(grep -c '^reason=' "$PATCHNEST_SUSPEND_FILE" 2>/dev/null || true)" = "1" ] || return 1
  _pn_reason=$(sed -n 's/^reason=//p' "$PATCHNEST_SUSPEND_FILE" 2>/dev/null | head -n 1)
  patchnest_valid_suspend_reason "$_pn_reason"
}

patchnest_suspend_recovery_monitoring() {
  _pn_reason=$1
  _pn_target=${2:-unknown}
  _pn_sha=${3:-unknown}
  patchnest_valid_suspend_reason "$_pn_reason" || return 1
  case "$_pn_target" in ''|*[!A-Za-z0-9_.-]*) _pn_target=unknown ;; esac
  printf '%s' "$_pn_sha" | grep -Eq '^[0-9a-f]{64}$' || _pn_sha=unknown

  mkdir -p "$PATCHNEST_STATE_DIR" || return 1
  chmod 0700 "$PATCHNEST_STATE_DIR" 2>/dev/null || true
  _pn_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  _pn_suspend_tmp="${PATCHNEST_SUSPEND_FILE}.tmp.$$"
  _pn_state_tmp="${PATCHNEST_RECOVERY_STATE}.tmp.$$"

  cat >"$_pn_suspend_tmp" <<EOF
schema_version=1
reason=$_pn_reason
target=$_pn_target
artifact_sha256=$_pn_sha
suspended_at=$_pn_at
EOF
  chmod 0600 "$_pn_suspend_tmp" 2>/dev/null || true

  cat >"$_pn_state_tmp" <<EOF
{
  "schema_version": 1,
  "boot_count": 0,
  "threshold": 3,
  "recovery_requested": false,
  "automatic_flash_performed": false,
  "monitoring_suspended": true,
  "suspension_reason": "$(patchnest_state_escape "$_pn_reason")",
  "target": "$(patchnest_state_escape "$_pn_target")",
  "artifact_sha256": "$(patchnest_state_escape "$_pn_sha")",
  "resolved_at": "$(patchnest_state_escape "$_pn_at")",
  "required_next_step": "repatch_or_remove_module"
}
EOF
  chmod 0600 "$_pn_state_tmp" 2>/dev/null || true

  mv "$_pn_suspend_tmp" "$PATCHNEST_SUSPEND_FILE" || {
    rm -f "$_pn_suspend_tmp" "$_pn_state_tmp"
    return 1
  }
  if ! mv "$_pn_state_tmp" "$PATCHNEST_RECOVERY_STATE"; then
    rm -f "$PATCHNEST_SUSPEND_FILE" "$_pn_state_tmp"
    return 1
  fi
  printf '%s\n' 0 >"$PATCHNEST_BOOT_COUNT" 2>/dev/null || true
  rm -f "$PATCHNEST_RECOVERY_MARKER" "$PATCHNEST_RECOVERY_REQUEST" 2>/dev/null || true
  return 0
}

patchnest_resume_recovery_monitoring() {
  _pn_resolution=${1:-patch-installed}
  case "$_pn_resolution" in
    patch-installed|healthy-kpatch-hello) ;;
    *) _pn_resolution=patch-installed ;;
  esac
  mkdir -p "$PATCHNEST_STATE_DIR" || return 1
  _pn_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  _pn_state_tmp="${PATCHNEST_RECOVERY_STATE}.tmp.$$"
  cat >"$_pn_state_tmp" <<EOF
{
  "schema_version": 1,
  "boot_count": 0,
  "threshold": 3,
  "recovery_requested": false,
  "automatic_flash_performed": false,
  "monitoring_suspended": false,
  "resolution": "$(patchnest_state_escape "$_pn_resolution")",
  "resolved_at": "$(patchnest_state_escape "$_pn_at")",
  "required_next_step": "none"
}
EOF
  chmod 0600 "$_pn_state_tmp" 2>/dev/null || true

  rm -f "$PATCHNEST_SUSPEND_FILE" "$PATCHNEST_RECOVERY_MARKER" "$PATCHNEST_RECOVERY_REQUEST" 2>/dev/null || {
    rm -f "$_pn_state_tmp"
    return 1
  }
  printf '%s\n' 0 >"$PATCHNEST_BOOT_COUNT" || {
    rm -f "$_pn_state_tmp"
    return 1
  }
  mv "$_pn_state_tmp" "$PATCHNEST_RECOVERY_STATE"
}
