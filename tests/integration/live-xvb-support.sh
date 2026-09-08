# shellcheck shell=bash
# Exact restoration and isolated-client helpers for the bounded live XvB smoke.

restore_xvb_original() {
    local baseline_tor=true
    [ "$(jq_get "$BASELINE_CONFIG" '.xvb.tor')" = false ] && baseline_tor=false
    push_config "$BASELINE_CONFIG" >/dev/null 2>&1 &&
        strict_pithead apply -y >/dev/null 2>&1 && wait_status_ok 240 &&
        [ "$(rx 'cat config.json' 2>/dev/null)" = "$BASELINE_CONFIG" ] &&
        [ "$(upgrade_secret_fingerprints)" = "$_XVB_SECRET_FP_BEFORE" ] &&
        [ "$(env_on_box XVB_ENABLED)" = true ] &&
        [ "$(env_on_box XVB_TOR_ENABLED)" = "$baseline_tor" ] &&
        wait_for 120 5 "proxy to restore the exact P2Pool route" _pred_proxy_route P2POOL "$_XVB_P2POOL_URL" &&
        [ "$(proxy_active_route)" = "$_XVB_BASELINE_ROUTE" ] &&
        [ "$(worker_names)" = "$_XVB_BASELINE_WORKERS" ] &&
        [ "$(jq_get "$(api_state)" '.stratum.total_hashes')" -gt 0 ] 2>/dev/null || return 1
    [ "${_UPGRADE_RESTORE_ARMED:-0}" = 1 ] || _SAFETY_RESTORE_ARMED=0
}

strict_firewall_installed() {
    rx 'source ./pithead; if [ "$(container_engine)" = podman ]; then r=$(sudo -n nft list table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null) && grep -q "hook forward" <<<"$r" && grep -qw drop <<<"$r"; else sudo -n iptables -C FORWARD -j DOCKER-USER >/dev/null 2>&1 && r=$(sudo -n iptables -S DOCKER-USER 2>/dev/null) && grep -qF -- "$TOR_EGRESS_TAG" <<<"$r" && grep -q -- "-j DROP" <<<"$r"; fi'
}

_pred_hashes_advanced() {
    local now
    now="$(jq_get "$(api_state)" '.stratum.total_hashes')"
    [[ "$now" =~ ^[0-9]+$ ]] && [ "$now" -gt "$1" ]
}

strict_pithead() {
    local payload args="" arg
    for arg in "$@"; do printf -v args '%s %q' "$args" "$arg"; done
    payload="$(
        base64 <<'SH' | tr -d '\n'
source ./pithead
eval "$(declare -f apply_tor_egress_firewall | sed '1s/apply_tor_egress_firewall/original_apply_tor_egress_firewall/')"
apply_tor_egress_firewall() {
    original_apply_tor_egress_firewall
    if [ "$(container_engine)" = podman ]; then
        r=$(sudo -n nft list table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null) && grep -q 'hook forward' <<<"$r" && grep -qw drop <<<"$r"
    else
        sudo -n iptables -C FORWARD -j DOCKER-USER >/dev/null 2>&1 && r=$(sudo -n iptables -S DOCKER-USER 2>/dev/null) && grep -qF -- "$TOR_EGRESS_TAG" <<<"$r" && grep -q -- '-j DROP' <<<"$r"
    fi || error "Live gate refuses to start containers without the hooked Tor-egress DROP rules."
}
main "$@"
SH
    )"
    rx "printf %s $(quote_arg "$payload") | base64 -d | bash -s --$args"
}

restore_xvb_or_safety() {
    if restore_xvb_original; then
        _XVB_RESTORE_ARMED=0
        return 0
    fi
    # shellcheck disable=SC2034 # consumed by run.sh:safety_cleanup
    SAFETY_RESTORE_FAILED=1
    [ -n "$SAFETY_ARCHIVE" ] && safety_restore_exact && _XVB_RESTORE_ARMED=0
    return 1
}

xvb_abort_restore() {
    local original_rc=$? restore_failed=0
    if [ "$_XVB_RESTORE_ARMED" = "1" ]; then
        it_warn "aborted XvB smoke — restoring the exact original configuration"
        if ! restore_xvb_or_safety; then
            restore_failed=1
            it_warn "XvB abort restore failed; safety archive retained at ${SAFETY_ARCHIVE:-<none>}"
        fi
    fi
    [ -z "$_XVB_FOREIGN_TRAP" ] || eval "$_XVB_FOREIGN_TRAP"
    [ "$restore_failed" -eq 0 ] || exit 1
    return "$original_rc"
}

arm_xvb_abort_restore() {
    local cur
    cur="$(trap -p EXIT)"
    if [ -n "$cur" ]; then
        local -a parsed
        eval "parsed=($cur)"
        _XVB_FOREIGN_TRAP="${parsed[2]}"
    fi
    _XVB_RESTORE_ARMED=1
    trap xvb_abort_restore EXIT
}

trigger_dashboard_xvb_fetch() {
    local payload inner
    payload="$(base64 <"$HERE/xvb-egress-probe.py" | tr -d '\n')"
    inner="read -r MONERO_WALLET_ADDRESS; export MONERO_WALLET_ADDRESS; printf %s $(quote_arg "$payload") | base64 -d | python3 -"
    rx "net=pithead-xvb-probe-\$\$; cleanup() { docker network disconnect -f \"\$net\" tor >/dev/null 2>&1 || true; docker network rm \"\$net\" >/dev/null 2>&1 || true; }; trap cleanup EXIT; docker network create --internal \"\$net\" >/dev/null && docker network connect --alias tor \"\$net\" tor && wallet=\$(grep -E '^MONERO_WALLET_ADDRESS=' .env | head -n1 | cut -d= -f2-) && image=\$(docker inspect dashboard --format '{{.Config.Image}}') && [ -n \"\$wallet\" ] && [ -n \"\$image\" ] && printf '%s\\n' \"\$wallet\" | docker run --rm -i --network \"\$net\" -e TOR_SOCKS_PROXY=socks5h://tor:9050 --entrypoint sh \"\$image\" -c $(quote_arg "$inner") >/dev/null 2>&1"
}
