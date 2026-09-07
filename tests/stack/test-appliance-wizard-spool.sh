# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# One boundary suite: private creation, hostile directory entries, immutable consumption and
# the mixed ownership needed by the page's retry protocol. Full boot remains a KVM gate.
echo "== unit: wizard spool publication and snapshot boundary =="
mk_tmpdir WSS
mkdir "$WSS/spool"
printf sentinel >"$WSS/target"
ln -s "$WSS/target" "$WSS/spool/error.txt"
run_sourced "$WSS" wizard_spool_publish "$WSS/spool" error.txt printf '%s' fixture-secret
assert_rc "a planted output symlink is replaced atomically" "$?" 0
assert_eq "the output symlink target stays untouched" "$(cat "$WSS/target")" sentinel
assert_eq "the published error is private" "$(stat -c '%a' "$WSS/spool/error.txt")" 600
assert_eq "the page gets the error" "$(cat "$WSS/spool/error.txt")" fixture-secret
run_sourced "$WSS" eval 'producer() { [ "$(stat -Lc %a /proc/$BASHPID/fd/1)" = 600 ] || return 1; printf first-byte; }; umask 000; wizard_spool_publish "$WSS/spool" last-attempt.json producer'
assert_rc "the output inode is 600 before the first secret byte" "$?" 0
assert_eq "a successful producer is published" "$(cat "$WSS/spool/last-attempt.json")" first-byte
run_sourced "$WSS" eval 'producer() { printf partial; return 1; }; wizard_spool_publish "$WSS/spool" last-attempt.json producer'
assert_rc "a failed producer refuses publication" "$?" 1
assert_eq "producer failure keeps the previous complete output" "$(cat "$WSS/spool/last-attempt.json")" first-byte
for kind in symlink fifo directory hardlink; do
    case "$kind" in
    symlink) ln -s "$WSS/target" "$WSS/spool/request" ;;
    fifo) mkfifo "$WSS/spool/request" ;;
    directory) mkdir "$WSS/spool/request" ;;
    hardlink) ln "$WSS/target" "$WSS/spool/request" ;;
    esac
    run_sourced "$WSS" wizard_spool_read "$WSS/spool" request >/dev/null 2>&1
    assert_rc "$kind input is refused without reading it" "$?" 1
    if [ "$kind" = directory ]; then rmdir "$WSS/spool/request"; else rm -f "$WSS/spool/request"; fi
done
printf original >"$WSS/spool/request"
SNAP=$(run_sourced "$WSS" wizard_spool_snapshot "$WSS/spool" request)
printf replacement >"$WSS/spool/request"
assert_eq "in-place page writes cannot change a completed snapshot" "$(cat "$SNAP")" original
run_sourced "$WSS" wizard_spool_clean "${SNAP%/*}"
run_sourced "$WSS" wizard_spool_snapshot "$WSS/spool" request 2 >/dev/null
assert_rc "oversize requests are refused" "$?" 1
run_sourced "$WSS" eval 'ln() { command ln "$@"; rm -f "$WSS/spool/request"; command ln -s "$WSS/target" "$WSS/spool/request"; }; wizard_spool_read "$WSS/spool" request' >/dev/null
assert_rc "replacement during pinning fails closed" "$?" 1
assert_eq "replacement target is unchanged" "$(cat "$WSS/target")" sentinel
rm -f "$WSS/spool/request"
# Caller proof: the dial occurs between parsing and promotion. Change the original request at
# that point; every field that lands must still come from the private snapshot.
printf '{"pool":"example.test:3333","worker":"original","stratum_password":"fixture"}' >"$WSS/spool/rig-request.json"
run_sourced "$WSS" eval 'timeout() { printf "{}" >"$WSS/spool/rig-request.json"; }; firstboot_consume_rig "$WSS/spool"' >/dev/null
assert_rc "normal rig acceptance uses a snapshot" "$?" 0
assert_eq "request replacement cannot alter accepted worker/password" "$(jq -c '[.worker,.stratum_password]' "$WSS/rig.json")" '["original","fixture"]'
printf '{"fixture":true}' >"$WSS/spool/config.json"
run_sourced "$WSS" eval 'bash() { printf "{}" >"$WSS/spool/config.json"; }; firstboot_consume_spool "$WSS/spool"' >/dev/null
assert_rc "config acceptance promotes the validated snapshot" "$?" 0
assert_eq "the promoted config is the snapshot, not the replaced request" "$(jq -c . "$WSS/config.json")" '{"fixture":true}'
assert_eq "accepted config is private" "$(stat -c '%a' "$WSS/config.json")" 600
# A real UID boundary, not a mocked chown. CI's Linux runner supplies sudo and setpriv.
echo "== unit: wizard spool root and page ownership =="
if command -v setpriv >/dev/null && sudo -n true 2>/dev/null; then
    chmod 711 "$WSS"
    sudo bash -s -- "$STACK" "$WSS" <<'ROOTCHECK'
set -euo pipefail
source "$1"
spool="$2/root-spool"
prepare_wizard_spool "$spool"
page() { setpriv --reuid=1000 --regid=1000 --clear-groups "$@"; }
[ "$(stat -c '%u:%g:%a' "$spool")" = 0:1000:1770 ]
wizard_spool_publish "$spool" wizard.key printf fixture-key
[ "$(stat -c '%u:%g:%a' "$spool/wizard.key")" = 0:1000:640 ]
[ "$(page cat "$spool/wizard.key")" = fixture-key ]
! page rm -f "$spool/wizard.key" 2>/dev/null
! page sh -c 'printf altered >"$1"' _ "$spool/wizard.key" 2>/dev/null
for file in error.txt last-attempt.json installing; do
    wizard_spool_publish "$spool" "$file" printf retry-fixture
    [ "$(stat -c '%u:%g:%a' "$spool/$file")" = 1000:1000:600 ]
    page rm "$spool/$file"
    page sh -c 'umask 077; printf retry >"$1"' _ "$spool/$file"
    [ "$(wizard_spool_read "$spool" "$file")" = retry ]
done
# Positive control: the hostile symlink can redirect a naive root writer on this fixture.
printf sentinel >"$2/root-target"
page ln -s "$2/root-target" "$spool/error.txt.link"
printf unsafe-control >"$spool/error.txt.link"
[ "$(cat "$2/root-target")" = unsafe-control ]
printf sentinel >"$2/root-target"
page ln -s "$2/root-target" "$spool/last-attempt.json.link"
wizard_spool_publish "$spool" last-attempt.json.link printf protected
[ "$(cat "$2/root-target")" = sentinel ]
# The page attempts replacement while the producer is holding a private inode open.
producer() {
    local dir
    dir=$(find "$spool" -maxdepth 1 -name '.host.*' -type d)
    ! page sh -c 'printf attack >"$1/value"' _ "$dir" 2>/dev/null
    printf protected
}
wizard_spool_publish "$spool" handoff.json producer
[ "$(page cat "$spool/handoff.json")" = protected ]
# Remove only fixture files, then empty fixture directories.
find "$spool" -maxdepth 1 -type f -delete
find "$spool" -maxdepth 1 -type l -delete
rmdir "$spool"
rm "$2/root-target"
ROOTCHECK
    assert_rc "real root/page read, refusal, retry, replacement and fired control" "$?" 0
else
    bad "real root/page boundary requires sudo and setpriv" "not run"
fi
rm -rf "$WSS"
unset WSS SNAP
