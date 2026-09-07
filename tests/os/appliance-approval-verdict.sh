# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2329  # fake functions and dynamic globals are the controls
# Verdicts and fake-transport failure controls for appliance-config-approval-leg.sh.

approval_prompt_verdict() { # <prompt-text> <required-text>...
    local prompt="$1" required
    shift
    [ -n "$prompt" ] || return 1
    for required in "$@"; do
        case "$prompt" in *"$required"*) ;; *) return 1 ;; esac
    done
}

approval_audit_verdict() { # <JSONL> <request-id>
    printf '%s\n' "$1" | jq -se --arg id "$2" 'any(.[];
        .id == $id and .action == "commit-approved" and .status == "applied" and .approver == "tg-1966")' >/dev/null
}

tari_endpoint_roundtrip_verdict() { # <p2pool-startup-log> <expected-host:port>
    local plain
    plain=$(printf '%s\n' "$1" | mm_strip_ansi)
    printf '%s\n' "$plain" | grep -aF "MergeMiningClientTari tari://$2 uses chain_id " | grep -aqE 'uses chain_id [0-9a-f]{16,}'
}

_control_request_transport_self_test() (
    local secret='os1966-secret-not-in-argv' body result ip=fixture transport_fail=0
    body=$(jq -nc --arg password "$secret" '{config:{monero:{node_password:$password}}}')
    dashboard_curl() {
        local arg stdin_body
        stdin_body=$(cat)
        [ "$stdin_body" = "$body" ] || return 92
        while [ "$#" -gt 0 ]; do
            arg="$1"
            case "$arg" in *"$secret"*) return 91 ;; esac
            if [ "$arg" = --data-binary ]; then
                [ "$2" = @- ] || return 93
                shift 2
            else
                shift
            fi
        done
        [ "$transport_fail" -eq 0 ] || return 94
        printf '{"id":"fixture","status":"previewed"}'
    }
    result=$(dashboard_control_request preview "$body") || return 1
    [ "$result" = '{"id":"fixture","status":"previewed"}' ] || return 1
    transport_fail=1
    dashboard_control_request preview "$body" >/dev/null 2>&1 && return 1
    return 0
)

_approval_fixture_failure_self_test() (
    local f=0 ip=fixture command_file command ssh_called=0
    _ssh() { ssh_called=1; }
    approval_fixture_arm not-an-id && f=$((f + 1))
    [ "$ssh_called" -eq 0 ] || f=$((f + 1))
    _ssh() { return 1; }
    APPROVAL_FIXTURE_ARMED=0
    ! approval_fixture_arm 00000000-0000-4000-8000-000000000001 && [ "$APPROVAL_FIXTURE_ARMED" -eq 1 ] || f=$((f + 1))
    APPROVAL_FIXTURE_ARMED=1
    ! approval_fixture_disarm && [ "$APPROVAL_FIXTURE_ARMED" -eq 1 ] || f=$((f + 1))
    _ssh() { return 0; }
    approval_fixture_disarm && [ "$APPROVAL_FIXTURE_ARMED" -eq 0 ] || f=$((f + 1))
    command_file=$(mktemp)
    _ssh() { printf '%s' "$1" >"$command_file"; }
    APPROVAL_FIXTURE_ARMED=1
    approval_fixture_quiesce || f=$((f + 1))
    command=$(cat "$command_file")
    rm -f "$command_file"
    case "$command" in
    *"systemctl stop pithead-control.path"*"systemctl stop pithead-control.service"*".os1966-active-id"*"requests"*".claim."*".approval-"*".telegram-"*'$id.json'*) ;;
    *) f=$((f + 1)) ;;
    esac
    [ "$f" -eq 0 ]
)

_runtime_epoch_self_test() (
    local count_file ip=fixture n
    count_file=$(mktemp)
    printf '0\n' >"$count_file"
    trap 'rm -f "$count_file"' EXIT
    _ssh() {
        case "$1" in
        *".State.StartedAt"*)
            n=$(cat "$count_file")
            n=$((n + 1))
            printf '%s\n' "$n" >"$count_file"
            [ "$n" -lt 4 ] && printf 'epoch-one\n' || printf 'epoch-two\n'
            ;;
        *"sed -n"*) printf 'MONERO_NODE_HOST=monero.fixture\nMONERO_RPC_PORT=18081\nMONERO_ZMQ_PORT=18083\nTARI_GRPC_ADDRESS=tari.fixture:18142\n' ;;
        *".Config.Cmd"*) printf 'monero.fixture\t18081\t18083\ttari://tari.fixture:18142\n' ;;
        *".Config.Env"*) return 0 ;;
        esac
    }
    local snapshot='PITHEAD_P2POOL_STARTED=epoch-one
MergeMiningClientTari tari://tari.fixture:18142 uses chain_id 0123456789abcdef'
    remote_node_runtime_verdict monero.fixture 18081 18083 tari.fixture 18142 "$snapshot" || return 1
    remote_node_runtime_verdict monero.fixture 18081 18083 tari.fixture 18142 "$snapshot" && return 1
    return 0
)
