# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel confirm-gate domain (#1105 Phase 1, appliance lane): the sections that prove an
# in-scope disruptive change cannot land on a plain commit, and that the typed APPLY token which
# unlocks it is scoped to the change itself rather than to the perimeter. A disruptive edit staged
# without the token is held; the same edit with the typed APPLY applies; and with that token in
# hand a DEST-flagged perimeter change — clearnet exposure, a prune disable — is still refused
# (#719, with #713's refusal wording naming the host apply path rather than the stale #338).
# Sourced by tests/stack/run.sh.
#
# THIS FILE IS DELIBERATELY NOT STANDALONE-SOURCEABLE, AND THAT IS THE CORRECT CALL HERE.
# It follows the shipped add-only-ssrf disclosure precedent — source in place, position-locked,
# dependency disclosed here — rather than the self-arm pattern most domain files use. "It should
# self-arm like its neighbours" is the obvious review note and it is wrong for this domain:
#
# - This domain is a pure CONSUMER of the control sandbox. It never calls build_control_sandbox();
#   test-control-core.sh calls it once, in the control-core domain sourced ahead, and $C, $CTRL_LOG
#   and $WALLET reach here from it.
#   (That section lived in run.sh until #1105 R12 moved it into its own domain file.)
# - This domain is position-locked by what it READS, not by anything a second builder call would
#   overwrite. Calling build_control_sandbox() here would be harmless, and that is why it buys
#   nothing: $C is the fixed path "$SANDBOX/control", its mkdir -p only creates, its copies are
#   static inputs, and seed_control_env/control_config are DEFINED inside it and never called — so
#   the builder writes no config.json and touches nothing under data/control/{requests,staged,
#   results,audit}. It could not establish the state this domain depends on, only running in
#   position after the sections that accumulate it can.
#   This domain drives the control channel repeatedly through `pithead apply -y` and run_pending
#   against the shared spool, and it opens by establishing a clean applied baseline that its own
#   later assertions and the sections after it read back.
#   The coupling that DOES bite here is write-side, and it has a recorded firing: the rig-worker
#   token-mask cluster moved with a re-derived $C, its applies wrote EXTRA result files into the
#   shared results dir, and a still-in-run.sh assertion counting that dir went red. That is
#   pollution of a counted directory — a different mechanism from anything being reset.
#   RETRACTED (#1105 R12): that firing's stated MECHANISM does not reproduce at the tip — the
#   apply path writes nothing into results/ unless is_appliance(), which no sandbox run
#   satisfies. The RED was real; WHY is not established, and the full re-derivation is in
#   test-rig-worker.sh's header. This domain's position-lock rests on what it READS, not on it.
#
# Re-derivations, audited over this WHOLE file, this header included. The audit script is
# lane-local and is NOT in this repo, so nothing below rests on it: each claim is written to be
# re-derived here with git and grep alone, and should be treated as a claim to check.
# - $REQS, $RESULTS, $STAGED and $AUDIT are NOT the builder's. They are assigned by the
#   control-run-pending section, in test-control-core.sh, sourced before this stanza — an ordering
#   dependency, same class as any other. They are deliberately NOT seeded here: each is a plain
#   derivation from $C, so a seed would duplicate that file's definitions and could drift from them,
#   and it would buy nothing, because $C itself keeps this file non-standalone either way.
# - $WALLET is NOT a top-level constant, and getting that right matters here. lib.sh assigns it
#   only INSIDE the two sandbox builders, as WALLET="${WALLET:-$VALID_PRIMARY}", and run.sh never
#   assigns it at all — so $WALLET reaches this domain from the same build_control_sandbox call
#   that provides $C, by the same ordering dependency, and belongs in the disclosure above rather
#   than filed as a constant. A defaulting fix retires a coupling only for CALLERS, and a split
#   manufactures non-callers.
# - $VALID_TARI is a lib.sh top-level constant, assigned at column one outside every function.
# - THE DEPENDENCY IS ALSO IN FUNCTION FORM, not only in variables. control_config() is not a
#   top-level lib.sh function: it is defined INSIDE build_control_sandbox(), so it does not exist
#   until that builder has run. This domain calls it, which is a second, independent reason the
#   file cannot stand alone — and one a variable-only sweep cannot see. The other provider
#   functions it calls are top-level: assert_eq, assert_contains, run_pending, and ok/bad beneath
#   the assertions. It does NOT call seed_env or seed_control_env.
# - preview_clearnet() is defined in the moved text and is not unset at its end, so it outlives
#   the source exactly as it outlived its old position in run.sh. No other file under tests/stack/
#   uses that name, so nothing downstream can see a definition it did not see before.
# - $UUID3 is assigned HERE, in the moved text. It is READ BY test-data-management.sh, whose
#   stanza run.sh sources immediately after this one — a dependency this split creates, disclosed
#   on both sides and guarded there.
#
# The source stanza sits at this block's own vacated position, so every assertion runs in the
# order it always ran, and the applied baseline this domain leaves behind still reaches the
# sections that follow it. The anchor is a correctness requirement in this cut, not a preference.
#
# The guard below is the ambient contract made executable: sourced out of position, this file
# stops on a named variable instead of degrading into assertions against an unbuilt sandbox.
: "${C:?}" "${CTRL_LOG:?}" "${WALLET:?}" "${VALID_TARI:?}" "${REQS:?}" "${RESULTS:?}" "${STAGED:?}" "${AUDIT:?}"

