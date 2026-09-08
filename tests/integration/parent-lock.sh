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

parent_lock_checkpoint() { # <phase>; e2e-side remote verification
    local phase="$1"
    [ -n "${RIG_LOCK_PARENT_ACTOR:-}" ] || [ -n "${RIG_LOCK_PARENT_NONCE:-}" ] || return 0
    {
        declare -f rig_lock_parent_verify
        printf 'rig_lock_parent_verify\n'
    } |
        ssh "${SSH_OPTS[@]}" "$BENCH_HOST" "RIG_LOCK_PARENT_ACTOR=$(quote_arg "${RIG_LOCK_PARENT_ACTOR:-}") RIG_LOCK_PARENT_NONCE=$(quote_arg "${RIG_LOCK_PARENT_NONCE:-}") RIG_LOCK_FILE=$(quote_arg "${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}") RIG_LOCK_HOLDER=$(quote_arg "${RIG_LOCK_HOLDER:-/run/rig-e2e.holder}") bash -s" || {
        warn "parent-held bench lock continuity failed before $phase"
        return 1
    }
    step "parent-held bench lock verified before $phase"
}
