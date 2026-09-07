# The boot menu's "Set up again" entry (#1318). os/rauc/grub.cfg appends pithead.setup=1 to that
# one boot; pithead-setup-again.service runs `pithead firstboot-wizard` with PITHEAD_SETUP_AGAIN
# set, ahead of pithead-boot. What that switch changes is small, and all of it is here or one line
# each in firstboot_wizard: the "this machine already has a role" short-circuits are skipped, the
# page is told what the machine is, and "Keep it" ends the session with nothing on /data touched.
# The role marker, rig.json and config.json are replaced only where a NEW role is accepted — the
# same accept paths a first boot takes, unchanged.
setup_again_mode() { [ -n "${PITHEAD_SETUP_AGAIN:-}" ]; }

# Root writes credentials into this directory while the uid-1000 wizard reads the finished card
# and writes requests. Keep root as the directory owner and make uid 1000 the writable group: the
# sticky bit then stops the wizard from replacing root's temp between creation and write. A test or
# DIY non-root caller gets a private directory it already owns. No world-writable fallback.
prepare_wizard_spool() { # <spool-dir>
    local uid
    [ ! -L "$1" ] || return 1
    mkdir -p "$1" || return 1
    uid=$(id -u)
    if [ "$uid" = 0 ]; then
        if ! chown 0:1000 "$1" 2>/dev/null || ! chmod 1770 "$1"; then
            chmod 700 "$1" 2>/dev/null || true
            return 1
        fi
    else
        [ "$(stat -c '%u' "$1" 2>/dev/null)" = "$uid" ] && chmod 700 "$1"
    fi
}

# What the page is told the machine already is, secrets left out: the role, and for a rig the pool
# and worker it mines as (no stratum password, no control token). The rig form's pre-fill is
# pointed at the SAME answers, so "Set up again" opens on them rather than on a fresh LAN probe; a
# coordinator's form pre-fills from config.json through the reinstall rule (strip_config_secrets),
# once per session so a failed re-provision's own retry context is never overwritten. Nothing is
# published outside a set-up-again boot: the file's presence IS the page's signal.
publish_saved_role() { # <spool-dir>
    setup_again_mode || return 0
    local spool="$1" role tmp="$1/.saved-role.json.$$" rtmp="$1/.rig-defaults.json.$$"
    role=$(machine_role)
    if [ "$role" = rig ] && [ -f "$PWD/rig.json" ]; then
        jq '{role: "rig", pool: (.pool // ""), worker: (.worker // "")}' "$PWD/rig.json" >"$tmp" 2>/dev/null ||
            jq -n '{role: "rig"}' >"$tmp"
        jq '{pool, worker}' "$tmp" >"$rtmp" 2>/dev/null && mv -f "$rtmp" "$spool/rig-defaults.json" || rm -f "$rtmp"
    else
        jq -n --arg r "$role" '{role: $r}' >"$tmp"
        if [ ! -f "$spool/last-attempt.json" ] && [ -f "$PWD/config.json" ]; then
            strip_config_secrets "$PWD/config.json" >"$spool/last-attempt.json" 2>/dev/null ||
                rm -f "$spool/last-attempt.json"
        fi
    fi
    chown 1000:1000 "$tmp" "$spool/rig-defaults.json" "$spool/last-attempt.json" 2>/dev/null || true
    mv -f "$tmp" "$spool/saved-role.json"
}

# The wizard's credentials card, both roles: the coordinator's login, or (since #1836) the rig's
# control token. It is owner-only from its FIRST byte (#1842): a chmod after the write leaves a
# world-readable window under the default umask, and a predictable temp left by an earlier attempt
# keeps THAT temp's mode (or may be a symlink) — so mktemp creates a new inode, its private mode is
# enforced before stdin is read, and the sticky spool prevents replacement before that write. The
# inode then replaces the card whole and is owned by the page's user; the ack is unchanged.
write_handoff_card() { # <spool-dir>; the card's JSON on stdin
    local tmp tmp_id tmp_fd
    tmp=$(mktemp "$1/.handoff.json.XXXXXX") || return 1
    if [ -L "$tmp" ] || [ ! -f "$tmp" ] || ! chmod 600 "$tmp" ||
        ! tmp_id=$(stat -Lc '%d:%i' "$tmp" 2>/dev/null) || ! exec {tmp_fd}>"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    # Write through the already-open inode, never by resolving the path again. The identity check
    # also makes a replacement attempt a refusal rather than publishing the replacement.
    if [ "$(stat -Lc '%d:%i' "/proc/$BASHPID/fd/$tmp_fd" 2>/dev/null)" != "$tmp_id" ] ||
        ! cat >&"$tmp_fd"; then
        exec {tmp_fd}>&-
        rm -f "$tmp"
        return 1
    fi
    exec {tmp_fd}>&-
    if [ "$(stat -Lc '%d:%i' "$tmp" 2>/dev/null)" != "$tmp_id" ] ||
        ! mv -f "$tmp" "$1/handoff.json"; then
        rm -f "$tmp"
        return 1
    fi
    if ! chown 1000:1000 "$1/handoff.json" 2>/dev/null; then
        rm -f "$1/handoff.json"
        return 1
    fi
}

# "Keep it": the page wrote keep-role. Nothing on /data was touched — the marker, rig.json and
# config.json are exactly as this boot found them — so firstboot_wizard returns, the unit ends,
# and pithead-boot runs the boot the machine would have taken from the default entry.
wizard_keep_requested() { # <spool-dir>
    setup_again_mode && [ -f "$1/keep-role" ] || return 1
    rm -f "$1/keep-role"
    _console "Setup closed: the saved settings are kept. The machine is starting as it was."
}