echo "== black-box: confirm-gate — an in-scope disruptive change needs a typed APPLY (#719) =="
assert_eq "reference default enables XvB" "$(jq -r '.xvb.enabled' "$ROOT/config.reference.json")" "true"
assert_eq "a config without xvb.enabled renders the same enabled state" "$(grep '^XVB_ENABLED=' "$C/.env" | cut -d= -f2-)" "true"
UUID3="33333333-3333-4333-8333-333333333333"
# Clean baseline: pool mini, clearnet off, applied.
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
# Candidate turns on Monero clearnet initial sync — describe_change flags this CONFIRM (#719): an
# in-scope disruptive change (host IP exposed during IBD), confirm-gated rather than host-only DEST.
preview_clearnet() {
    jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
        monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",clearnet_initial_sync:true},
        tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
        dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
    run_pending >/dev/null
}
preview_clearnet
assert_eq "confirm-gated candidate previews destructive:true" "$(jq -r '.destructive' "$RESULTS/$UUID3.json" 2>/dev/null)" "true"
assert_contains "confirm-gated preview carries a CONFIRM row" "$(jq -r '.changes[].flag' "$RESULTS/$UUID3.json" 2>/dev/null)" "CONFIRM"
# Commit WITHOUT the typed confirmation is refused — and points at the confirm step, NOT a flat
# host-only #338 refusal. The in-scope change is NOT hard-refused; it just needs the acknowledgement.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit without a token is refused" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_contains "refusal asks for the typed APPLY" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "type APPLY"
assert_eq "unconfirmed commit did not touch config.json" "$(jq -r '.monero.clearnet_initial_sync // false' "$C/config.json")" "false"
# A WRONG token is refused too — only the exact literal proceeds.
preview_clearnet
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"apply"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit with the wrong token is refused" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_eq "wrong-token commit did not touch config.json" "$(jq -r '.monero.clearnet_initial_sync // false' "$C/config.json")" "false"
# Commit WITH the exact typed APPLY proceeds and lands the change.
preview_clearnet
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit with APPLY applies" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "applied"
assert_eq "confirmed change landed in config.json" "$(jq -r '.monero.clearnet_initial_sync' "$C/config.json")" "true"
# The audit log records it AS a dashboard-confirmed destructive change (#719): the distinct
# commit-confirmed action, carrying the changed key NAME (never a value).
assert_contains "confirmed commit audits as commit-confirmed with the key name" \
    "$(grep '"action":"commit-confirmed","status":"applied"' "$AUDIT" | tail -n 1)" "monero.clearnet_initial_sync"

