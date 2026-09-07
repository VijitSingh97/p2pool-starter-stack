# Shared helpers for the control approval envelope and audit provenance (#1959/#1962).
control_changed_config_paths() { # <staged-file>
    jq -rn --slurpfile ref "$REFERENCE_CONFIG" --slurpfile live "$CONFIG_FILE" --slurpfile staged "$1" '
        def merged($x): $ref[0] * $x;
        def leaves($x): [$x | paths(scalars) | select(.[0:2] != ["workers", "list"])];
        (leaves(merged($live[0])) + leaves(merged($staged[0])) | unique)[] as $p
        | select((merged($live[0]) | getpath($p)) != (merged($staged[0]) | getpath($p)))
        | $p | map(tostring) | join(".")' 2>/dev/null
}

control_never_path_changed() { # <staged-file>
    local changed never
    while IFS= read -r changed; do
        [ -n "$changed" ] || continue
        for never in $CONTROL_DASHBOARD_NEVER_PATHS; do
            case "$changed" in "$never" | "$never".*) return 0 ;; esac
        done
    done < <(control_changed_config_paths "$1")
    return 1
}

control_telegram_approve() { # <staged-file> <id> <actor> <suffixes-json> <porcelain> <control-dir>
    local staged="$1" id="$2" actor="$3" suffixes="$4" porcelain="$5" cdir="$6"
    local token chat allowed confirm_s prefix socks nonce digest now deadline ratef count
    local pending payload response updates message_id poll_s uid offset="" text values changes tmp
    token=$(env_get TELEGRAM_BOT_TOKEN)
    chat=$(env_get TELEGRAM_CHAT_ID)
    allowed=$(env_get TELEGRAM_CONTROL_ALLOWED_IDS)
    confirm_s=$(env_get TELEGRAM_CONTROL_CONFIRM_S)
    printf '%s' "$token" | grep -qE '^[A-Za-z0-9:_-]+$' || {
        printf 'Telegram approval is unavailable because the bot token is not configured'
        return 1
    }
    [ -n "$chat" ] && [ -n "$allowed" ] || {
        printf 'Telegram approval is unavailable because its chat or operator allow-list is empty'
        return 1
    }
    printf '%s' "$confirm_s" | grep -qE '^[0-9]+([.][0-9]+)?$' || confirm_s=60
    confirm_s=${confirm_s%%.*}
    [ "$confirm_s" -ge 5 ] 2>/dev/null || confirm_s=60
    [ "$confirm_s" -le 300 ] 2>/dev/null || confirm_s=300

    # Apply the existing ten-prompts/hour budget globally at this host-owned gate. The dashboard
    # actor is audit context, not a rate-limit identity: a compromised spool writer could vary it.
    # The dashboard cannot reset or edit this file, and a refused/rate-limited attempt never prompts.
    now=$(date +%s)
    ratef="$cdir/audit/approval-prompts"
    tmp="${ratef}.tmp.$$"
    if [ -f "$ratef" ]; then
        (umask 077 && awk -v floor="$((now - 3600))" '$1 >= floor' "$ratef" >"$tmp") || return 1
    else
        (umask 077 && : >"$tmp") || return 1
    fi
    count=$(awk 'END {print NR+0}' "$tmp")
    if [ "$count" -ge 10 ]; then
        rm -f "$tmp"
        printf 'too many Telegram approval prompts recently — wait before trying again'
        return 1
    fi
    if ! { printf '%s %s\n' "$now" "$actor" >>"$tmp" && mv "$tmp" "$ratef"; }; then
        rm -f "$tmp"
        printf 'could not record the Telegram approval prompt budget — refusing the change'
        return 1
    fi

    nonce=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' || true)
    printf '%s' "$nonce" | grep -qE '^[0-9a-f]{32}$' || {
        printf 'could not create a one-time approval token — refusing the change'
        return 1
    }
    digest=$(sha256sum "$staged" 2>/dev/null | awk '{print $1}')
    [ -n "$digest" ] || return 1
    deadline=$((now + confirm_s))
    pending="$cdir/staged/.$id.approval-pending"
    payload="$cdir/staged/.$id.telegram-request"
    response="$cdir/staged/.$id.telegram-response"
    updates="$cdir/staged/.$id.telegram-updates"

    changes=$(printf '%s\n' "$porcelain" | jq -R -s '
        [split("\n")[] | select(length > 0) | split("\t")
         | {key:.[1], message:(.[2:] | join("\t"))} | select(.message != "")]') || return 1
    if ! jq -e --slurpfile live "$CONFIG_FILE" '(.workers.list // []) == ($live[0].workers.list // [])' "$staged" >/dev/null 2>&1; then
        tmp=$(jq -nr --slurpfile live "$CONFIG_FILE" --slurpfile staged "$staged" '
            def safe: map(del(.token) + {token:(if (.token // "") == "" then "not set" else "set (redacted)" end)});
            "Worker descriptors: " + (($live[0].workers.list // [] | safe) | tojson)
            + " → " + (($staged[0].workers.list // [] | safe) | tojson)')
        changes=$(jq --arg message "$tmp" '. + [{key:"workers.list",message:$message}]' <<<"$changes")
    fi
    if control_changed_config_paths "$staged" | grep -qx 'dashboard.energy.price_feed'; then
        tmp=$(jq -nr --slurpfile live "$CONFIG_FILE" --slurpfile staged "$staged" '
            "Electricity price feed: " + (($live[0].dashboard.energy.price_feed // false)|tostring)
            + " → " + (($staged[0].dashboard.energy.price_feed // false)|tostring)
            + " (remote price traffic changes)"')
        changes=$(jq --arg message "$tmp" '. + [{key:"dashboard.energy.price_feed",message:$message}]' <<<"$changes")
    fi
    values=$(jq -n --slurpfile live "$CONFIG_FILE" --slurpfile staged "$staged" '
        [["monero.wallet_address","Monero payout"], ["tari.wallet_address","Tari payout"],
         ["xvb.url","XvB endpoint"], ["monero.remote.host","Monero node host"],
         ["monero.remote.rpc_port","Monero RPC port"], ["monero.remote.zmq_port","Monero ZMQ port"],
         ["tari.remote.host","Tari node host"], ["tari.remote.grpc_port","Tari gRPC port"]]
        | map(.[0] as $p | ($p / ".") as $path
          | select(($live[0] | getpath($path)) != ($staged[0] | getpath($path)))
          | {key:$p,label:.[1],old:($live[0] | getpath($path)),new:($staged[0] | getpath($path))})') || return 1
    text=$(jq -nr --arg actor "$actor" --argjson changes "$changes" --argjson values "$values" '
        (["Approve configuration change for dashboard user " + $actor + "?"]
         + ($changes | map(.key + ": " + .message))
         + ($values | map(.label + ": " + ((.old // "")|tostring) + " → " + ((.new // "")|tostring)))
         + ["Denied automatically if not confirmed soon."]) | join("\n")') || return 1
    # Telegram limits message text to 4096 UTF-8 bytes. Never truncate a security preview: a
    # too-large change must be split and previewed again so every line remains visible.
    if [ "$(printf '%s' "$text" | wc -c)" -gt 3900 ]; then
        printf 'the approval preview is too large for one untruncated Telegram message — split the change'
        return 1
    fi
    (umask 077 && jq -n --arg id "$id" --arg actor "$actor" --arg nonce "$nonce" \
        --arg digest "$digest" --argjson suffixes "$suffixes" --argjson expiry "$deadline" \
        '{preview_id:$id,staged_sha256:$digest,actor:$actor,payout_suffixes:$suffixes,expiry:$expiry,nonce:$nonce}' >"$pending") || return 1
    (umask 077 && jq -n --arg chat "$chat" --arg text "$text" --arg nonce "$nonce" '
        {chat_id:$chat,text:$text,disable_web_page_preview:true,
         reply_markup:{inline_keyboard:[[{text:"✅ Approve configuration change",callback_data:("approve-config:"+$nonce)}]]}}' >"$payload") || return 1
    prefix=$(env_get NETWORK_PREFIX 2>/dev/null) || true
    [ -n "$prefix" ] || prefix="172.28.0"
    socks="${prefix}.25:9050"
    if ! printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" |
        curl -fsS --max-time 20 --max-filesize "$CURL_CAP_SMALL" --socks5-hostname "$socks" \
            --config - -H 'Content-Type: application/json' --data-binary "@$payload" -o "$response" 2>/dev/null; then
        rm -f "$pending" "$payload" "$response" "$updates"
        printf 'could not send the Telegram approval prompt — refusing the change'
        return 1
    fi
    message_id=$(jq -r 'select(.ok == true) | .result.message_id // empty' "$response")
    [ -n "$message_id" ] || {
        rm -f "$pending" "$payload" "$response" "$updates"
        printf 'Telegram did not accept the approval prompt — refusing the change'
        return 1
    }
    if ! { jq --arg mid "$message_id" '. + {message_id:$mid}' "$pending" >"${pending}.tmp" &&
        mv "${pending}.tmp" "$pending"; }; then
        rm -f "$pending" "${pending}.tmp" "$payload" "$response" "$updates"
        printf 'could not bind the Telegram message to its approval record — refusing the change'
        return 1
    fi

    while [ "$(date +%s)" -lt "$deadline" ]; do
        poll_s=$((deadline - $(date +%s)))
        [ "$poll_s" -gt 50 ] && poll_s=50
        [ "$poll_s" -gt 0 ] || break
        tmp=$(jq -n --argjson timeout "$poll_s" --argjson allowed '["callback_query"]' \
            --arg offset "$offset" '{timeout:$timeout,allowed_updates:$allowed,limit:100}
            | if $offset != "" then .offset=($offset|tonumber) else . end')
        printf '%s' "$tmp" >"$payload"
        if ! printf 'url = "https://api.telegram.org/bot%s/getUpdates"\n' "$token" |
            curl -fsS --max-time "$((poll_s + 10))" --max-filesize "$CURL_CAP_SMALL" --socks5-hostname "$socks" \
                --config - -H 'Content-Type: application/json' --data-binary "@$payload" -o "$updates" 2>/dev/null; then
            continue
        fi
        offset=$(jq -r '[.result[]?.update_id] | max // empty | . + 1' "$updates")
        uid=$(jq -r --arg nonce "approve-config:$nonce" --arg chat "$chat" --arg mid "$message_id" --arg text "$text" '
            .result[]?.callback_query
            | select(.data == $nonce and (.message.chat.id|tostring) == $chat
                     and (.message.message_id|tostring) == $mid and .message.text == $text)
            | (.from.id|tostring)' "$updates" | tail -n 1)
        [ -n "$uid" ] || continue
        case " $(printf '%s' "$allowed" | tr ',\t\n' '   ') " in
        *" $uid "*)
            [ "$(sha256sum "$staged" 2>/dev/null | awk '{print $1}')" = "$digest" ] || {
                rm -f "$pending" "$payload" "$response" "$updates"
                printf 'the staged configuration changed while approval was pending — refusing it'
                return 1
            }
            if ! { jq --arg approver "tg-$uid" '. + {approver:$approver}' "$pending" >"${pending}.approved" &&
                mv "${pending}.approved" "${staged}.approved"; }; then
                rm -f "$pending" "${pending}.approved" "$payload" "$response" "$updates"
                printf 'could not save the verified Telegram approver — refusing the change'
                return 1
            fi
            rm -f "$pending" "$payload" "$response" "$updates"
            printf 'tg-%s' "$uid"
            return 0
            ;;
        esac
    done
    rm -f "$pending" "$payload" "$response" "$updates"
    printf 'Telegram approval was not confirmed in time by an allow-listed operator'
    return 1
}

control_validate_approval() { # <staged-file> <id> <actor> <approval-json> <porcelain> <control-dir>
    local staged="$1" id="$2" actor="$3" approval="$4" porcelain="$5" cdir="$6"
    local chain env_key expected supplied suffixes
    [ -n "$actor" ] || {
        printf 'sign in before approving this sensitive change'
        return 1
    }
    jq -e '
        type == "object" and ((.payout_suffixes // {}) | type == "object")
        and ([keys[] | select(. != "payout_suffixes")] | length == 0)
        and ([.payout_suffixes | keys[] | select(. != "monero" and . != "tari")] | length == 0)
        and ([.payout_suffixes[] | select(type != "string")] | length == 0)
    ' <<<"$approval" >/dev/null 2>&1 || {
        printf 'sensitive changes need typed payout confirmations followed by host-verified Telegram approval'
        return 1
    }
    suffixes=$(jq -c '.payout_suffixes // {}' <<<"$approval")
    for chain in monero tari; do
        env_key="$(printf '%s' "$chain" | tr 'a-z' 'A-Z')_WALLET_ADDRESS"
        if printf '%s' "$porcelain" | awk -F'\t' -v k="$env_key" '$2 == k {found=1} END {exit !found}'; then
            expected=$(jq -r --arg c "$chain" '.[$c].wallet_address // "" | if length > 8 then .[-8:] else . end' "$staged")
            supplied=$(jq -r --arg c "$chain" '.[$c] // ""' <<<"$suffixes")
            [ -n "$expected" ] && [ "$supplied" = "$expected" ] || {
                printf 'type the final characters of the new %s payout address exactly' "$chain"
                return 1
            }
        fi
    done
    control_telegram_approve "$staged" "$id" "$actor" "$suffixes" "$porcelain" "$cdir"
}

# Called only by an explicit successful firstboot boundary; absence of a snapshot is not provenance.
control_audit_provisioned() { # [control-dir]
    local cdir="${1:-$(env_get CONTROL_DIR)}" id
    [ -n "$cdir" ] || cdir="$PWD/data/control"
    mkdir -p "$cdir/audit"
    id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
    printf '%s' "$id" | grep -qE '^[0-9a-f-]{36}$' || return 1
    control_audit "$cdir/audit/control.log" "$id" "setup-wizard" "provision" "applied" ""
}

control_consume_provisioning_marker() { # <marker>
    [ -f "$1" ] || return 0
    control_audit_provisioned "$PWD/data/control" || return 1
    rm -f "$1"
}

porcelain_keys() {
    printf '%s' "$1" | awk -F'\t' 'NF' | cut -f2 | sort -u | tr '\n' ' ' | sed 's/ $//'
}

control_write_result() { # <results-dir> <id> <json>
    printf '%s\n' "$3" >"$1/.$2.tmp" && mv "$1/.$2.tmp" "$1/$2.json"
}

# Values never enter the audit log: keys are the path names re-derived from live and staged files.
control_audit() { # <audit-file> <id> <actor> <action> <status> [keys] [approver]
    if [ -f "$1" ] && [ "$(wc -c <"$1" | tr -d ' ')" -gt 524288 ]; then
        tail -n 2000 "$1" >"$1.tmp" && mv "$1.tmp" "$1"
    fi
    printf '{"ts":"%s","id":"%s","actor":"%s","action":"%s","status":"%s","keys":"%s","approver":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(printf '%s' "$2" | tr -cd 'A-Za-z0-9-')" \
        "$(printf '%s' "$3" | tr -cd 'A-Za-z0-9._@-')" \
        "$(printf '%s' "$4" | tr -cd 'a-z-')" \
        "$(printf '%s' "$5" | tr -cd 'a-z-')" \
        "$(printf '%s' "${6:-}" | tr -cd 'A-Za-z0-9._ ')" \
        "$(printf '%s' "${7:-}" | tr -cd 'A-Za-z0-9._@-')" >>"$1"
}
