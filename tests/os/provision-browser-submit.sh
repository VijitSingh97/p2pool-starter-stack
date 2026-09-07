# shellcheck shell=bash
#
# The browser-shaped wizard submit for phase_provision (#1846). Sourced by tests/os/run.sh.
# What a person's browser sends is not the no-JS field form: wizard.mjs takes the page's own
# served config (/api/wizard-state .config — the reference merged with the last attempt), sets the
# operator's answers on the same paths the page uses, and POSTs it whole as `config=<JSON>`
# beside `auth_mode=auto` (the recommended "generate a strong password for me"). The old leg
# posted `monero_wallet=…&pool=…`, which build_config() turns into a config server-side, so the
# path the operator actually took — and the one that refused on Both — never ran through the
# gate. A sibling, not rows in run.sh, which sits at its 3423-line ceiling.
#
# $1 ip, $2 authenticated cookie jar, then any extra form fields (`disk=vda`, `wipe=data` — the
# installer's disk half rides beside the config) -> prints the HTTP status of /submit (or a short
# reason when the page never served a config), the same contract the inline curl had.
provision_browser_submit() { # <ip> <jar> [field=value]...
    local ip="$1" jar="$2" served cfg extra=()
    shift 2
    for f in "$@"; do extra+=(--data-urlencode "$f"); done
    # A few reads, the way a person waits for the page: one cold read at -m 5 is not a verdict.
    # When none serves a config, the reason prints what the helper saw — status, curl's rc, the
    # head of the body — so the log discriminates a refusal from a timeout from a non-JSON page (#1932).
    local raw="" http="" crc=0 tries=0
    while [ "$tries" -lt 6 ]; do
        raw=$(curl -sSk -b "$jar" -m 5 -w '\n%{http_code}' "https://$ip/api/wizard-state" 2>/dev/null)
        crc=$?
        http=${raw##*$'\n'}
        raw=${raw%$'\n'*}
        served=$(printf '%s' "$raw" | jq -c '.config // empty' 2>/dev/null)
        [ -n "$served" ] && break
        tries=$((tries + 1))
        sleep 5
    done
    [ -n "$served" ] || {
        printf 'no-served-config(http=%s curl=%s after %sx5s body=%s)' "${http:-none}" "$crc" "$tries" \
            "$(printf '%s' "$raw" | head -c 60 | tr -c '[:print:]' '?')"
        return 1
    }
    # The four answers the Both role gives on the page, on the page's own paths (wizard.mjs
    # FIELDS: monero.wallet_address, tari.wallet_address, p2pool.pool, local_miner.enabled).
    cfg=$(printf '%s' "$served" | jq -c --arg m "$HARNESS_WALLET" --arg t "$HARNESS_TARI" \
        '.monero.wallet_address = $m | .monero.mode = "local" | .tari.wallet_address = $t |
         .tari.mode = "local" | .p2pool.pool = "mini" | .local_miner.enabled = true') || {
        printf 'jq-failed'
        return 1
    }
    curl -sSk -b "$jar" --data-urlencode "config=$cfg" --data-urlencode "auth_mode=auto" "${extra[@]}" \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null
}

# The page's own error line, for a red that names the refusal instead of a timeout. Empty when
# the page shows none (or cannot be reached).
provision_page_error() { # <ip> <jar>
    curl -sSk -b "$2" -m 5 "https://$1/api/wizard-state" 2>/dev/null | jq -r '.error // ""' 2>/dev/null
}

failed_install_state_retained() { # <wizard-state-json> <expected-wallet>
    printf '%s' "$1" | jq -e --arg m "$2" '
        .stage == "failed" and .error != null and .error != "" and
        .config.monero.wallet_address == $m and .config.tari.remote.host == "unreachable.invalid"' >/dev/null
}

# Exercise the failure the RC1 browser could not recover from before submitting the real config.
# The first attempt uses a syntactically valid but unresolvable remote node, waits for the host's
# terminal failure, proves the page retained the safe answers, then reopens those settings. The
# caller's normal provision_browser_submit replaces the node choice with local and continues.
provision_failed_install_recovery() { # <ip> <authenticated-cookie-jar>
    local ip="$1" jar="$2" state cfg code handoff="" tries=0
    state=$(curl -fsSk -b "$jar" -m 5 "https://$ip/api/wizard-state" 2>/dev/null) || return 1
    cfg=$(printf '%s' "$state" | jq -c --arg m "$HARNESS_WALLET" --arg t "$HARNESS_TARI" '
        .config | .monero.wallet_address = $m | .tari.wallet_address = $t |
        .tari.mode = "remote" | .tari.remote.host = "unreachable.invalid" |
        .tari.remote.grpc_port = 18142 | .p2pool.pool = "mini" | .local_miner.enabled = true') || return 1
    code=$(curl -sSk -b "$jar" --data-urlencode "config=$cfg" --data-urlencode "auth_mode=auto" \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$code" = "200" ] || return 1
    while [ "$tries" -lt 24 ]; do
        handoff=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        printf '%s' "$handoff" | jq -e '.password' >/dev/null 2>&1 && break
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] || return 1
    curl -fsSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null || return 1
    tries=0
    while [ "$tries" -lt 48 ]; do
        state=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/wizard-state" 2>/dev/null)
        [ "$(printf '%s' "$state" | jq -r '.stage // ""' 2>/dev/null)" = "failed" ] && break
        sleep 5
        tries=$((tries + 1))
    done
    if failed_install_state_retained "$state" "$HARNESS_WALLET"; then
        ok "failed setup returns a named error and retains the payout + node answers"
    else
        bad "failed setup did not return a recoverable retained form (state: $(printf '%s' "$state" | jq -c '{stage,error}' 2>/dev/null))"
        return 1
    fi
    code=$(curl -sSk -b "$jar" -X POST "https://$ip/retry" -o /dev/null -w '%{http_code}' 2>/dev/null)
    state=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/wizard-state" 2>/dev/null)
    if [ "$code" = "200" ] && printf '%s' "$state" | jq -e --arg m "$HARNESS_WALLET" '
        .stage == "setup" and .error == null and .config.monero.wallet_address == $m' >/dev/null; then
        ok "Back to the settings reopens the retained form for a corrected retry"
    else
        bad "failed setup could not reopen its retained settings (HTTP ${code:-none})"
        return 1
    fi
}

# POST a dashboard control request and follow the existing result endpoint through a dashboard
# restart. Preview's `previewed` is terminal; commit's is the old result waiting to be replaced.
dashboard_control_request() { # <route> <json-body> [deadline-seconds]
    local route="$1" body="$2" deadline=$(($(date +%s) + ${3:-240})) out rid status
    out=$(curl -sSk -m 8 -u "$DASH_USER:$DASH_PASS" -H 'Content-Type: application/json' \
        -H 'X-Pithead-Control: 1' --data "$body" "https://$ip/api/control/$route" 2>/dev/null)
    rid=$(printf '%s' "$out" | jq -r '.id // ""' 2>/dev/null)
    [ -n "$rid" ] || return 1
    while [ "$(date +%s)" -lt "$deadline" ]; do
        status=$(printf '%s' "$out" | jq -r '.status // "pending"' 2>/dev/null) || status=pending
        case "$status" in
        pending | running | downloading | installing | "") ;;
        previewed) [ "$route" = preview ] && {
            printf '%s' "$out"
            return 0
        } ;;
        *)
            printf '%s' "$out"
            return 0
            ;;
        esac
        sleep 3
        out=$(curl -sSk -m 8 -u "$DASH_USER:$DASH_PASS" "https://$ip/api/control/result?id=$rid" 2>/dev/null)
    done
    return 1
}

