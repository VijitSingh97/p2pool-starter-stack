# shellcheck shell=bash
HARNESS_PID=""
HARNESS_DONE=0
HARNESS_PENDING=0
HARNESS_STATE=""

harness_prepare() {
    HARNESS_STATE="$E2E_DIR/results/e2e-harness.$1.state"
    on_bench "mkdir -p '$E2E_DIR/results' && printf 'intent\\n' > '$HARNESS_STATE.tmp' && mv '$HARNESS_STATE.tmp' '$HARNESS_STATE'" || return 1
    HARNESS_PENDING=1
}

drain_harness() {
    local state i
    [ "$HARNESS_PENDING" = 1 ] && [ "$HARNESS_DONE" = 0 ] || return 0
    warn "detached harness is still active; terminating and draining it before restoration"
    if [ -z "$HARNESS_PID" ]; then
        for i in {1..10}; do
            state="$(on_bench "cat '$HARNESS_STATE'" 2>/dev/null)" || state=""
            [[ "$state" =~ ^running\ ([0-9]+)$ ]] && HARNESS_PID="${BASH_REMATCH[1]}" && break
            sleep 1
        done
        [ -n "$HARNESS_PID" ] || return 1
    fi
    until on_bench "sudo -n true || exit 1; if sudo -n kill -0 -- -'$HARNESS_PID' 2>/dev/null; then sudo -n kill -TERM -- -'$HARNESS_PID' || exit 1; fi; i=0; while sudo -n kill -0 -- -'$HARNESS_PID' 2>/dev/null && test \"\$i\" -lt 30; do sleep 1; i=\$((i + 1)); done; if sudo -n kill -0 -- -'$HARNESS_PID' 2>/dev/null; then sudo -n kill -KILL -- -'$HARNESS_PID' || exit 1; fi; ! sudo -n kill -0 -- -'$HARNESS_PID' 2>/dev/null"; do
        warn "could not prove the detached harness stopped; retaining ownership and retrying"
        sleep 5
    done
    HARNESS_DONE=1
}

drain_harness_or_refuse() {
    until drain_harness; do warn "harness launch state is uncertain; retaining ownership and retrying"; sleep 5; done
}

harness_finished() {
    until on_bench "sudo -n true && ! sudo -n kill -0 -- -'$HARNESS_PID' 2>/dev/null"; do sleep 1; done
    HARNESS_DONE=1
}
