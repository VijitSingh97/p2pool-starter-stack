#!/usr/bin/env bash
# Launch a destructive live gate in systemd so Actions cancellation cannot kill rollback.
set -uo pipefail
[ "${1:-}" = -- ] || {
    echo "usage: live-supervisor.sh -- command [args...]" >&2
    exit 2
}
shift
[ "$#" -gt 0 ] || exit 2
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_id="${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-0}"
[[ "$run_id" =~ ^[0-9]+-[0-9]+$ ]] || exit 2
unit="pithead-release-gate-$run_id"
result="$HERE/results/release-gate-supervisor-$run_id.done"
heartbeat="$HERE/results/release-gate-supervisor-$run_id.heartbeat"
mkdir -p "$HERE/results"
rm -f "$result" "$result.tmp" "$heartbeat"
: >"$heartbeat"
sudo -n systemd-run --quiet --collect --unit "$unit" \
    --property "User=$(id -un)" --property "Group=$(id -gn)" \
    --property "WorkingDirectory=$PWD" --property TimeoutStopSec=15min --property RuntimeMaxSec=4h20min \
    /bin/bash "$HERE/live-supervised-run.sh" "$result" "$heartbeat" 14400 "$@" || exit 1
while [ ! -f "$result" ]; do
    touch "$heartbeat"
    if ! sudo -n systemctl is-active --quiet "$unit"; then
        sleep 1
        [ -f "$result" ] || exit 1
    fi
    sleep 5
done
rm -f "$heartbeat"
rc="$(cat "$result")"
[[ "$rc" =~ ^[0-9]+$ ]] || exit 1
exit "$rc"