phase_provision_control_regressions() { # <dashboard-user> <dashboard-password>
    local DASH_USER="$1" DASH_PASS="$2" live proposed preview result rid old peers code names archive
    live=$(curl -fsSk -m 8 -u "$DASH_USER:$DASH_PASS" "https://$ip/api/config" 2>/dev/null) || {
        bad "post-provision control: live config could not be read"
        return
    }

    proposed=$(printf '%s' "$live" | jq -c '.dashboard.energy.cost_per_kwh = 0.17')
    preview=$(dashboard_control_request preview "$(jq -nc --argjson config "$proposed" '{config:$config}')")
    if printf '%s' "$preview" | jq -e '.status == "previewed" and .destructive == false and any(.changes[]; .flag == "INFO")' >/dev/null; then
        ok "post-provision benign setting previews as an ordinary committable change"
    else
        bad "post-provision benign setting did not produce an INFO preview"
        return
    fi
    rid=$(printf '%s' "$preview" | jq -r '.id')
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id}')")
    if printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null &&
        curl -fsSk -m 8 -u "$DASH_USER:$DASH_PASS" "https://$ip/api/config" 2>/dev/null |
        jq -e '.dashboard.energy.cost_per_kwh == 0.17' >/dev/null; then
        ok "post-provision benign setting applies through the dashboard control runner"
    else
        bad "post-provision benign setting did not land"
        return
    fi

    live=$(curl -fsSk -m 8 -u "$DASH_USER:$DASH_PASS" "https://$ip/api/config" 2>/dev/null) || return
    old=$(printf '%s' "$live" | jq -r '.monero.out_peers // 48')
    [ "$old" -lt 1024 ] && peers=$((old + 1)) || peers=$((old - 1))
    proposed=$(printf '%s' "$live" | jq -c --argjson peers "$peers" '.monero.out_peers = $peers')
    preview=$(dashboard_control_request preview "$(jq -nc --argjson config "$proposed" '{config:$config}')")
    if printf '%s' "$preview" | jq -e '.status == "previewed" and .destructive == true and any(.changes[]; .flag == "CONFIRM")' >/dev/null; then
        ok "post-provision disruptive setting previews behind typed approval"
    else
        bad "post-provision disruptive setting was not classified CONFIRM"
        return
    fi
    rid=$(printf '%s' "$preview" | jq -r '.id')
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id}')")
    if printf '%s' "$result" | jq -e '.status == "rejected" and (.error | contains("type APPLY"))' >/dev/null; then
        ok "post-provision disruptive apply is refused without the typed approval"
    else
        bad "post-provision disruptive apply crossed the approval gate without APPLY"
        return
    fi
    preview=$(dashboard_control_request preview "$(jq -nc --argjson config "$proposed" '{config:$config}')")
    rid=$(printf '%s' "$preview" | jq -r '.id')
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,confirm:"APPLY"}')")
    if printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null &&
        curl -fsSk -m 8 -u "$DASH_USER:$DASH_PASS" "https://$ip/api/config" 2>/dev/null |
        jq -e --argjson peers "$peers" '.monero.out_peers == $peers' >/dev/null; then
        ok "post-provision disruptive setting applies with typed approval"
    else
        bad "post-provision approved setting did not land"
        return
    fi

    proposed=$(curl -fsSk -m 8 -u "$DASH_USER:$DASH_PASS" "https://$ip/api/config" 2>/dev/null |
        jq -c --argjson old "$old" '.monero.out_peers = $old')
    preview=$(dashboard_control_request preview "$(jq -nc --argjson config "$proposed" '{config:$config}')")
    rid=$(printf '%s' "$preview" | jq -r '.id')
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,confirm:"APPLY"}')")
    printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null || bad "post-provision approved-setting cleanup failed"

    result=$(dashboard_control_request diag-doctor '{}')
    if printf '%s' "$result" | jq -e '.status == "applied" and (.doctor.checks | type == "array")' >/dev/null; then
        ok "doctor completes through the dashboard control runner"
    else
        bad "doctor did not return a report through the control runner"
    fi
    result=$(dashboard_control_request diag-logs '{"container":"dashboard","lines":20}')
    if printf '%s' "$result" | jq -e '.status == "applied" and .container == "dashboard" and (has("lines") or has("note"))' >/dev/null; then
        ok "dashboard log tail completes through the control runner"
    else
        bad "dashboard log tail did not return through the control runner"
    fi

    result=$(dashboard_control_request backup '{}' 360)
    rid=$(printf '%s' "$result" | jq -r '.id // ""')
    archive=$(mktemp)
    code=$(curl -sSk -m 30 -u "$DASH_USER:$DASH_PASS" -o "$archive" -w '%{http_code}' \
        "https://$ip/api/control/backup-download?id=$rid" 2>/dev/null)
    if printf '%s' "$result" | jq -e '.status == "applied" and (.passphrase | length > 0) and (.archive | length > 0)' >/dev/null &&
        [ "$code" = "200" ] && [ -s "$archive" ]; then
        ok "dashboard backup returns its encrypted archive and one-time passphrase"
    else
        bad "dashboard backup did not produce a downloadable encrypted archive"
    fi
    rm -f "$archive"
    names=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
    code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
    case "$names:$code" in
    *dashboard*caddy*:2?? | *dashboard*caddy*:3?? | *dashboard*caddy*:401 | *dashboard*caddy*:403 | \
        *caddy*dashboard*:2?? | *caddy*dashboard*:3?? | *caddy*dashboard*:401 | *caddy*dashboard*:403)
        ok "stack and dashboard recover after the dashboard-driven backup (HTTP $code)"
        ;;
    *) bad "stack/dashboard did not recover after backup (running: ${names:-none}; HTTP ${code:-none})" ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--self-test" ]; then
    good='{"stage":"failed","error":"node unavailable","config":{"monero":{"wallet_address":"wallet"},"tari":{"remote":{"host":"unreachable.invalid"}}}}'
    failed_install_state_retained "$good" wallet || exit 1
    failed_install_state_retained "${good/\"failed\"/\"installing\"}" wallet && exit 1
    failed_install_state_retained "${good/\"wallet\"/\"lost\"}" wallet && exit 1
    echo "provision-browser-submit self-test: recovery verdict and failure controls passed"
fi
