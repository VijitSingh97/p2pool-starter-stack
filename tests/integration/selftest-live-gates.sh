#!/usr/bin/env bash
# Small pure-logic check for live-gates.sh; no server required.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/live-gates.sh
source "$HERE/live-gates.sh"
# shellcheck source=tests/integration/live-safety-support.sh
source "$HERE/live-safety-support.sh"

if python3 "$HERE/xvb-egress-probe.py" --self-test; then
    it_pass "XvB socket guard self-test"
else
    it_fail "XvB socket guard self-test" "probe accepted non-Tor DNS or socket egress"
fi
if python3 "$HERE/migration-state-probe.py" --self-test; then
    it_pass "durable migration-state probe self-test"
else
    it_fail "durable migration-state probe self-test"
fi

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    printf '%s\n' '#!/bin/sh' \
        'if [ "$1 $2 $3" = "compose config --services" ]; then printf "tor\\np2pool\\nxmrig-proxy\\n"; exit 0; fi' \
        'if [ "$1 $2 $3" = "compose ps -q" ]; then echo cid; exit 0; fi' \
        'exit 125' >"$td/docker" && chmod +x "$td/docker"
    out="$(PATH="$td:$PATH" bash "$HERE/benchmarks/bench-verify-egress.sh" tor --dir "$td" --polls 1 --interval 0 2>&1)"
    rc=$?
    [ "$rc" = 2 ] && [[ "$out" == *INCONCLUSIVE* ]] && [[ "$out" != *"[verify-egress] OK"* ]]
); then
    it_pass "egress verifier fails inconclusive when live sockets are unreadable"
else
    it_fail "egress verifier fails inconclusive when live sockets are unreadable"
fi

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    printf '%s\n' '#!/usr/bin/env python3' 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' >"$td/setsid" && chmod +x "$td/setsid"
    : >"$td/heartbeat"
    PATH="$td:$PATH" bash "$HERE/live-supervised-run.sh" "$td/result" "$td/heartbeat" 60 bash -c 'exit 7'
    [ "$?" = 7 ] && [ "$(cat "$td/result")" = 7 ] || exit 1
    rm "$td/result"
    PATH="$td:$PATH" bash "$HERE/live-supervised-run.sh" "$td/result" "$td/heartbeat" 60 true
    [ "$?" = 0 ] && [ "$(cat "$td/result")" = 0 ]
); then
    it_pass "durable runner publishes fast zero and nonzero exit status"
else
    it_fail "durable runner publishes fast zero and nonzero exit status"
fi

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    printf '%s\n' '#!/usr/bin/env python3' 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' >"$td/setsid" && chmod +x "$td/setsid"
    : >"$td/heartbeat"
    PATH="$td:$PATH" bash "$HERE/live-supervised-run.sh" "$td/result" "$td/heartbeat" 1 bash -c 'trap "touch \"$1\"" EXIT; sleep 10' _ "$td/restored"
    [ "$?" = 124 ] && [ "$(cat "$td/result")" = 124 ] && [ -f "$td/restored" ]
); then
    it_pass "durable runner bounds the payload and lets its EXIT rollback finish"
else
    it_fail "durable runner bounds the payload and lets its EXIT rollback finish"
fi

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    mkdir "$td/bin"
    printf '%s\n' 'TOR_EGRESS_NFT_TABLE=pithead_egress' 'container_engine() { echo podman; }' 'apply_tor_egress_firewall() { :; }' \
        'error() { exit 1; }' 'main() { apply_tor_egress_firewall; printf "%s" "$1" > called; }' >"$td/pithead"
    printf '%s\n' '#!/bin/sh' 'shift' 'printf "hook forward priority -5; ip saddr 172.28.0.0/24 drop\n"' >"$td/bin/sudo"
    chmod +x "$td/bin/sudo"
    IT_REMOTE_DIR="$td" PATH="$td/bin:$PATH"
    rx() { (cd "$IT_REMOTE_DIR" && bash -c "$1"); }
    for cmd in apply up upgrade; do
        strict_pithead "$cmd" && [ "$(cat "$td/called")" = "$cmd" ] || exit 1
    done
); then
    it_pass "strict firewall wrapper dispatches apply, up, and upgrade"
else
    it_fail "strict firewall wrapper dispatches apply, up, and upgrade"
