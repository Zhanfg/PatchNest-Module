#!/system/bin/sh
# Transaction identity/state helpers shared by patch, service and restore paths.
# This file never writes a boot target directly.

PATCHNEST_ROLLBACK_BINDING_FILE="${PATCHNEST_ROLLBACK_BINDING_FILE:-/data/adb/patchnest/rollback_binding.json}"
PATCHNEST_PENDING_TRANSACTION_FILE="${PATCHNEST_PENDING_TRANSACTION_FILE:-/data/adb/patchnest/transaction.pending.json}"
PATCHNEST_RECOVERY_REQUIRED_FILE="${PATCHNEST_RECOVERY_REQUIRED_FILE:-/data/adb/patchnest/flash_recovery_required}"

patchnest_json_escape() {
    printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

patchnest_json_string() {
    _pn_key=$1
    _pn_file=$2
    grep -o "\"${_pn_key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$_pn_file" 2>/dev/null \
        | head -n 1 \
        | sed -E "s/.*\"${_pn_key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/"
}

patchnest_json_bool() {
    _pn_key=$1
    _pn_file=$2
    grep -o "\"${_pn_key}\"[[:space:]]*:[[:space:]]*(true|false)" "$_pn_file" 2>/dev/null \
        | head -n 1 \
        | sed -E "s/.*\"${_pn_key}\"[[:space:]]*:[[:space:]]*(true|false).*/\\1/"
}

patchnest_json_number() {
    _pn_key=$1
    _pn_file=$2
    grep -o "\"${_pn_key}\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" "$_pn_file" 2>/dev/null \
        | head -n 1 \
        | sed -E "s/.*\"${_pn_key}\"[[:space:]]*:[[:space:]]*([0-9][0-9]*).*/\\1/"
}

patchnest_state_expected_owner() {
    if [ "${PATCHNEST_TRANSACTION_TEST:-0}" = "1" ]; then
        id -u
    else
        printf '%s\n' 0
    fi
}

patchnest_state_file_is_secure() {
    _pn_file=$1
    [ -f "$_pn_file" ] || return 1
    [ ! -L "$_pn_file" ] || return 1
    _pn_mode=$(stat -c '%a' "$_pn_file" 2>/dev/null) || return 1
    _pn_owner=$(stat -c '%u' "$_pn_file" 2>/dev/null) || return 1
    _pn_expected_owner=$(patchnest_state_expected_owner) || return 1
    [ "$_pn_mode" = "600" ] || return 1
    [ "$_pn_owner" = "$_pn_expected_owner" ] || return 1
}

patchnest_hash_file() {
    _pn_hash=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    printf '%s' "$_pn_hash" | grep -Eq '^[0-9a-f]{64}$' || return 1
    printf '%s\n' "$_pn_hash"
}

patchnest_hash_prefix() {
    _pn_target=$1
    _pn_size=$2
    printf '%s' "$_pn_size" | grep -Eq '^[1-9][0-9]*$' || return 1
    _pn_blocks=$(((_pn_size + 1048575) / 1048576))
    _pn_digest=$(dd if="$_pn_target" bs=1048576 count="$_pn_blocks" 2>/dev/null \
        | head -c "$_pn_size" \
        | sha256sum \
        | awk '{print $1}')
    printf '%s' "$_pn_digest" | grep -Eq '^[0-9a-f]{64}$' || return 1
    printf '%s\n' "$_pn_digest"
}

patchnest_device_binding_sha256() {
    _pn_bind_target=${1:-${BOOT_TARGET:-unknown-target}}
    if [ "${PATCHNEST_TRANSACTION_TEST:-0}" = "1" ] && [ -n "${PATCHNEST_DEVICE_IDENTITY:-}" ]; then
        _pn_identity=$PATCHNEST_DEVICE_IDENTITY
    else
        command -v getprop >/dev/null 2>&1 || return 1
        _pn_serial=$(getprop ro.boot.serialno 2>/dev/null | tr -d '\r\n')
        [ -n "$_pn_serial" ] || _pn_serial=$(getprop ro.serialno 2>/dev/null | tr -d '\r\n')
        [ -n "$_pn_serial" ] || return 1
        _pn_product=$(getprop ro.product.device 2>/dev/null | tr -d '\r\n')
        _pn_vbmeta=$(getprop ro.boot.vbmeta.digest 2>/dev/null | tr -d '\r\n')
        _pn_slot=$(getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r\n')
        _pn_identity="$_pn_serial|$_pn_product|$_pn_vbmeta|$_pn_slot"
    fi

    _pn_digest=$(printf '%s' "$_pn_identity|$_pn_bind_target" | sha256sum | awk '{print $1}')
    printf '%s' "$_pn_digest" | grep -Eq '^[0-9a-f]{64}$' || return 1
    printf '%s\n' "$_pn_digest"
}

patchnest_has_unfinished_transaction() {
    [ -e "$PATCHNEST_PENDING_TRANSACTION_FILE" ] || [ -e "$PATCHNEST_RECOVERY_REQUIRED_FILE" ]
}

patchnest_clear_pending_transaction() {
    rm -f "$PATCHNEST_PENDING_TRANSACTION_FILE"
    [ ! -e "$PATCHNEST_PENDING_TRANSACTION_FILE" ]
}

patchnest_mark_recovery_required() {
    _pn_reason=${1:-unknown}
    _pn_dir=${PATCHNEST_RECOVERY_REQUIRED_FILE%/*}
    mkdir -p "$_pn_dir" || return 1
    umask 077
    _pn_tmp="${PATCHNEST_RECOVERY_REQUIRED_FILE}.tmp.$$"
    {
        printf 'reason=%s\n' "$_pn_reason"
        printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"
    } > "$_pn_tmp" || return 1
    chmod 0600 "$_pn_tmp" || { rm -f "$_pn_tmp"; return 1; }
    mv -f "$_pn_tmp" "$PATCHNEST_RECOVERY_REQUIRED_FILE" || { rm -f "$_pn_tmp"; return 1; }
}

patchnest_clear_recovery_required() {
    rm -f "$PATCHNEST_RECOVERY_REQUIRED_FILE"
}

patchnest_stage_pending_transaction() {
    _pn_source=$1
    _pn_target=$2
    _pn_backup=$3

    [ ! -e "$PATCHNEST_PENDING_TRANSACTION_FILE" ] || return 1
    [ ! -e "$PATCHNEST_RECOVERY_REQUIRED_FILE" ] || return 1
    [ -f "$_pn_source" ] || return 1
    [ -f "$_pn_backup" ] || return 1
    [ -e "$_pn_target" ] || return 1

    _pn_source_sha=$(patchnest_hash_file "$_pn_source") || return 1
    _pn_backup_sha=$(patchnest_hash_file "$_pn_backup") || return 1
    _pn_source_size=$(stat -c '%s' "$_pn_source" 2>/dev/null)
    _pn_device_sha=$(patchnest_device_binding_sha256 "$_pn_target") || return 1
    _pn_key_sha=$(patchnest_superkey_sha256 2>/dev/null) || return 1
    _pn_backup_name=$(basename "$_pn_backup")

    printf '%s' "$_pn_source_size" | grep -Eq '^[1-9][0-9]*$' || return 1
    case "$_pn_backup_name" in
        boot_backup_*.img) ;;
        *) return 1 ;;
    esac
    case "$_pn_backup_name" in
        */*|*..*) return 1 ;;
    esac

    _pn_dir=${PATCHNEST_PENDING_TRANSACTION_FILE%/*}
    mkdir -p "$_pn_dir" || return 1
    umask 077
    _pn_tmp="${PATCHNEST_PENDING_TRANSACTION_FILE}.tmp.$$"
    cat > "$_pn_tmp" <<EOF
{
  "schema": 2,
  "state": "prepared",
  "boot_target": "$(patchnest_json_escape "$_pn_target")",
  "device_binding_sha256": "$_pn_device_sha",
  "rollback_backup": "$(patchnest_json_escape "$_pn_backup_name")",
  "rollback_backup_sha256": "$_pn_backup_sha",
  "patched_image_sha256": "$_pn_source_sha",
  "patched_image_size": $_pn_source_size,
  "superkey_sha256": "$_pn_key_sha",
  "prepared_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"
}
EOF
    chmod 0600 "$_pn_tmp" || { rm -f "$_pn_tmp"; return 1; }
    mv -f "$_pn_tmp" "$PATCHNEST_PENDING_TRANSACTION_FILE" || { rm -f "$_pn_tmp"; return 1; }
    patchnest_state_file_is_secure "$PATCHNEST_PENDING_TRANSACTION_FILE"
}

patchnest_mark_pending_transaction_written() {
    patchnest_state_file_is_secure "$PATCHNEST_PENDING_TRANSACTION_FILE" || return 1
    [ "$(patchnest_json_string state "$PATCHNEST_PENDING_TRANSACTION_FILE")" = "prepared" ] || return 1

    _pn_target=$(patchnest_json_string boot_target "$PATCHNEST_PENDING_TRANSACTION_FILE")
    _pn_sha=$(patchnest_json_string patched_image_sha256 "$PATCHNEST_PENDING_TRANSACTION_FILE")
    _pn_size=$(patchnest_json_number patched_image_size "$PATCHNEST_PENDING_TRANSACTION_FILE")
    [ -e "$_pn_target" ] || return 1
    _pn_actual=$(patchnest_hash_prefix "$_pn_target" "$_pn_size") || return 1
    [ "$_pn_actual" = "$_pn_sha" ] || return 1

    _pn_tmp="${PATCHNEST_PENDING_TRANSACTION_FILE}.tmp.$$"
    sed 's/"state"[[:space:]]*:[[:space:]]*"prepared"/"state": "written"/' \
        "$PATCHNEST_PENDING_TRANSACTION_FILE" > "$_pn_tmp" || return 1
    chmod 0600 "$_pn_tmp" || { rm -f "$_pn_tmp"; return 1; }
    mv -f "$_pn_tmp" "$PATCHNEST_PENDING_TRANSACTION_FILE" || { rm -f "$_pn_tmp"; return 1; }
    [ "$(patchnest_json_string state "$PATCHNEST_PENDING_TRANSACTION_FILE")" = "written" ]
}

patchnest_pending_transaction_matches_written_key() {
    _pn_key=$1
    patchnest_state_file_is_secure "$PATCHNEST_PENDING_TRANSACTION_FILE" || return 1
    [ "$(patchnest_json_string state "$PATCHNEST_PENDING_TRANSACTION_FILE")" = "written" ] || return 1

    _pn_target=$(patchnest_json_string boot_target "$PATCHNEST_PENDING_TRANSACTION_FILE")
    _pn_device=$(patchnest_json_string device_binding_sha256 "$PATCHNEST_PENDING_TRANSACTION_FILE")
    _pn_sha=$(patchnest_json_string patched_image_sha256 "$PATCHNEST_PENDING_TRANSACTION_FILE")
    _pn_size=$(patchnest_json_number patched_image_size "$PATCHNEST_PENDING_TRANSACTION_FILE")
    _pn_key_sha=$(patchnest_json_string superkey_sha256 "$PATCHNEST_PENDING_TRANSACTION_FILE")
    [ -e "$_pn_target" ] || return 1
    printf '%s' "$_pn_device$_pn_sha$_pn_key_sha" | grep -Eq '^[0-9a-f]{192}$' || return 1
    printf '%s' "$_pn_size" | grep -Eq '^[1-9][0-9]*$' || return 1

    _pn_actual_key=$(printf '%s' "$_pn_key" | sha256sum | awk '{print $1}')
    [ "$_pn_actual_key" = "$_pn_key_sha" ] || return 1
    _pn_actual_device=$(patchnest_device_binding_sha256 "$_pn_target") || return 1
    [ "$_pn_actual_device" = "$_pn_device" ] || return 1
    _pn_actual_sha=$(patchnest_hash_prefix "$_pn_target" "$_pn_size") || return 1
    [ "$_pn_actual_sha" = "$_pn_sha" ]
}

patchnest_commit_rollback_binding() {
    [ -n "${BOOT_TARGET:-}" ] || return 1
    [ -n "${BACKUP_CANDIDATE:-}" ] || return 1
    [ -f "$BACKUP_CANDIDATE" ] || return 1
    [ -n "${WORKDIR:-}" ] || return 1
    [ -f "$WORKDIR/new-boot.img" ] || return 1

    _pn_backup_name=$(basename "$BACKUP_CANDIDATE")
    case "$_pn_backup_name" in
        boot_backup_*.img) ;;
        *) return 1 ;;
    esac
    case "$_pn_backup_name" in
        */*|*..*) return 1 ;;
    esac

    _pn_backup_sha=$(patchnest_hash_file "$BACKUP_CANDIDATE") || return 1
    _pn_patched_sha=$(patchnest_hash_file "$WORKDIR/new-boot.img") || return 1
    _pn_patched_size=$(stat -c '%s' "$WORKDIR/new-boot.img" 2>/dev/null)
    _pn_device_sha=$(patchnest_device_binding_sha256 "$BOOT_TARGET") || return 1
    _pn_key_sha=$(patchnest_superkey_sha256 2>/dev/null) || return 1
    printf '%s' "$_pn_patched_size" | grep -Eq '^[1-9][0-9]*$' || return 1

    if [ -e "$PATCHNEST_PENDING_TRANSACTION_FILE" ]; then
        patchnest_state_file_is_secure "$PATCHNEST_PENDING_TRANSACTION_FILE" || return 1
        [ "$(patchnest_json_string state "$PATCHNEST_PENDING_TRANSACTION_FILE")" = "written" ] || return 1
        [ "$(patchnest_json_string boot_target "$PATCHNEST_PENDING_TRANSACTION_FILE")" = "$BOOT_TARGET" ] || return 1
        [ "$(patchnest_json_string rollback_backup_sha256 "$PATCHNEST_PENDING_TRANSACTION_FILE")" = "$_pn_backup_sha" ] || return 1
        [ "$(patchnest_json_string patched_image_sha256 "$PATCHNEST_PENDING_TRANSACTION_FILE")" = "$_pn_patched_sha" ] || return 1
        [ "$(patchnest_json_string superkey_sha256 "$PATCHNEST_PENDING_TRANSACTION_FILE")" = "$_pn_key_sha" ] || return 1
    fi

    _pn_when=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
    _pn_dir=${PATCHNEST_ROLLBACK_BINDING_FILE%/*}
    mkdir -p "$_pn_dir" || return 1
    umask 077
    _pn_tmp="${PATCHNEST_ROLLBACK_BINDING_FILE}.tmp.$$"
    cat > "$_pn_tmp" <<EOF
{
  "schema": 2,
  "boot_target": "$(patchnest_json_escape "$BOOT_TARGET")",
  "device_binding_sha256": "$_pn_device_sha",
  "rollback_backup": "$(patchnest_json_escape "$_pn_backup_name")",
  "rollback_backup_sha256": "$_pn_backup_sha",
  "patched_image_sha256": "$_pn_patched_sha",
  "patched_image_size": $_pn_patched_size,
  "superkey_sha256": "$_pn_key_sha",
  "verified_readback": true,
  "committed_at": "$_pn_when"
}
EOF
    chmod 0600 "$_pn_tmp" || { rm -f "$_pn_tmp"; return 1; }
    mv -f "$_pn_tmp" "$PATCHNEST_ROLLBACK_BINDING_FILE" || { rm -f "$_pn_tmp"; return 1; }

    if ! patchnest_clear_pending_transaction; then
        rm -f "$PATCHNEST_ROLLBACK_BINDING_FILE"
        return 1
    fi
    patchnest_clear_recovery_required || true
    return 0
}

patchnest_remove_rollback_binding() {
    rm -f "$PATCHNEST_ROLLBACK_BINDING_FILE"
}
