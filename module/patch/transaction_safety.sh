#!/system/bin/sh
# Transaction identity helpers shared by patch and restore paths.
# No function in this file writes a boot target directly.

PATCHNEST_ROLLBACK_BINDING_FILE="${PATCHNEST_ROLLBACK_BINDING_FILE:-/data/adb/patchnest/rollback_binding.json}"

patchnest_device_binding_sha256() {
    # Synthetic identity is an offline-test hook only. Production always uses
    # the real boot serial/context and stores only the digest, never the serial.
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

    _pn_target=${BOOT_TARGET:-unknown-target}
    _pn_digest=$(printf '%s' "$_pn_identity|$_pn_target" | sha256sum | awk '{print $1}')
    printf '%s' "$_pn_digest" | grep -Eq '^[0-9a-f]{64}$' || return 1
    printf '%s\n' "$_pn_digest"
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

    _pn_backup_sha=$(sha256sum "$BACKUP_CANDIDATE" 2>/dev/null | awk '{print $1}')
    _pn_patched_sha=$(sha256sum "$WORKDIR/new-boot.img" 2>/dev/null | awk '{print $1}')
    _pn_patched_size=$(stat -c '%s' "$WORKDIR/new-boot.img" 2>/dev/null)
    _pn_device_sha=$(patchnest_device_binding_sha256) || return 1
    printf '%s' "$_pn_backup_sha" | grep -Eq '^[0-9a-f]{64}$' || return 1
    printf '%s' "$_pn_patched_sha" | grep -Eq '^[0-9a-f]{64}$' || return 1
    printf '%s' "$_pn_patched_size" | grep -Eq '^[1-9][0-9]*$' || return 1

    _pn_key_sha="null"
    if command -v patchnest_superkey_sha256 >/dev/null 2>&1; then
        _pn_key_sha=$(patchnest_superkey_sha256 2>/dev/null || printf 'null')
    fi
    case "$_pn_key_sha" in
        null) ;;
        *) printf '%s' "$_pn_key_sha" | grep -Eq '^[0-9a-f]{64}$' || return 1 ;;
    esac

    _pn_when=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
    _pn_dir=${PATCHNEST_ROLLBACK_BINDING_FILE%/*}
    mkdir -p "$_pn_dir" || return 1
    umask 077
    _pn_tmp="${PATCHNEST_ROLLBACK_BINDING_FILE}.tmp.$$"

    cat > "$_pn_tmp" <<EOF
{
  "schema": 1,
  "boot_target": "$BOOT_TARGET",
  "device_binding_sha256": "$_pn_device_sha",
  "rollback_backup": "$_pn_backup_name",
  "rollback_backup_sha256": "$_pn_backup_sha",
  "patched_image_sha256": "$_pn_patched_sha",
  "patched_image_size": $_pn_patched_size,
  "superkey_sha256": "$_pn_key_sha",
  "verified_readback": true,
  "committed_at": "$_pn_when"
}
EOF
    chmod 0600 "$_pn_tmp" || { rm -f "$_pn_tmp"; return 1; }
    [ "$(stat -c '%a' "$_pn_tmp" 2>/dev/null)" = "600" ] || {
        rm -f "$_pn_tmp"
        return 1
    }

    # One irreversible binding transition. No chmod or other potentially
    # failing mutation is performed after mv, so an existing valid binding is
    # either untouched or atomically replaced by the complete new record.
    mv -f "$_pn_tmp" "$PATCHNEST_ROLLBACK_BINDING_FILE" || {
        rm -f "$_pn_tmp"
        return 1
    }
    return 0
}

patchnest_remove_rollback_binding() {
    rm -f "$PATCHNEST_ROLLBACK_BINDING_FILE"
}