fi

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    printf '%s\n' '#!/bin/sh' \
        'if [ "$1 $2 $3" = "compose config --services" ]; then echo tor; exit 0; fi' \
        'if [ "$1 $2 $3" = "compose ps -q" ]; then echo cid; exit 0; fi' \
        'if [ "$1" = exec ]; then printf "  sl  local_address rem_address st\\n"; exit 0; fi' \
        'exit 125' >"$td/docker" && chmod +x "$td/docker"
    out="$(PATH="$td:$PATH" bash "$HERE/benchmarks/bench-verify-egress.sh" tor --dir "$td" --polls 1 --interval 0 2>&1)"
    rc=$?
    [ "$rc" = 2 ] && [[ "$out" == *INCONCLUSIVE* ]] && [[ "$out" != *"[verify-egress] OK"* ]]
); then
    it_pass "egress verifier rejects an empty app profile and idle Tor"
else
    it_fail "egress verifier rejects an empty app profile and idle Tor"
fi

echo "== image-upgrade continuity verdicts =="
OLD_SHA=0123456789abcdef0123456789abcdef01234567
valid_full_sha "$OLD_SHA" && it_pass "full commit accepted" || it_fail "full commit accepted"
revision_matches_sha 0123456789ab "$OLD_SHA" && it_fail "short image revision rejected" || it_pass "short image revision rejected"
revision_matches_sha 0123456-dirty "$OLD_SHA" && it_fail "dirty image revision rejected" || it_pass "dirty image revision rejected"
revision_matches_sha deadbee "$OLD_SHA" && it_fail "different image revision rejected" || it_pass "different image revision rejected"
height_continues 120 123 && it_pass "chain height may advance" || it_fail "chain height may advance"
height_continues 123 120 && it_fail "chain height may not regress" || it_pass "chain height may not regress"
chain_tip_valid "2840000 $(printf '%064d' 1)" && it_pass "direct Monero tip accepted" || it_fail "direct Monero tip accepted"
chain_tip_valid "0 $(printf '%064d' 1)" && it_fail "zero Monero tip rejected" || it_pass "zero Monero tip rejected"

fp_stub() { printf '%064d\n' 0; }
rx() { fp_stub; }
[ "$(upgrade_secret_fingerprints | wc -l | tr -d ' ')" = 6 ] && it_pass "six secret categories fingerprinted" || it_fail "six secret categories fingerprinted"
rx() { case "$1" in *TOR_DATA_DIR*) return 1 ;; *) fp_stub ;; esac }
upgrade_secret_fingerprints >/dev/null && it_fail "missing or unreadable onion member fails closed" || it_pass "missing or unreadable onion member fails closed"

revs="tor $OLD_SHA
p2pool $OLD_SHA
xmrig-proxy $OLD_SHA
dashboard $OLD_SHA"
revisions_match_sha "$revs" "$OLD_SHA" && it_pass "all required first-party revisions match" || it_fail "all required first-party revisions match"
revisions_match_sha "${revs/dashboard */dashboard deadbee}" "$OLD_SHA" && it_fail "one stale first-party revision fails" || it_pass "one stale first-party revision fails"

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    mkdir -p "$td/src/pithead" "$td/out" && printf ok >"$td/src/pithead/pithead" &&
        COPYFILE_DISABLE=1 tar -czf "$td/safe.tar.gz" -C "$td/src" pithead &&
        extract_candidate_archive "$td/safe.tar.gz" "$td/out" &&
        [ "$(cat "$td/out/pithead/pithead")" = ok ]
); then
    it_pass "candidate extraction accepts regular pithead members"
else
    it_fail "candidate extraction accepts regular pithead members"
fi
if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    mkdir -p "$td/src/pithead" "$td/out" && ln -s /tmp "$td/src/pithead/escape" &&
        COPYFILE_DISABLE=1 tar -czf "$td/unsafe.tar.gz" -C "$td/src" pithead &&
        extract_candidate_archive "$td/unsafe.tar.gz" "$td/out" >/dev/null 2>&1
); then
    it_fail "candidate extraction rejects links"
else
    it_pass "candidate extraction rejects links"
fi

refs="tor repo/tor@sha256:$(printf '%064d' 1)
monerod repo/monero@sha256:$(printf '%064d' 2)
p2pool repo/p2pool@sha256:$(printf '%064d' 3)
xmrig-proxy repo/xmrig@sha256:$(printf '%064d' 4)
dashboard repo/dashboard@sha256:$(printf '%064d' 5)"
pinned_refs_valid "$refs" && it_pass "all first-party refs are digest-pinned" || it_fail "all first-party refs are digest-pinned"
telemetry_rows_continue $'blocks -\nblocks aaa\ndisk_growth -' $'blocks -\nblocks aaa\nblocks bbb\ndisk_growth -' && it_pass "permanent telemetry rows continue" || it_fail "permanent telemetry rows continue"
telemetry_rows_continue $'blocks -\nblocks aaa' $'blocks -\nblocks bbb' && it_fail "telemetry row replacement fails" || it_pass "telemetry row replacement fails"

