# shellcheck shell=bash
HARNESS_PID=""
HARNESS_DONE=0

drain_harness() {
    [ -n "$HARNESS_PID" ] && [ "$HARNESS_DONE" = 0 ] || return 0
    warn "detached harness is still active; terminating and draining it before restoration"
    until on_bench "kill -TERM -- -'$HARNESS_PID' 2>/dev/null || true; i=0; while kill -0 -- -'$HARNESS_PID' 2>/dev/null && test \"\$i\" -lt 30; do sleep 1; i=\$((i + 1)); done; kill -KILL -- -'$HARNESS_PID' 2>/dev/null || true; while kill -0 -- -'$HARNESS_PID' 2>/dev/null; do sleep 1; done"; do
        warn "could not prove the detached harness stopped; retaining ownership and retrying"
        sleep 5
    done
    HARNESS_DONE=1
}

harness_finished() {
    until on_bench "! kill -0 -- -'$HARNESS_PID' 2>/dev/null"; do sleep 1; done
    HARNESS_DONE=1
}
