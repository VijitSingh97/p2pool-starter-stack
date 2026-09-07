# A bare dashboard.host label names the appliance. Existing DNS/IP pins remain certificate
# addresses; Docker hosts never change identity. config.json on /data is the persistent source:
# boot's render restores the kernel hostname after each reboot or A/B update, without /etc writes.
appliance_hostname_label() {
    is_appliance || return 0
    local name="${DASHBOARD_HOST:-}"
    [[ "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 0
    [ "$name" != auto ] || return 0
    printf '%s' "${name,,}"
}

# Only call after validation/confirmation, in setup, boot render or a successful apply.
# Resolution and preview use the pure label helper above, never this privileged step.
reconcile_appliance_hostname() {
    [ "${PITHEAD_DRY_RUN:-0}" != 1 ] || return 0
    local name
    name=$(appliance_hostname_label)
    [ -n "$name" ] || return 0
    if [ "$(hostname)" != "$name" ]; then
        sudo hostname "$name" || error "Could not set this appliance's hostname. Retry apply."
    fi
    # Avahi may already be running under the old name. try-restart leaves a not-yet-started
    # boot unit alone, and also retries a previous failed announcement on an unchanged apply.
    sudo systemctl try-restart avahi-daemon.service || error "Could not refresh this machine's local network name. Retry apply."
}