echo "== black-box: sensitive changes need the authenticated approval envelope (#1959) =="
# Type-to-confirm alone is still only friction. A sensitive RPC exposure is refused without an
# envelope bound to this preview and actor, then accepted with the real envelope.
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",rpc_lan_access:true},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "sensitive RPC-LAN change refuses typed APPLY without approval" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_contains "sensitive refusal names approval" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "Telegram approval"
assert_eq "unapproved perimeter change did not touch config.json" "$(jq -r '.monero.rpc_lan_access // false' "$C/config.json")" "false"
# Re-preview because every refused commit consumes its staged copy, then carry the server-shaped
# envelope. A forged actor is rejected; the matching authenticated actor applies.
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",rpc_lan_access:true},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
jq -n --arg id "$UUID3" '{id:$id,action:"commit",actor:"admin",confirm:"APPLY",approval:{preview_id:$id,actor:"mallory",approver:"tg-7",payout_suffixes:{}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "approval actor cannot be forged" "$(jq -r '.status' "$RESULTS/$UUID3.json")" "rejected"
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",rpc_lan_access:true},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
jq -n --arg id "$UUID3" '{id:$id,action:"commit",actor:"admin",confirm:"APPLY",approval:{preview_id:$id,actor:"admin",approver:"tg-7",payout_suffixes:{}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "matching approval envelope applies sensitive change" "$(jq -r '.status' "$RESULTS/$UUID3.json")" "applied"
assert_eq "approved perimeter change landed" "$(jq -r '.monero.rpc_lan_access' "$C/config.json")" "true"
assert_contains "approved change records actor and approved action" "$(grep '"action":"commit-approved","status":"applied"' "$AUDIT" | tail -n 1)" '"actor":"admin"'

# An existing worker descriptor is no longer a hidden host-only exception: the JSON pane can
# repoint it, but only through the same approval identity, and the audit names the schema path.
jq '.workers={api_port:8080,api_auth:"none",api_token:"",list:[{name:"rig-1",host:"192.168.1.50",control_port:8082,token:"rig-token"}]}' "$C/config.json" >"$C/config.worker" && mv "$C/config.worker" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq -n --slurpfile live "$C/config.json" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:($live[0] | .workers.list[0].host="192.168.1.51")}' >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "worker repoint preview requires approval" "$(jq -r '.approval_required' "$RESULTS/$UUID3.json")" "true"
assert_contains "worker repoint preview names its schema path" "$(jq -r '.changes[].key' "$RESULTS/$UUID3.json")" "workers.list"
jq -n --arg id "$UUID3" '{id:$id,action:"commit",actor:"admin",approval:{preview_id:$id,actor:"admin",approver:"tg-7",payout_suffixes:{}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "approved worker repoint applies" "$(jq -r '.status' "$RESULTS/$UUID3.json")" "applied"
assert_eq "approved worker host landed" "$(jq -r '.workers.list[0].host' "$C/config.json")" "192.168.1.51"
assert_contains "worker repoint audit names workers.list" "$(grep '"action":"commit-approved","status":"applied"' "$AUDIT" | tail -n 1)" "workers.list"

# A confirm-key in its heavy direction (prune disable) is now approval-gated too: it still needs
# typed APPLY, but is no longer impossible for a shell-less appliance operator.
jq -n --arg w "$WALLET" '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",prune:true},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",prune:false},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
jq -n --arg id "$UUID3" '{id:$id,action:"commit",actor:"admin",confirm:"APPLY",approval:{preview_id:$id,actor:"admin",approver:"tg-7",payout_suffixes:{}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "approved prune disable applies" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "applied"
assert_eq "approved prune disable landed" "$(jq -r '.monero.prune' "$C/config.json")" "false"
[ ! -f "$STAGED/$UUID3.json" ] && ok "approved destructive intent cleared from staged" || bad "approved destructive intent cleared from staged" "still staged"

