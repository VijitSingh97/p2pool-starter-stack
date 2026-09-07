# --- Restore staging and archive boundaries ---

compose_active_ids() {
    local status ids active=""
    for status in running restarting paused; do
        ids=$(docker compose ps --status "$status" -q 2>/dev/null) || return 1
        active+="$ids"
    done
    printf '%s' "$active"
}

restore_require_stack_stopped() {
    command -v docker >/dev/null 2>&1 ||
        error "Restore could not verify that the stack is stopped because docker is unavailable — nothing was restored."
    local active
    active=$(compose_active_ids) ||
        error "Restore could not verify that the stack is stopped — nothing was restored. Fix Docker access, run '$0 down', and retry."
    [ -z "$active" ] ||
        error "Restore refused because stack services are still active — nothing was restored. Run '$0 down', then retry the restore."
}

restore_archive_stream() { # <archive> <encrypted:0|1> <passphrase>
    if [ "$2" -eq 1 ]; then
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
            -pass fd:3 -in "$1" 2>/dev/null 3< <(printf '%s' "$3")
    else
        cat "$1"
    fi
}

restore_collect_destinations() {
    local cfg="$CONFIG_FILE" key path
    case "$cfg" in /*) ;; *) cfg="$PWD/$cfg" ;; esac
    RESTORE_FIXED_PATHS=("$cfg" "$PWD/$ENV_FILE" "$PWD/Caddyfile")
    RESTORE_TRUSTED_DIRS=("$PWD/data/monero" "$PWD/data/tari" "$PWD/data/p2pool" "$PWD/data/tor" "$PWD/data/dashboard")
    for key in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR TOR_DATA_DIR DASHBOARD_DATA_DIR; do
        path=$(env_get_file "$PWD/$ENV_FILE" "$key")
        [ -z "$path" ] || RESTORE_TRUSTED_DIRS+=("$path")
    done
}

restore_member_allowed() {
    local name="${1%/}" path rel
    for path in "${RESTORE_FIXED_PATHS[@]}"; do
        [ "$name" = "${path#/}" ] && return 0
    done
    for path in "${RESTORE_ALLOWED_DIRS[@]}"; do
        rel="${path#/}"
        case "$name" in "$rel" | "$rel"/*) return 0 ;; esac
    done
    return 1
}

restore_discard_stage() {
    [ -z "${RESTORE_STAGE_DIR:-}" ] || rm -rf "$RESTORE_STAGE_DIR"
    RESTORE_STAGE_DIR=""
}

restore_destination_safe() { # <path> <file|dir>
    local path="$1" kind="$2" probe="$1"
    [ ! -L "$path" ] || return 1
    if [ -e "$path" ]; then
        if [ "$kind" = dir ]; then [ -d "$path" ]; else [ -f "$path" ]; fi || return 1
    fi
    probe=$(dirname "$probe")
    while [ "$probe" != / ]; do
        [ ! -L "$probe" ] || return 1
        { [ ! -e "$probe" ] || [ -d "$probe" ]; } || return 1
        probe=$(dirname "$probe")
    done
}

restore_staged_members_safe() {
    local root staged_root source rel destination kind
    for root in "${RESTORE_ALLOWED_DIRS[@]}"; do
        staged_root="$RESTORE_STAGE_DIR/${root#/}"
        [ ! -d "$staged_root" ] || while IFS= read -r -d '' source; do
            rel="${source#"$staged_root"/}"
            destination="$root/$rel"
            if [ -d "$source" ]; then kind="dir"; else kind="file"; fi
            restore_destination_safe "$destination" "$kind" || return 1
        done < <(find "$staged_root" -mindepth 1 -print0)
    done
}

restore_stage_archive() { # <archive> <encrypted:0|1> <passphrase>
    local archive="$1" encrypted="$2" pass="$3" names details name unsafe=0
    local staged_cfg staged_env staged_caddy paths_file err="" path trusted match env_path i=0
    local keys=(MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR TOR_DATA_DIR DASHBOARD_DATA_DIR)
    restore_collect_destinations
    names=$(restore_archive_stream "$archive" "$encrypted" "$pass" | tar -tzf -) ||
        error "Archive fails integrity verification (tampered or truncated) — nothing was restored."
    details=$(restore_archive_stream "$archive" "$encrypted" "$pass" | tar -tvzf -) ||
        error "Archive fails integrity verification (tampered or truncated) — nothing was restored."
    if printf '%s\n' "$names" | grep -qE '^/|(^|/)(\.|\.\.)(/|$)|//' ||
        printf '%s\n' "$details" | grep -qEv '^[-d]'; then
        error "Archive contains unsafe paths, links, or special files — nothing was restored."
    fi

    RESTORE_STAGE_DIR=$(mktemp -d) || error "Could not create a private restore staging directory."
    if ! restore_archive_stream "$archive" "$encrypted" "$pass" | tar -xzf - -C "$RESTORE_STAGE_DIR"; then
        restore_discard_stage
        error "Could not stage the verified archive — nothing was restored."
    fi
    staged_cfg="$RESTORE_STAGE_DIR/${RESTORE_FIXED_PATHS[0]#/}"
    staged_env="$RESTORE_STAGE_DIR/${RESTORE_FIXED_PATHS[1]#/}"
    staged_caddy="$RESTORE_STAGE_DIR/${RESTORE_FIXED_PATHS[2]#/}"
    paths_file="$RESTORE_STAGE_DIR/.validated-data-paths"
    if [ ! -f "$staged_cfg" ] || [ ! -f "$staged_env" ] || { [ -e "$staged_caddy" ] && [ ! -f "$staged_caddy" ]; } ||
        ! err=$(PITHEAD_CONFIG_FILE="$staged_cfg" RESTORE_PATH_FILE="$paths_file" bash -c \
            "source '${BASH_SOURCE[0]}' && parse_and_validate_config >/dev/null && printf '%s\\0' \"\$MONERO_DIR\" \"\$TARI_DIR\" \"\$P2POOL_DIR\" \"\$TOR_DATA_DIR\" \"\$DASHBOARD_DIR\" >\"\$RESTORE_PATH_FILE\"" 2>&1); then
        restore_discard_stage
        error "Archive does not contain a valid Pithead configuration — nothing was restored. ${err:0:240}"
    fi

    RESTORE_ALLOWED_DIRS=()
    while IFS= read -r -d '' path; do
        match=0
        for trusted in "${RESTORE_TRUSTED_DIRS[@]}"; do [ "$path" != "$trusted" ] || match=1; done
        if [ "$match" -ne 1 ]; then
            restore_discard_stage
            error "Archive targets a data directory that is not configured on this appliance — nothing was restored. Configure the destination first, then retry."
        fi
        RESTORE_ALLOWED_DIRS+=("$path")
        env_path=$(env_get_file "$staged_env" "${keys[$i]}")
        [ -z "$env_path" ] || [ "$env_path" = "$path" ] || unsafe=1
        i=$((i + 1))
    done <"$paths_file"
    rm -f "$paths_file"
    [ "$i" -eq 5 ] || unsafe=1
    while IFS= read -r name; do restore_member_allowed "$name" || unsafe=1; done <<<"$names"
    if [ "$unsafe" -ne 0 ]; then
        restore_discard_stage
        error "Archive contains files or data paths outside this appliance's validated restore set — nothing was restored."
    fi
}

restore_recheck_destinations() {
    local restore_paths_snapshot=("${RESTORE_ALLOWED_DIRS[@]}") path trusted match
    restore_collect_destinations
    for path in "${restore_paths_snapshot[@]}"; do
        match=0
        for trusted in "${RESTORE_TRUSTED_DIRS[@]}"; do [ "$path" != "$trusted" ] || match=1; done
        if [ "$match" -ne 1 ]; then
            restore_discard_stage
            error "Restore destinations changed while the archive was being checked — nothing was restored. Retry against the current configuration."
        fi
    done
    RESTORE_ALLOWED_DIRS=("${restore_paths_snapshot[@]}")
    for path in "${RESTORE_FIXED_PATHS[@]}"; do
        restore_destination_safe "$path" file || {
            restore_discard_stage
            error "Restore refused an unsafe fixed-file destination — nothing was restored. Replace destination symlinks or non-directory parents, then retry."
        }
    done
    for path in "${RESTORE_ALLOWED_DIRS[@]}"; do
        restore_destination_safe "$path" dir || {
            restore_discard_stage
            error "Restore refused an unsafe data-directory destination — nothing was restored. Replace destination symlinks or non-directory parents, then retry."
        }
    done
    restore_staged_members_safe || {
        restore_discard_stage
        error "Restore refused a redirected path inside a data directory — nothing was restored. Remove destination symlinks, then retry."
    }
}

restore_commit_stage() {
    local path rel
    for path in "${RESTORE_FIXED_PATHS[@]}"; do
        rel="${path#/}"
        [ ! -e "$RESTORE_STAGE_DIR/$rel" ] || sudo cp -a --remove-destination "$RESTORE_STAGE_DIR/$rel" "$path" || {
            restore_discard_stage
            error "Restore failed while committing $path; inspect the destination before retrying."
        }
    done
    for path in "${RESTORE_ALLOWED_DIRS[@]}"; do
        rel="${path#/}"
        [ ! -d "$RESTORE_STAGE_DIR/$rel" ] || { sudo mkdir -p "$path" && sudo cp -a --remove-destination "$RESTORE_STAGE_DIR/$rel"/. "$path"/; } || {
            restore_discard_stage
            error "Restore failed while committing $path; inspect the destination before retrying."
        }
    done
    restore_discard_stage
}
