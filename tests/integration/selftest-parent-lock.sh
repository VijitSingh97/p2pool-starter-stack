#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export RIG_LOCK_FILE="$WORK/rig.lock"
export RIG_LOCK_HOLDER="$WORK/rig.holder"
export RIG_LOCK_PARENT_ACTOR=e2e-controller
export RIG_LOCK_PARENT_NONCE=0123456789abcdef0123456789abcdef

echo "== a real parent lock carries an exact, unspoofable identity =="
: >"$RIG_LOCK_FILE"
exec 9<"$RIG_LOCK_FILE"
flock -n -x 9
printf '%s nonce=%s parent continuity selftest\n' "$RIG_LOCK_PARENT_ACTOR" "$RIG_LOCK_PARENT_NONCE" >"$RIG_LOCK_HOLDER"
assert_eq "lock is a regular non-symlink file" "$([ -f "$RIG_LOCK_FILE" ] && [ ! -L "$RIG_LOCK_FILE" ] && echo yes)" yes
assert_eq "holder is a regular non-symlink file" "$([ -f "$RIG_LOCK_HOLDER" ] && [ ! -L "$RIG_LOCK_HOLDER" ] && echo yes)" yes
assert_eq "holder's first fields are the exact actor and nonce" \
    "$(awk '{print $1, $2}' "$RIG_LOCK_HOLDER")" \
    "$RIG_LOCK_PARENT_ACTOR nonce=$RIG_LOCK_PARENT_NONCE"

flock -E 75 -n -x "$RIG_LOCK_FILE" -c true 2>/dev/null
busy_rc=$?
assert_rc "the held kernel flock reports the protocol's busy rc" "$busy_rc" 75
rig_lock_parent_verify
assert_rc "the matching parent identity verifies against the busy flock" "$?" 0

verify_fails() {
    rig_lock_parent_verify >/dev/null 2>&1
    [ "$?" -ne 0 ]
}

echo "== incomplete, malformed, and mismatched claims fail closed =="
saved_nonce="$RIG_LOCK_PARENT_NONCE"
unset RIG_LOCK_PARENT_NONCE
verify_fails
assert_rc "a half-set identity is refused" "$?" 0
RIG_LOCK_PARENT_NONCE=ABCDEF0123456789abcdef0123456789
verify_fails
assert_rc "a nonce outside 32 lowercase hex characters is refused" "$?" 0
RIG_LOCK_PARENT_NONCE="$saved_nonce"
printf 'another-controller nonce=%s pithead test\n' "$RIG_LOCK_PARENT_NONCE" >"$RIG_LOCK_HOLDER"
verify_fails
assert_rc "a different holder actor is refused" "$?" 0
printf '%s nonce=%s pithead test\n' "$RIG_LOCK_PARENT_ACTOR" "$RIG_LOCK_PARENT_NONCE" >"$RIG_LOCK_HOLDER"

mv "$RIG_LOCK_HOLDER" "$WORK/real-holder"
ln -s "$WORK/real-holder" "$RIG_LOCK_HOLDER"
verify_fails
assert_rc "a symlink holder is refused" "$?" 0
rm "$RIG_LOCK_HOLDER"
mv "$WORK/real-holder" "$RIG_LOCK_HOLDER"

echo "== nested cleanup cannot erase its parent's holder =="
INT_DIR="$HERE" bash -c '
    source "$INT_DIR/lib.sh"
    source "$INT_DIR/rig-key-ledger.sh"
    _RIG_LOCK_PARENT_VERIFIED=1
    rig_key_mark dash rig DONATION 0
    rig_key_clear dash rig DONATION
'
assert_eq "the parent holder survives the child ledger EXIT trap" "$([ -f "$RIG_LOCK_HOLDER" ] && echo yes)" yes

echo "== a matching breadcrumb never substitutes for a held flock =="
exec 9>&-
mv "$RIG_LOCK_FILE" "$WORK/real-lock"
ln -s "$WORK/real-lock" "$RIG_LOCK_FILE"
verify_fails
assert_rc "a symlink lock is refused" "$?" 0
rm "$RIG_LOCK_FILE"
mv "$WORK/real-lock" "$RIG_LOCK_FILE"
verify_fails
assert_rc "a free lock is refused even when the holder still matches" "$?" 0

echo "== source wiring checks every mutating boundary =="
assert_eq "e2e checks both parent-held rigs at every mutating boundary" \
    "$(cat "$HERE/e2e.sh" "$HERE/parent-lock.sh" | grep -Ec 'parent_lock_checkpoint (restore|provision|deploy)|parent_lock_checkpoint "(the first bench touch|miner restore|loaner borrow)"')" 6
assert_contains "detached launch reads token and continuity identity from stdin" \
    "$(sed -n '/printf.*IT_RIG_TOKEN.*RIG_LOCK_PARENT_NONCE/p' "$HERE/e2e.sh")" \
    "printf '%s\\n%s\\n%s\\n'"
assert_contains "detached harness owns a process group that cleanup can drain" "$(cat "$HERE/e2e.sh")" 'nohup setsid ./.e2e-run.sh'
assert_contains "restoration drains an unfinished detached harness first" "$(sed -n '/restore_all()/,/parent_lock_checkpoint restore/p' "$HERE/e2e.sh")" 'drain_harness'
assert_contains "only the local nested runner can use parent-lock bypass" \
    "$(sed -n '/RIG_LOCK_PARENT_ACTOR/,/elif \[ "\$IT_MODE"/p' "$HERE/run.sh")" \
    'IT_MODE" = "local'
assert_contains "the child marks parent verification internally" "$(cat "$HERE/parent-lock.sh")" '_RIG_LOCK_PARENT_VERIFIED=1'

echo "selftest-parent-lock: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