if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    IT_MODE=local IT_REMOTE_DIR="$td/current" UPGRADE_STAGE_DIR="$td/stage"
    rx() { [ "$1" = 'pwd -P' ] && (cd "$IT_REMOTE_DIR" && pwd -P); }
    mkdir -p "$td/pithead-v1.0.0/data/control" "$UPGRADE_STAGE_DIR/pithead"
    ln -s pithead-v1.0.0 "$td/current"
    printf old >"$td/pithead-v1.0.0/kept"
    printf '{}\n' >"$td/pithead-v1.0.0/config.json"
    printf 'SECRET=value\n' >"$td/pithead-v1.0.0/.env"
    printf audit >"$td/pithead-v1.0.0/data/control/audit"
    printf new >"$UPGRADE_STAGE_DIR/pithead/added"
    printf '2.0.0\n' >"$UPGRADE_STAGE_DIR/pithead/VERSION"
    prepare_candidate_install && [ "$(cat "$td/pithead-v1.0.0/kept")" = old ] && [ ! -e "$td/pithead-v2.0.0/kept" ] &&
        [ "$(cat "$td/pithead-v2.0.0/added")" = new ] && [ "$(cat "$td/pithead-v2.0.0/data/control/audit")" = audit ] &&
        [ "$IT_REMOTE_DIR" = "$(cd "$td/pithead-v2.0.0" && pwd -P)" ]
); then
    it_pass "upgrade staging leaves the immutable old version tree untouched"
else
    it_fail "upgrade staging leaves the immutable old version tree untouched"
fi

if (
    RUN_IMAGE_UPGRADE=0 RUN_XVB_ROUTING=1 SAFETY_BACKUP=0
    it_err() { :; }
    validate_live_gate_args
); then
    it_fail "XvB gate requires a safety backup"
else
    [ "$?" = 2 ] && it_pass "XvB gate requires a safety backup" || it_fail "XvB gate requires a safety backup"
fi

if (
    restore_calls=0 foreign_called=0
    restore_upgrade_baseline() {
        restore_calls=$((restore_calls + 1))
        _UPGRADE_RESTORE_ARMED=0
    }
    trap 'foreign_called=1' EXIT
    arm_upgrade_abort_restore
    upgrade_abort_restore
    _UPGRADE_FOREIGN_TRAP=""
    trap - EXIT
    [ "$restore_calls" -eq 1 ] && [ "$foreign_called" -eq 1 ]
); then
    it_pass "upgrade abort restores baseline and composes the prior EXIT handler"
else
    it_fail "upgrade abort restores baseline and composes the prior EXIT handler"
fi

if (
    restore_calls=0 foreign_called=0 SAFETY_ARCHIVE=archive
    safety_restore_exact() {
        restore_calls=$((restore_calls + 1))
        _SAFETY_RESTORE_ARMED=0
    }
    trap 'foreign_called=1' EXIT
    arm_safety_abort_restore
    safety_abort_restore
    _SAFETY_FOREIGN_TRAP=""
    trap - EXIT
    [ "$restore_calls" -eq 1 ] && [ "$foreign_called" -eq 1 ]
); then
    it_pass "run-level abort restores the safety archive and composes the lock trap"
else
    it_fail "run-level abort restores the safety archive and composes the lock trap"
fi

if (
    restore_calls=0 foreign_called=0 BASELINE_CONFIG='{}' _XVB_SECRET_FP_BEFORE=fp
    # shellcheck disable=SC2034 # live-gates writes this cross-module restoration marker
    SAFETY_ARCHIVE="" SAFETY_RESTORE_FAILED=0
    restore_xvb_or_safety() {
        restore_calls=$((restore_calls + 1))
        _XVB_RESTORE_ARMED=0
    }
    it_warn() { :; }
    rx() { printf '{}'; }
    upgrade_secret_fingerprints() { printf fp; }
    trap 'foreign_called=1' EXIT
    arm_xvb_abort_restore
    xvb_abort_restore
    _XVB_RESTORE_ARMED=0
    _XVB_FOREIGN_TRAP=""
    trap - EXIT
    [ "$restore_calls" -eq 1 ] && [ "$foreign_called" -eq 1 ]
); then
    it_pass "XvB abort restore composes the prior EXIT handler"
else
    it_fail "XvB abort restore composes the prior EXIT handler"
fi

[ "$IT_FAIL" -eq 0 ]
