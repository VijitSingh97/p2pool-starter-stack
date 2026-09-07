# Appliance name

The coordinator wizard's **Name this machine** field sets `dashboard.host`.

Use 1–63 ASCII letters, digits or hyphens, starting and ending with a letter or digit.
New coordinators default to `pithead`. RigForge-only installs keep their worker-name field.
A reinstall that keeps everything retains the saved configuration, including its name.

For a name such as `garden-box`, the appliance uses the lowercase hostname `garden-box`
and serves the dashboard at `https://garden-box.local`. The certificate covers that name
and the permitted local addresses; the dashboard header uses the same name. After a name
change, open the new address and check the new certificate fingerprint on the console.

To rename an installed appliance, edit `dashboard.host` to a hostname label in
[Configuration](configuration.md), then apply the change. A successful apply refreshes the
machine's hostname and mDNS announcement. Preview and dry-run leave them alone.
The saved configuration restores the name during boot, including after an OS update;
the read-only system partition holds no separate hostname setting.

Existing `auto` settings retain the current hostname. Existing dotted DNS names and IP
addresses remain dashboard certificate addresses. Docker installations keep their host's
identity when `dashboard.host` changes.
