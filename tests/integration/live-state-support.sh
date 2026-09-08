# shellcheck shell=bash
# Private CoW snapshots for exact rollback of writable live mount sources.

capture_state_snapshots() { # <stateful mount TSV>
    local source parent base snap nonce prior covered kept=""
    nonce="$$-$(date +%s)"
    UPGRADE_STATE_SNAPSHOTS=""
    UPGRADE_STATE_OLD_DIRS=""
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        [[ "$source" = /* && "$source" != / ]] || return 1
        covered=0
        while IFS= read -r prior; do
            [ -z "$prior" ] || case "$source/" in "$prior/"*) covered=1 ;; esac
        done <<<"$kept"
        [ "$covered" = 0 ] || continue
        parent="$(dirname "$source")" base="$(basename "$source")"
        snap="$parent/.pithead-live-$base-$nonce"
        rx "test -d $(quote_arg "$source") && test ! -L $(quote_arg "$source") && test ! -e $(quote_arg "$snap") && sudo -n cp -a --reflink=always -- $(quote_arg "$source") $(quote_arg "$snap")" || {
            rx "sudo -n rm -rf -- $(quote_arg "$snap")" >/dev/null 2>&1 || true
            cleanup_state_snapshots
            return 1
        }
        kept+="${kept:+$'\n'}$source"
        UPGRADE_STATE_SNAPSHOTS+="${UPGRADE_STATE_SNAPSHOTS:+$'\n'}$source"$'\t'"$snap"
    done < <(printf '%s\n' "$1" | cut -f3 | sort -u)
    [ -n "$UPGRADE_STATE_SNAPSHOTS" ]
}

restore_state_snapshots() {
    local source snap replacement old nonce
    nonce="$$-$(date +%s)"
    while IFS=$'\t' read -r source snap; do
        [ -n "$source" ] && [ -n "$snap" ] || return 1
        [[ "$source" = /* && "$source" != / && "$snap" = "$(dirname "$source")/.pithead-live-"* ]] || return 1
        replacement="$source.pithead-restore-$nonce" old="$source.pithead-old-$nonce"
        rx "test -d $(quote_arg "$snap") && test ! -e $(quote_arg "$replacement") && test ! -e $(quote_arg "$old") && sudo -n cp -a --reflink=always -- $(quote_arg "$snap") $(quote_arg "$replacement") && sudo -n mv -- $(quote_arg "$source") $(quote_arg "$old") && { sudo -n mv -- $(quote_arg "$replacement") $(quote_arg "$source") || { sudo -n mv -- $(quote_arg "$old") $(quote_arg "$source"); false; }; }" || return 1
        UPGRADE_STATE_OLD_DIRS+="${UPGRADE_STATE_OLD_DIRS:+$'\n'}$old"
    done <<<"$UPGRADE_STATE_SNAPSHOTS"
}

cleanup_state_snapshots() {
    local _source snap
    while IFS=$'\t' read -r _source snap; do
        [ -z "$snap" ] || rx "sudo -n rm -rf -- $(quote_arg "$snap")" >/dev/null 2>&1 || true
    done <<<"${UPGRADE_STATE_SNAPSHOTS:-}"
    while IFS= read -r snap; do
        [ -z "$snap" ] || rx "sudo -n rm -rf -- $(quote_arg "$snap")" >/dev/null 2>&1 || true
    done <<<"${UPGRADE_STATE_OLD_DIRS:-}"
}

derived_state_fingerprint() {
    rx 'source ./pithead; d=$(control_unit_dir); { for p in .env Caddyfile; do [ ! -f "$p" ] || sha256sum "$p"; done; find build -type f -exec sha256sum {} + 2>/dev/null; for p in "$d/pithead-control.path" "$d/pithead-control.service" /run/systemd/system/ssh.service.d/pithead.conf /run/pithead-ssh/authorized_keys; do if [ -f "$p" ]; then sudo -n sha256sum "$p"; else echo "absent $p"; fi; done; systemctl is-enabled pithead-control.path 2>/dev/null || true; systemctl is-active pithead-control.path 2>/dev/null || true; sudo -n passwd -S root 2>/dev/null | awk "{print \\$2}"; } | sort | sha256sum | cut -d" " -f1'
}

reset_control_units_for_render() {
    rx 'source ./pithead; [ "$OS_TYPE" != Linux ] || { d=$(control_unit_dir); sudo -n rm -f "$d/pithead-control.path" "$d/pithead-control.service" && sudo -n systemctl daemon-reload; }'
}
