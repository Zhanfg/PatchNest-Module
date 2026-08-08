#!/system/bin/sh
# FR-014 physical-candidate one-time preflight receipt.
# Requires transaction_safety.sh helpers. It is a no-op for normal review/release
# trees that do not contain FR014_DEVICE_CANDIDATE.

PATCHNEST_FR014_PREFLIGHT_FILE="${PATCHNEST_FR014_PREFLIGHT_FILE:-/data/adb/patchnest/fr014_preflight.json}"

patchnest_fr014_module_dir() {
    if [ -n "${PATCHNEST_MODULE_DIR:-}" ]; then
        printf '%s\n' "$PATCHNEST_MODULE_DIR"
        return 0
    fi
    if [ -n "${MODPATH:-}" ]; then
        case "$MODPATH" in
            */patch) printf '%s\n' "${MODPATH%/patch}" ;;
            *) printf '%s\n' "$MODPATH" ;;
        esac
        return 0
    fi
    return 1
}

patchnest_fr014_marker_path() {
    _pn_mod=$(patchnest_fr014_module_dir) || return 1
    printf '%s\n' "$_pn_mod/FR014_DEVICE_CANDIDATE"
}

patchnest_fr014_candidate_active() {
    _pn_marker=$(patchnest_fr014_marker_path 2>/dev/null) || return 1
    [ -f "$_pn_marker" ]
}

patchnest_clear_fr014_preflight_receipt() {
    rm -f "$PATCHNEST_FR014_PREFLIGHT_FILE"
    [ ! -e "$PATCHNEST_FR014_PREFLIGHT_FILE" ]
}

patchnest_write_fr014_preflight_receipt() {
    _pn_target=$1
    patchnest_fr014_candidate_active || return 0
    [ -e "$_pn_target" ] || return 1
    _pn_target=$(readlink -f "$_pn_target" 2>/dev/null || printf '%s' "$_pn_target")
    _pn_marker=$(patchnest_fr014_marker_path) || return 1
    _pn_marker_sha=$(patchnest_hash_file "$_pn_marker") || return 1
    _pn_target_sha=$(patchnest_hash_file "$_pn_target") || return 1
    _pn_device_sha=$(patchnest_device_binding_sha256 "$_pn_target") || return 1
    _pn_dir=${PATCHNEST_FR014_PREFLIGHT_FILE%/*}
    mkdir -p "$_pn_dir" || return 1
    umask 077
    _pn_tmp="${PATCHNEST_FR014_PREFLIGHT_FILE}.tmp.$$"
    cat > "$_pn_tmp" <<EOF
{
  "schema": 1,
  "preflight_pass": true,
  "boot_target": "$(patchnest_json_escape "$_pn_target")",
  "boot_target_sha256": "$_pn_target_sha",
  "device_binding_sha256": "$_pn_device_sha",
  "candidate_marker_sha256": "$_pn_marker_sha",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"
}
EOF
    chmod 0600 "$_pn_tmp" || { rm -f "$_pn_tmp"; return 1; }
    mv -f "$_pn_tmp" "$PATCHNEST_FR014_PREFLIGHT_FILE" || { rm -f "$_pn_tmp"; return 1; }
    patchnest_state_file_is_secure "$PATCHNEST_FR014_PREFLIGHT_FILE"
}

patchnest_consume_fr014_preflight_if_required() {
    _pn_target=$1
    patchnest_fr014_candidate_active || return 0
    _pn_target=$(readlink -f "$_pn_target" 2>/dev/null || printf '%s' "$_pn_target")
    _pn_marker=$(patchnest_fr014_marker_path) || return 1

    patchnest_state_file_is_secure "$PATCHNEST_FR014_PREFLIGHT_FILE" || {
        >&2 echo "! FR-014 candidate requires a fresh device_validation.sh preflight"
        return 1
    }
    [ "$(patchnest_json_bool preflight_pass "$PATCHNEST_FR014_PREFLIGHT_FILE")" = "true" ] || return 1
    [ "$(patchnest_json_string boot_target "$PATCHNEST_FR014_PREFLIGHT_FILE")" = "$_pn_target" ] || {
        >&2 echo "! FR-014 preflight receipt boot target mismatch"
        return 1
    }

    _pn_expected_target=$(patchnest_json_string boot_target_sha256 "$PATCHNEST_FR014_PREFLIGHT_FILE")
    _pn_expected_device=$(patchnest_json_string device_binding_sha256 "$PATCHNEST_FR014_PREFLIGHT_FILE")
    _pn_expected_marker=$(patchnest_json_string candidate_marker_sha256 "$PATCHNEST_FR014_PREFLIGHT_FILE")
    printf '%s' "$_pn_expected_target$_pn_expected_device$_pn_expected_marker" | grep -Eq '^[0-9a-f]{192}$' || return 1

    [ "$(patchnest_hash_file "$_pn_target")" = "$_pn_expected_target" ] || {
        >&2 echo "! Boot target changed after FR-014 preflight"
        return 1
    }
    [ "$(patchnest_device_binding_sha256 "$_pn_target")" = "$_pn_expected_device" ] || {
        >&2 echo "! Device/slot context changed after FR-014 preflight"
        return 1
    }
    [ "$(patchnest_hash_file "$_pn_marker")" = "$_pn_expected_marker" ] || {
        >&2 echo "! FR-014 candidate identity changed after preflight"
        return 1
    }

    # One successful validation authorizes one destructive attempt only. Consume
    # before the transaction is staged; any later pre-write failure requires a
    # fresh read-only preflight rather than silently reusing stale approval.
    patchnest_clear_fr014_preflight_receipt || return 1
    return 0
}
