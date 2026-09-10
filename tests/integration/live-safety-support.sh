# shellcheck shell=bash
# Safety backup and run-level restoration helpers sourced by run.sh.

safety_backup() {
    [ "$SAFETY_BACKUP" = "1" ] || return 0
    [ "$RUN_IMAGE_UPGRADE" != "1" ] || UPGRADE_TELEMETRY_EPOCH="$(rx 'date +%s')"
    it_log "Taking a safety backup before destructive scenarios (pithead backup -y)…"
    if ! pithead backup -y --no-encrypt >"$OUT_DIR/backup.log" 2>&1; then
        SAFETY_ARCHIVE="$(sed -n 's/^.*Backup written to: //p' "$OUT_DIR/backup.log" | tail -n1)"
        it_fail "safety backup created" "see $OUT_DIR/backup.log"
        if [ -n "$SAFETY_ARCHIVE" ] && rx "test -f $(quote_arg "$SAFETY_ARCHIVE") && test ! -L $(quote_arg "$SAFETY_ARCHIVE")"; then
            SAFETY_RESTORE_FAILED=1
            it_warn "backup is valid but stack restart failed; retaining $SAFETY_ARCHIVE"
        fi
        return 1
    fi
    SAFETY_ARCHIVE="$(sed -n 's/^.*Backup written to: //p' "$OUT_DIR/backup.log" | tail -n1)"
    if [ -z "$SAFETY_ARCHIVE" ] || ! rx "test -f $(quote_arg "$SAFETY_ARCHIVE") && test ! -L $(quote_arg "$SAFETY_ARCHIVE")"; then
        it_fail "safety backup archive located" "the successful backup did not name a regular archive"
        safety_cleanup
        return 1
    fi
    it_log "Safety backup: $SAFETY_ARCHIVE"
    local listing
    listing="$(rx "tar -tzf $(quote_arg "$SAFETY_ARCHIVE") 2>/dev/null")"
    assert_contains "backup archive contains config.json" "$listing" "config.json"
    assert_contains "backup archive contains .env" "$listing" ".env"
    if ! printf '%s\n' "$listing" | grep -q 'config.json' || ! printf '%s\n' "$listing" | grep -q '\.env'; then
        safety_cleanup
        return 1
    fi
    wait_status_ok 240 || {
        it_fail "stack recovered after safety backup" "pithead status did not become healthy"
        safety_restore_exact && safety_cleanup || true
        return 1
    }
    if [ "$RUN_IMAGE_UPGRADE" = "1" ]; then
        if ! UPGRADE_BEFORE_TELEMETRY="$(archived_dashboard_durable_rows "$SAFETY_ARCHIVE" "$UPGRADE_TELEMETRY_EPOCH")" ||
            [ -z "$UPGRADE_BEFORE_TELEMETRY" ]; then
            it_fail "safety archive durable dashboard state is readable" "the archived database or a required table is absent"
            safety_cleanup
            return 1
        fi
    fi
}

safety_restore_exact() {
    pithead down >/dev/null 2>&1 || true
    if ! pithead restore -y "$SAFETY_ARCHIVE" >/dev/null 2>&1 ||
        ! strict_pithead up >/dev/null 2>&1 || ! wait_status_ok 240 ||
        [ "$(rx 'cat config.json' 2>/dev/null)" != "$BASELINE_CONFIG" ] ||
        [ "$(upgrade_secret_fingerprints)" != "$BASELINE_EXACT_SECRET_FP" ]; then
        SAFETY_RESTORE_FAILED=1
        return 1
    fi
    it_log "rollback complete — exact config and wallet/proxy/dashboard/RPC/onion baseline verified."
    _XVB_RESTORE_ARMED=0
    _SAFETY_RESTORE_ARMED=0
}

safety_rollback_if_failed() {
    [ "$SAFETY_BACKUP" = "1" ] && [ -n "$SAFETY_ARCHIVE" ] || return 0
    [ "$IT_FAIL" -gt 0 ] || return 0
    it_warn "failures detected — rolling back to the safety backup ($SAFETY_ARCHIVE)…"
    safety_restore_exact || {
        it_fail "safety rollback restored the exact healthy baseline" "restore/apply/health/config/secret verification failed; archive retained at $SAFETY_ARCHIVE"
        return 1
    }
}

safety_abort_restore() {
    local original_rc=$? restore_failed=0
    if [ "$_SAFETY_RESTORE_ARMED" = 1 ]; then
        it_warn "interrupted destructive run — restoring the safety backup"
        safety_restore_exact || restore_failed=1
    fi
    [ -z "$_SAFETY_FOREIGN_TRAP" ] || eval "$_SAFETY_FOREIGN_TRAP"
    [ "$restore_failed" = 0 ] || exit 1
    return "$original_rc"
}

arm_safety_abort_restore() {
    local cur
    cur="$(trap -p EXIT)"
    if [ -n "$cur" ]; then
        local -a parsed
        eval "parsed=($cur)"
        _SAFETY_FOREIGN_TRAP="${parsed[2]}"
    fi
    _SAFETY_RESTORE_ARMED=1
    trap safety_abort_restore EXIT
}

safety_cleanup() {
    [ -n "$SAFETY_ARCHIVE" ] || return 0
    if [ "$SAFETY_RESTORE_FAILED" != "0" ]; then
        it_warn "retaining the safety backup after a failed rollback: $SAFETY_ARCHIVE"
    elif [ "$KEEP_STATE" = "1" ]; then
        it_warn "--keep: leaving the safety backup at $SAFETY_ARCHIVE"
    else
        rx "rm -f $(quote_arg "$SAFETY_ARCHIVE")" >/dev/null 2>&1 || true
        it_step "removed the safety backup archive"
    fi
}
