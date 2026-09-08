# shellcheck shell=bash
rig_lock_parent_verify() {
    local actor="${RIG_LOCK_PARENT_ACTOR:-}" nonce="${RIG_LOCK_PARENT_NONCE:-}"
    local lf="${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}" hf="${RIG_LOCK_HOLDER:-/run/rig-e2e.holder}" got_actor got_nonce _ rc
    [ -n "$actor" ] || [ -n "$nonce" ] || return 0
    [[ "$actor" =~ ^[A-Za-z0-9._:-]+$ && "$nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
    [ -f "$lf" ] && [ ! -L "$lf" ] && [ -f "$hf" ] && [ ! -L "$hf" ] || return 1
    IFS=' ' read -r got_actor got_nonce _ <"$hf" || return 1
    [ "$got_actor" = "$actor" ] && [ "$got_nonce" = "nonce=$nonce" ] || return 1
    exec 7<"$lf" || return 1
    flock -E 75 -n -x 7
    rc=$?
    exec 7<&-
    [ "$rc" -eq 75 ]
}

rig_lock_parent_use() {
    [ "$IT_MODE" = local ] || {
        it_err "parent-lock continuity is valid only for a local nested runner"
        return 1
    }
    rig_lock_parent_verify || return 1
    _RIG_LOCK_PARENT_VERIFIED=1
    it_log "Verified parent-held rig lock (${RIG_LOCK_PARENT_ACTOR})."
}

parent_lock_checkpoint() { # <phase> [host]; e2e-side remote verification
    local phase="$1" host="${2:-$BENCH_HOST}"
    [ -n "${RIG_LOCK_PARENT_ACTOR:-}" ] || [ -n "${RIG_LOCK_PARENT_NONCE:-}" ] || return 0
    # shellcheck disable=SC2029 # quote_arg makes each client-side expansion one remote word.
    {
        declare -f rig_lock_parent_verify
        printf 'rig_lock_parent_verify\n'
    } | ssh "${SSH_OPTS[@]}" "$host" "RIG_LOCK_PARENT_ACTOR=$(quote_arg "${RIG_LOCK_PARENT_ACTOR:-}") RIG_LOCK_PARENT_NONCE=$(quote_arg "${RIG_LOCK_PARENT_NONCE:-}") RIG_LOCK_FILE=$(quote_arg "${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}") RIG_LOCK_HOLDER=$(quote_arg "${RIG_LOCK_HOLDER:-/run/rig-e2e.holder}") bash -s" || {
        warn "parent-held lock continuity failed on $host before $phase"
        return 1
    }
    step "parent-held lock verified on $host before $phase"
}

parent_lock_miner_borrow() {
    if [ -n "${RIG_LOCK_PARENT_ACTOR:-}" ] || [ -n "${RIG_LOCK_PARENT_NONCE:-}" ]; then
        parent_lock_checkpoint "loaner borrow" "$MINER_HOST" || return 1
        ok "parent rig lock verified on $MINER_HOST (loaner)"
    else
        rig_lock_remote pithead "e2e.sh loaner-borrow" "" "$MINER_HOST" "${SSH_OPTS[@]}"
        ok "rig lock held on $MINER_HOST (loaner) for the life of this run"
    fi
}

parent_lock_miner_restore() {
    [ "$BORROW_MINER" = 1 ] && { [ -n "${RIG_LOCK_PARENT_ACTOR:-}" ] || [ -n "${RIG_LOCK_PARENT_NONCE:-}" ]; } || return 0
    parent_lock_checkpoint "miner restore" "$MINER_HOST"
}
