#!/system/bin/sh
# High-level destructive boot write transaction.
# Requires flash_safety.sh, transaction_safety.sh and superkey_safety.sh.

# Candidate-only physical validation gate. Normal review/release trees without
# FR014_DEVICE_CANDIDATE treat this helper as a no-op. A candidate marker with a
# missing helper is a hard failure, never an implicit bypass.
PATCHNEST_FR014_GATE_MISSING=0
if [ -n "${MODPATH:-}" ]; then
    _pn_candidate_marker="$MODPATH/../FR014_DEVICE_CANDIDATE"
    if [ -f "$_pn_candidate_marker" ]; then
        if [ -f "$MODPATH/fr014_gate.sh" ]; then
            # shellcheck disable=SC1091
            . "$MODPATH/fr014_gate.sh"
        else
            PATCHNEST_FR014_GATE_MISSING=1
        fi
    elif [ -f "$MODPATH/fr014_gate.sh" ]; then
        # Load the no-op-capable helper in normal review/release trees as well.
        # shellcheck disable=SC1091
        . "$MODPATH/fr014_gate.sh"
    fi
fi

patchnest_discard_pending_key_if_new() {
    if command -v patchnest_discard_pending_key >/dev/null 2>&1; then
        patchnest_discard_pending_key || true
    fi
}

patchnest_transaction_cleanup_transient() {
    patchnest_clear_pending_transaction || true
    patchnest_discard_pending_key_if_new
}

patchnest_attempt_verified_rollback() {
    _pn_target=$1
    _pn_backup=$2
    >&2 echo "! Attempting verified rollback to pre-write boot image"
    flash_image "$_pn_backup" "$_pn_target"
    _pn_rb=$?
    if [ "$_pn_rb" -eq 0 ]; then
        patchnest_transaction_cleanup_transient
        patchnest_clear_recovery_required || true
        echo "- Verified rollback restored the pre-write boot image"
        return 0
    fi

    patchnest_mark_recovery_required "automatic_rollback_failed:${_pn_rb}" || true
    >&2 echo "! CRITICAL: automatic rollback failed: $_pn_rb"
    >&2 echo "! Pending transaction/key evidence was preserved for recovery"
    return 1
}

# Returns:
#   0  write verified and pending transaction advanced to state=written
#   9  FR-014 candidate preflight gate rejected/missing; target untouched
#   10 transaction could not be staged; target untouched
#   11 writer rejected before target mutation; transient state removed
#   20 writer may have touched target; verified rollback succeeded
#   21 writer may have touched target; automatic rollback failed (fatal)
#   22 write verified but state advance failed; verified rollback succeeded
#   23 write verified but state advance and rollback both failed (fatal)
patchnest_transactional_flash() {
    _pn_source=$1
    _pn_target=$2
    _pn_backup=$3

    if [ "${PATCHNEST_FR014_GATE_MISSING:-0}" = "1" ]; then
        >&2 echo "! FR-014 candidate gate helper is missing"
        patchnest_discard_pending_key_if_new
        return 9
    fi
    if [ -f "${_pn_candidate_marker:-/nonexistent}" ]; then
        if ! command -v patchnest_consume_fr014_preflight_if_required >/dev/null 2>&1; then
            >&2 echo "! FR-014 candidate gate function is unavailable"
            patchnest_discard_pending_key_if_new
            return 9
        fi
        if ! patchnest_consume_fr014_preflight_if_required "$_pn_target"; then
            patchnest_discard_pending_key_if_new
            return 9
        fi
    elif command -v patchnest_consume_fr014_preflight_if_required >/dev/null 2>&1; then
        # Normal branch helper explicitly returns success when candidate mode is
        # inactive. Keeping the call here exercises one common code path.
        patchnest_consume_fr014_preflight_if_required "$_pn_target" || {
            patchnest_discard_pending_key_if_new
            return 9
        }
    fi

    patchnest_stage_pending_transaction "$_pn_source" "$_pn_target" "$_pn_backup" || {
        patchnest_discard_pending_key_if_new
        return 10
    }

    flash_image "$_pn_source" "$_pn_target"
    _pn_rc=$?
    if [ "$_pn_rc" -ne 0 ]; then
        case "$_pn_rc" in
            1|2|3|4|7)
                # Capacity/RO/dependency/payload/unsupported-target failures are
                # detected before the writer starts copying target bytes.
                patchnest_transaction_cleanup_transient
                return 11
                ;;
            5|6)
                # Write failure or readback mismatch may already have changed
                # target bytes. Never just return to the caller.
                if patchnest_attempt_verified_rollback "$_pn_target" "$_pn_backup"; then
                    return 20
                fi
                return 21
                ;;
            *)
                # Unknown writer status is treated as potentially destructive.
                if patchnest_attempt_verified_rollback "$_pn_target" "$_pn_backup"; then
                    return 20
                fi
                return 21
                ;;
        esac
    fi

    if ! patchnest_mark_pending_transaction_written; then
        >&2 echo "! Boot write verified but transaction state could not advance"
        if patchnest_attempt_verified_rollback "$_pn_target" "$_pn_backup"; then
            return 22
        fi
        patchnest_mark_recovery_required "transaction_state_advance_failed" || true
        return 23
    fi

    return 0
}

# Used after a verified write when credential/binding commit fails. The target
# is definitely mutated, so rollback is mandatory and uses the same verified
# writer contract.
patchnest_rollback_after_commit_failure() {
    _pn_target=$1
    _pn_backup=$2
    if patchnest_attempt_verified_rollback "$_pn_target" "$_pn_backup"; then
        return 0
    fi
    patchnest_mark_recovery_required "postwrite_commit_and_rollback_failed" || true
    return 1
}