echo "== black-box: payout approval previews full addresses and binds the typed suffix (#1959) =="
NEW_WALLET="44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
NEW_WALLET_SUFFIX="${NEW_WALLET: -8}"
jq -n --arg old "$WALLET" --arg new "$NEW_WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$new,node_username:"u",node_password:"p",prune:false},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "payout preview marks approval required" "$(jq -r '.approval_required' "$RESULTS/$UUID3.json")" "true"
assert_eq "payout preview old value is complete" "$(jq -r '.preview_values[] | select(.key=="monero.wallet_address") | .old' "$RESULTS/$UUID3.json")" "$WALLET"
assert_eq "payout preview new value is complete" "$(jq -r '.preview_values[] | select(.key=="monero.wallet_address") | .new' "$RESULTS/$UUID3.json")" "$NEW_WALLET"
jq -n --arg id "$UUID3" '{id:$id,action:"commit",actor:"admin",confirm:"APPLY",approval:{preview_id:$id,actor:"admin",approver:"tg-7",payout_suffixes:{monero:"wrong"}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "wrong payout suffix is refused" "$(jq -r '.status' "$RESULTS/$UUID3.json")" "rejected"
assert_eq "wrong payout suffix changed no funds destination" "$(jq -r '.monero.wallet_address' "$C/config.json")" "$WALLET"
jq -n --arg new "$NEW_WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$new,node_username:"u",node_password:"p",prune:false},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
jq -n --arg id "$UUID3" --arg suffix "$NEW_WALLET_SUFFIX" '{id:$id,action:"commit",actor:"admin",confirm:"APPLY",approval:{preview_id:$id,actor:"admin",approver:"tg-7",payout_suffixes:{monero:$suffix}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "matching payout suffix applies" "$(jq -r '.status' "$RESULTS/$UUID3.json")" "applied"
assert_eq "approved payout destination landed" "$(jq -r '.monero.wallet_address' "$C/config.json")" "$NEW_WALLET"

echo "== black-box: approval never crosses the media-only boundary (#1959) =="
jq -n --arg w "$NEW_WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",prune:false},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"replacement-password"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
jq -n --arg id "$UUID3" '{id:$id,action:"commit",actor:"admin",confirm:"APPLY",approval:{preview_id:$id,actor:"admin",approver:"tg-7",payout_suffixes:{}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "dashboard password stays physical-presence-only despite approval" "$(jq -r '.status' "$RESULTS/$UUID3.json")" "rejected"
assert_contains "media-only refusal names the configuration stick" "$(jq -r '.error' "$RESULTS/$UUID3.json")" "configuration stick"
assert_eq "refused approval did not change dashboard password" "$(jq -r '.dashboard.auth.password' "$C/config.json")" "a control passphrase"

echo "== unit: setup-wizard provenance marker is consumed only after durable audit (#1962) =="
mk_tmpdir PROV
touch "$PROV/setup-wizard"
if (
    cd "$PROV" || exit
    source "$STACK"
    control_audit_provisioned() { return 1; }
    control_consume_provisioning_marker "$PROV/setup-wizard"
); then
    bad "audit failure is reported" "returned success"
else
    ok "audit failure is reported"
fi
[ -f "$PROV/setup-wizard" ] && ok "audit failure retains installer provenance marker" ||
    bad "audit failure retains installer provenance marker" "marker was deleted"
(
    cd "$PROV" || exit
    source "$STACK"
    control_audit_provisioned() { printf 'recorded\n' >"$PROV/audit-call"; }
    control_consume_provisioning_marker "$PROV/setup-wizard"
)
[ -f "$PROV/audit-call" ] && ok "successful target setup records wizard provenance" ||
    bad "successful target setup records wizard provenance" "audit was not called"
[ ! -f "$PROV/setup-wizard" ] && ok "successful audit consumes installer provenance marker" ||
    bad "successful audit consumes installer provenance marker" "marker remains"
assert_contains "installer stages explicit provenance for the target" "$(grep 'install -m 600 /dev/null /boot/efi/pithead-setup-wizard' "$ROOT/lib/pithead/12-firstboot-wizard.sh")" "pithead-setup-wizard"
assert_contains "direct wizard success records provenance" "$(grep 'control_audit_provisioned.*PWD/data/control' "$ROOT/lib/pithead/12-firstboot-wizard.sh")" "control_audit_provisioned"
rm -rf "$PROV"
unset PROV
