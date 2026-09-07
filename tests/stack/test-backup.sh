# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
WALLET="$VALID_PRIMARY" # checksum-valid mainnet primary (the XMRig donation address) — see #1305

echo "== unit: stack_backup — one bounded retry on a tar race (#970) =="
RB="$(cd "$SANDBOX" && pwd -P)/backup-retry"
mkdir -p "$RB/build/tari" "$RB/data/tor" "$RB/data/dashboard" "$RB/bin"
cp "$STACK" "$RB/pithead"
cp "$ROOT/build/tari/config.toml.template" "$RB/build/tari/"
cat >"$RB/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$RB/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
if [ "$1" = "tar" ] && [ ! -f "${RETRY_MARK:?}" ]; then
    : >"$RETRY_MARK"
    echo "tar: fixture-member: file changed as we read it" >&2
    exit 1
fi
exec "$@"
EOF
chmod +x "$RB/bin/docker" "$RB/bin/sudo"
cat >"$RB/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=RBTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$RB/config.json"
out="$(cd "$RB" && PATH="$RB/bin:$PATH" RETRY_MARK="$RB/first-tar-failed" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "backup survives one tar race via the retry" "$rc" "0"
assert_contains "the first failure is loud, not silent" "$out" "retrying once"
assert_eq "the retry actually ran (fixture consumed)" "$([ -f "$RB/first-tar-failed" ] && echo yes)" "yes"
rbarchive="$(ls "$RB"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$rbarchive" ] && [ -s "$rbarchive" ]; } && ok "retry produced a real archive" || bad "retry produced a real archive" "no .enc archive"

echo "== unit: backup_require_items — refuses a missing/dangling required item before anything is touched (#1244) =="
BRI="$SANDBOX/backup-require-items"
mkdir -p "$BRI"
: >"$BRI/present.txt"
ln -s "$BRI/nowhere" "$BRI/dangling.txt"
out=$(run_sourced "$BRI" backup_require_items "$BRI/present.txt" "$BRI/missing.txt" 2>&1)
rc=$?
assert_rc "a genuinely missing item refuses (nonzero)" "$rc" "1"
assert_contains "the refusal names the exact resolved path" "$out" "$BRI/missing.txt"
assert_contains "the refusal says what to do next" "$out" "pithead setup"
out=$(run_sourced "$BRI" backup_require_items "$BRI/present.txt" "$BRI/dangling.txt" 2>&1)
rc=$?
assert_rc "a dangling symlink refuses the same way a missing file does" "$rc" "1"
assert_contains "the dangling-symlink refusal also names the path" "$out" "$BRI/dangling.txt"
out=$(run_sourced "$BRI" backup_require_items "$BRI/present.txt" 2>&1)
rc=$?
assert_rc "every item present passes silently" "$rc" "0"
assert_eq "nothing is printed when every required item is present" "$out" ""

echo "== unit: backup_diagnose_items — a tar failure names its cwd and each item's real state (#1244) =="
out=$(run_sourced "$BRI" backup_diagnose_items "/" "$BRI/present.txt" "$BRI/missing.txt" "$BRI/dangling.txt" 2>&1)
assert_contains "names the -C directory tar ran against" "$out" 'tar ran with -C "/"'
assert_contains "a present item is reported present with its own listing" "$out" "present: "
assert_contains "the present item's line names its own path" "$out" "$BRI/present.txt"
assert_contains "a missing item is called out by name" "$out" "MISSING: $BRI/missing.txt"
assert_contains "a dangling symlink is distinguished from a plain miss" "$out" "DANGLING SYMLINK: $BRI/dangling.txt"
unset BRI out rc

echo "== unit: stack_backup — an absolute CONFIG_FILE override is archived at its real path, not a doubled one (#1244) =="
CJ="$SANDBOX/backup-cfg-override"
mkdir -p "$CJ/build/tari" "$CJ/data/tor" "$CJ/data/dashboard" "$CJ/bin"
cp "$STACK" "$CJ/pithead"
cp "$ROOT/build/tari/config.toml.template" "$CJ/build/tari/"
cat >"$CJ/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$CJ/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$CJ/bin/docker" "$CJ/bin/sudo"
cat >"$CJ/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=CJTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
CJALT="$SANDBOX/backup-cfg-override-elsewhere"
mkdir -p "$CJALT"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$CJALT/candidate.json"
out=$(cd "$CJ" && PATH="$CJ/bin:$PATH" PITHEAD_CONFIG_FILE="$CJALT/candidate.json" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)
rc=$?
assert_rc "backup succeeds against an absolute CONFIG_FILE override" "$rc" "0"
cjarchive="$(ls "$CJ"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$cjarchive" ] && [ -s "$cjarchive" ]; } && ok "override archive was written" || bad "override archive was written" "no .enc archive"
cjlist=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass pass:hunter2 -in "$cjarchive" 2>/dev/null | tar -tzf - 2>/dev/null)
assert_contains "the archive carries the override's real, un-doubled path" "$cjlist" "${CJALT#/}/candidate.json"
assert_not_contains "the archive never carries a \$PWD-doubled override path" "$cjlist" "${CJ#/}${CJALT}"
unset CJ CJALT out rc cjarchive cjlist

echo "== black-box: backup -> restore round-trip (#140) =="
BK="$(cd "$SANDBOX" && pwd -P)/backup"
mkdir -p "$BK/build/tari" "$BK/data/tor" "$BK/data/dashboard" "$BK/bin"
cp "$STACK" "$BK/pithead"
cp "$ROOT/build/tari/config.toml.template" "$BK/build/tari/"
cat >"$BK/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "compose ps --status" ] && [ "$5" = -q ]; then
    n=0; [ -z "${PS_COUNT:-}" ] || { [ ! -f "$PS_COUNT" ] || n=$(cat "$PS_COUNT"); n=$((n + 1)); printf '%s' "$n" >"$PS_COUNT"; }
    { [ "${STACK_STATUS:-}" = "$4" ] || { [ "${ACTIVE_AFTER_PS_COUNT:-999}" -lt "$n" ] && [ "$4" = running ]; }; } && echo cid123
fi
exit 0
EOF
cat >"$BK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$BK/bin/docker" "$BK/bin/sudo"
cat >"$BK/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=BKTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$BK/config.json"
printf 'CADDY-ORIG\n' >"$BK/Caddyfile"
printf 'ONIONKEY-ORIG\n' >"$BK/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-ORIG\n' >"$BK/data/dashboard/dashboard.db"

out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "backup exits 0" "$rc" "0"
archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$archive" ] && [ -f "$archive" ]; } && ok "backup archive created" || bad "backup archive created" "no archive under backups/"

listing="$(tar -tzf "$archive" 2>/dev/null)"
assert_contains "archive has config.json" "$listing" "config.json"
assert_contains "archive has .env" "$listing" ".env"
assert_contains "archive has Caddyfile" "$listing" "Caddyfile"
assert_contains "archive has the tor onion key" "$listing" "hs_ed25519_secret_key"
assert_contains "archive has the dashboard db" "$listing" "dashboard.db"
case "$listing" in
*data/monero* | *data/p2pool/* | *data/tari*) bad "archive excludes blockchains by default" "chain data present without --with-chains" ;;
*) ok "archive excludes blockchains by default" ;;
esac
sandbox_rel="${BK#/}"
escaped="$(printf '%s\n' "$listing" | grep -v '^$' | grep -v "^$sandbox_rel" || true)"
assert_eq "archive paths stay inside the sandbox" "$escaped" ""

victim="$SANDBOX/restore-victim"
malroot="$SANDBOX/malicious-restore"
malarchive="$BK/backups/malicious.tar.gz"
mkdir -p "$malroot/${BK#/}" "$(dirname "$malroot/${victim#/}")" "$malroot/${BK#/}/data/tor"
cp "$BK/config.json" "$BK/.env" "$malroot/${BK#/}/"
printf 'SAFE\n' >"$victim"
printf 'ATTACK\n' >"$malroot/${victim#/}"
tar -czf "$malarchive" -C "$malroot" "${BK#/}/config.json" "${BK#/}/.env" "${victim#/}"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$malarchive" 2>&1)"
assert_rc "restore rejects a valid archive member outside its destination set" "$?" "1"
assert_eq "rejected outside member cannot overwrite a host file" "$(cat "$victim")" "SAFE"
ln -s "$victim" "$malroot/${BK#/}/data/tor/escape-link"
tar -czf "$malarchive" -C "$malroot" "${BK#/}/config.json" "${BK#/}/.env" "${BK#/}/data/tor/escape-link"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$malarchive" 2>&1)"
assert_rc "restore rejects links even under an allowed data directory" "$?" "1"
assert_contains "unsafe archive refusal explains the boundary" "$out" "unsafe paths, links, or special files"
rm -f "$malarchive"

printf 'FIXED-SAFE\n' >"$SANDBOX/fixed-destination-victim"
rm -f "$BK/Caddyfile" && ln -s "$SANDBOX/fixed-destination-victim" "$BK/Caddyfile"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$archive" 2>&1)"
assert_rc "restore rejects an existing fixed-file destination symlink" "$?" "1"
assert_eq "fixed-file symlink victim stays untouched" "$(cat "$SANDBOX/fixed-destination-victim")" "FIXED-SAFE"
rm -f "$BK/Caddyfile" && printf 'CADDY-ORIG\n' >"$BK/Caddyfile"
mv "$BK/data/tor" "$BK/data/tor-real" && mkdir -p "$SANDBOX/data-destination-victim"
ln -s "$SANDBOX/data-destination-victim" "$BK/data/tor"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$archive" 2>&1)"
assert_rc "restore rejects an existing data-directory destination symlink" "$?" "1"
assert_eq "data-directory symlink victim stays untouched" "$(find "$SANDBOX/data-destination-victim" -mindepth 1 -print -quit)" ""
rm -f "$BK/data/tor" && mv "$BK/data/tor-real" "$BK/data/tor"

printf 'CADDY-LIVE\n' >"$BK/Caddyfile"
out="$(cd "$BK" && STACK_STATUS=running PATH="$BK/bin:$PATH" ./pithead restore -y "$archive" 2>&1)"
rc=$?
assert_rc "restore refuses while any stack service is running (#1965)" "$rc" "1"
assert_contains "live-restore refusal names the required recovery" "$out" "pithead down"
assert_eq "live-restore refusal preserves the current files" "$(cat "$BK/Caddyfile")" "CADDY-LIVE"
out="$(cd "$BK" && STACK_STATUS=paused PATH="$BK/bin:$PATH" ./pithead restore -y "$archive" 2>&1)"
assert_rc "restore also refuses a paused service" "$?" "1"
rm -f "$BK/ps.count"
out="$(cd "$BK" && PS_COUNT="$BK/ps.count" ACTIVE_AFTER_PS_COUNT=3 PATH="$BK/bin:$PATH" ./pithead restore -y "$archive" 2>&1)"
assert_rc "restore rechecks service state under its mutation lock" "$?" "1"
assert_eq "a service starting after the early check prevents extraction" "$(cat "$BK/Caddyfile")" "CADDY-LIVE"

printf 'CORRUPTED\n' >"$BK/Caddyfile"
printf 'CORRUPTED\n' >"$BK/data/dashboard/dashboard.db"
rm -f "$BK/data/tor/hs_ed25519_secret_key"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$archive" 2>&1)"
rc=$?
assert_rc "restore exits 0" "$rc" "0"
assert_eq "restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
assert_eq "restore brings back the dashboard db" "$(cat "$BK/data/dashboard/dashboard.db")" "DBDATA-ORIG"
assert_eq "restore brings back the onion key" "$(cat "$BK/data/tor/hs_ed25519_secret_key" 2>/dev/null)" "ONIONKEY-ORIG"

cat >"$BK/bin/df" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' '/dev/fake 100 99 1 99% /'
EOF
chmod +x "$BK/bin/df"
rm -f "$BK"/backups/pithead-backup-*.tar.gz
out="$(cd "$BK" && printf '\nn\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
assert_contains "low-space prompt, then cancel" "$out" "ancelled"
leftover="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
assert_eq "cancelled backup writes no archive" "$leftover" ""
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "low-space backup proceeds with --yes" "$rc" "0"
assert_contains "low-space backup warns first" "$out" "Low free space"

echo "== black-box: encrypted backup -> restore (#374) =="
rm -f "$BK/bin/df" "$BK"/backups/pithead-backup-*

# 1a) --yes with no passphrase REFUSES (no silent plaintext downgrade for cron); writes nothing.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "unattended backup without passphrase exits non-zero" || bad "unattended backup without passphrase exits non-zero" "rc=0"
assert_contains "refusal names the missing passphrase" "$out" "PITHEAD_BACKUP_PASSPHRASE"
assert_eq "refused unattended backup writes no archive" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
# 1b) --no-encrypt is the explicit plaintext opt-out (loud warning, exits 0, writes a plain archive).
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "explicit --no-encrypt backup exits 0" "$rc" "0"
plain_optout="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$plain_optout" ] && [ -f "$plain_optout" ]; } && ok "--no-encrypt writes a plaintext archive" || bad "--no-encrypt writes a plaintext archive" "no plain archive"
rm -f "$BK"/backups/pithead-backup-*

# 2) Env-var passphrase: a .enc archive with the openssl Salted__ header, no plaintext twin.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "encrypted backup exits 0" "$rc" "0"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$enc_archive" ] && [ -f "$enc_archive" ]; } && ok "encrypted archive created (.enc)" || bad "encrypted archive created (.enc)" "no .enc under backups/"
assert_eq "archive starts with Salted__" "$(head -c 8 "$enc_archive")" "Salted__"
plain_left="$(ls "$BK"/backups/*.tar.gz 2>/dev/null | head -1)"
assert_eq "no plaintext archive alongside the .enc" "$plain_left" ""
assert_contains "backup says to store the passphrase elsewhere" "$out" "passphrase"

# 3) Wrong passphrase: restore fails loudly before tar runs — live files untouched.
printf 'CADDY-LIVE\n' >"$BK/Caddyfile"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=wrong ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "wrong passphrase exits non-zero" || bad "wrong passphrase exits non-zero" "rc=0"
assert_contains "wrong passphrase names the cause" "$out" "rong passphrase"
assert_eq "wrong passphrase leaves live files untouched" "$(cat "$BK/Caddyfile")" "CADDY-LIVE"

# A prompted right passphrase restores the archived -ORIG values.
printf 'CORRUPTED\n' >"$BK/data/dashboard/dashboard.db"
rm -f "$BK/data/tor/hs_ed25519_secret_key"
out="$(cd "$BK" && printf 'hunter2\n' | PATH="$BK/bin:$PATH" ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
assert_rc "encrypted restore exits 0" "$rc" "0"
assert_eq "encrypted restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
assert_eq "encrypted restore brings back the dashboard db" "$(cat "$BK/data/dashboard/dashboard.db")" "DBDATA-ORIG"
assert_eq "encrypted restore brings back the onion key" "$(cat "$BK/data/tor/hs_ed25519_secret_key" 2>/dev/null)" "ONIONKEY-ORIG"

# A truncated ciphertext passes magic but must fail full-stream verification before writes.
printf 'CADDY-LIVE\n' >"$BK/Caddyfile"
head -c $(($(wc -c <"$enc_archive") - 32)) "$enc_archive" >"$BK/backups/truncated.tar.gz.enc"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead restore -y "$BK/backups/truncated.tar.gz.enc" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "tampered archive exits non-zero" || bad "tampered archive exits non-zero" "rc=0"
assert_contains "tampered archive names integrity failure" "$out" "integrity"
assert_eq "tampered archive leaves live files untouched" "$(cat "$BK/Caddyfile")" "CADDY-LIVE"
rm -f "$BK"/backups/pithead-backup-* "$BK/backups/truncated.tar.gz.enc"
# Keep -ORIG in place for the later plaintext backup.
printf 'CADDY-ORIG\n' >"$BK/Caddyfile"

# 5) Interactive prompt path: passphrase typed twice encrypts; a mismatch aborts with no archive.
out="$(cd "$BK" && printf 'pw\npw\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
rc=$?
assert_rc "prompted encrypted backup exits 0" "$rc" "0"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
assert_eq "prompted backup writes Salted__" "$(head -c 8 "$enc_archive")" "Salted__"
rm -f "$BK"/backups/pithead-backup-*
out="$(cd "$BK" && printf 'pw\nother\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "passphrase mismatch exits non-zero" || bad "passphrase mismatch exits non-zero" "rc=0"
assert_contains "passphrase mismatch says so" "$out" "do not match"
assert_eq "passphrase mismatch writes no archive" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""

# --no-encrypt overrides the env passphrase; the gzip archive still restores.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "--no-encrypt backup exits 0" "$rc" "0"
plain_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$plain_archive" ] && gzip -t "$plain_archive" 2>/dev/null; } && ok "--no-encrypt writes plain gzip" || bad "--no-encrypt writes plain gzip" "missing or not gzip"
printf 'CORRUPTED\n' >"$BK/Caddyfile"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$plain_archive" 2>&1)"
rc=$?
assert_rc "plaintext archive still restores" "$rc" "0"
assert_eq "plaintext restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
rm -f "$BK"/backups/pithead-backup-*

# A truncated plaintext archive must fail full-stream verification before extraction (#549).
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
plain_trunc_src="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
config_before="$(cat "$BK/config.json")"
env_before="$(cat "$BK/.env")"
head -c "$(($(wc -c <"$plain_trunc_src") / 2))" "$plain_trunc_src" >"$BK/backups/truncated-plain.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$BK/backups/truncated-plain.tar.gz" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "truncated plaintext archive exits non-zero" || bad "truncated plaintext archive exits non-zero" "rc=0"
assert_contains "truncated plaintext archive names integrity failure" "$out" "integrity"
assert_eq "truncated plaintext archive leaves config.json untouched" "$(cat "$BK/config.json")" "$config_before"
assert_eq "truncated plaintext archive leaves .env untouched" "$(cat "$BK/.env")" "$env_before"
rm -f "$BK"/backups/pithead-backup-* "$BK/backups/truncated-plain.tar.gz"

# 7) A failed encrypted backup (openssl dies mid-stream) removes the partial archive.
cat >"$BK/bin/openssl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BK/bin/openssl"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=x ./pithead backup -y 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "failed encrypted backup exits non-zero" || bad "failed encrypted backup exits non-zero" "rc=0"
assert_eq "failed encrypted backup leaves nothing behind" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
rm -f "$BK/bin/openssl"

# 8) An archive that is neither encrypted nor gzip is refused before the overwrite prompt.
printf 'garbage-not-an-archive' >"$BK/backups/bogus.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$BK/backups/bogus.tar.gz" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "garbage archive is refused" || bad "garbage archive is refused" "rc=0"
assert_contains "garbage archive names the problem" "$out" "Not a pithead backup archive"
rm -f "$BK"/backups/bogus.tar.gz

# 9) Restore of an encrypted archive with no passphrase available (piped empty stdin) fails clean.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
out="$(cd "$BK" && printf '' | PATH="$BK/bin:$PATH" ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "encrypted restore w/o passphrase exits non-zero" || bad "encrypted restore w/o passphrase exits non-zero" "rc=0"
assert_contains "encrypted restore w/o passphrase explains" "$out" "PITHEAD_BACKUP_PASSPHRASE"
rm -f "$BK"/backups/pithead-backup-*

echo "== black-box: failed plaintext backup restarts a running stack, removes the partial archive (#551) =="
# A failed tar must remove its partial archive and recover the previously running stack.
FB="$SANDBOX/failbackup"
mkdir -p "$FB/build/tari" "$FB/data/tor" "$FB/data/dashboard" "$FB/bin"
cp "$STACK" "$FB/pithead"
cp "$ROOT/build/tari/config.toml.template" "$FB/build/tari/"
cat >"$FB/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >>"${DOCKER_LOG:-/dev/null}"
[ "${PS_FAIL:-0}" != 1 ] || { [ "$1 $2 $3 $5" != "compose ps --status -q" ] || exit 1; }
case "$*" in
  "compose ps --status running -q")
    n=0; [ -z "${PS_COUNT:-}" ] || { [ ! -f "$PS_COUNT" ] || n=$(cat "$PS_COUNT"); n=$((n + 1)); printf '%s' "$n" >"$PS_COUNT"; }
    { [ -z "${ACTIVE_AFTER_PS_COUNT:-}" ] || [ "$n" -gt "$ACTIVE_AFTER_PS_COUNT" ]; } && echo cid123
    ;;
  "compose down"*) [ "${DOWN_FAIL:-0}" != 1 ] || exit 1; [ -z "${STATE_FILE:-}" ] || printf stopped >"$STATE_FILE" ;;
  "compose up"*)
    n=0; [ ! -f "${UP_COUNT:?}" ] || n=$(cat "$UP_COUNT")
    n=$((n + 1)); printf '%s' "$n" >"$UP_COUNT"
    [ "$n" -gt "${UP_FAILS:-0}" ] || exit 1
    [ -z "${STATE_FILE:-}" ] || printf running >"$STATE_FILE"
    ;;
esac
exit 0
EOF
cat >"$FB/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "chown" ]; then [ "${CHOWN_FAIL:-0}" != 1 ]; exit; fi
exec "$@"
EOF
cat >"$FB/bin/tar" <<'EOF'
#!/usr/bin/env bash
[ -z "${TAR_CALLED:-}" ] || : >"$TAR_CALLED"
[ -z "${STATE_FILE:-}" ] || cat "$STATE_FILE" >"${TAR_STATE:?}"
[ "${TAR_FAIL:-1}" = 1 ] && exit 1
exec /usr/bin/tar "$@"
EOF
chmod +x "$FB/bin/docker" "$FB/bin/sudo" "$FB/bin/tar"
cat >"$FB/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=FBTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$FB/config.json"

out="$(cd "$FB" && DOCKER_LOG="$FB/docker.log" UP_COUNT="$FB/up.count" TAR_FAIL=1 PATH="$FB/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "failed plaintext backup (running stack) exits non-zero" || bad "failed plaintext backup (running stack) exits non-zero" "rc=0"
assert_contains "failed plaintext backup names the cause" "$out" "partial archive was removed"
assert_eq "failed plaintext backup leaves no archive behind" "$(ls "$FB"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
assert_contains "failed plaintext backup restarts the stack" "$(cat "$FB/docker.log" 2>/dev/null)" "compose up"

rm -f "$FB/tar.called" "$FB"/backups/pithead-backup-*
out="$(cd "$FB" && PS_FAIL=1 TAR_CALLED="$FB/tar.called" PATH="$FB/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
assert_rc "backup refuses an unknown service state" "$?" "1"
assert_contains "unknown state reports the verification failure" "$out" "could not verify whether stack services are active"
assert_eq "unknown state attempts no archive" "$([ -e "$FB/tar.called" ] && echo yes || echo no)" "no"

rm -f "$FB/docker.log" "$FB/up.count" "$FB/ps.count" "$FB/tar.state"
printf running >"$FB/state"
out="$(cd "$FB" && DOCKER_LOG="$FB/docker.log" UP_COUNT="$FB/up.count" PS_COUNT="$FB/ps.count" ACTIVE_AFTER_PS_COUNT=1 STATE_FILE="$FB/state" TAR_STATE="$FB/tar.state" TAR_FAIL=0 PATH="$FB/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
assert_rc "backup handles a stack that starts before its locked recheck" "$?" "0"
assert_eq "the locked recheck stops services before archiving" "$(cat "$FB/tar.state")" "stopped"
assert_eq "the race path restores the active stack" "$(cat "$FB/state")" "running"

rm -f "$FB/docker.log" "$FB/up.count" "$FB/tar.called" "$FB"/backups/pithead-backup-*
out="$(cd "$FB" && DOCKER_LOG="$FB/docker.log" UP_COUNT="$FB/up.count" DOWN_FAIL=1 TAR_CALLED="$FB/tar.called" PATH="$FB/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
assert_rc "a failed stop aborts backup and reports recovery" "$?" "1"
assert_contains "failed stop keeps the original error context" "$out" "failed to stop"
assert_eq "failed stop attempts no archive" "$([ -e "$FB/tar.called" ] && echo yes || echo no)" "no"
assert_eq "failed stop recovers through one normal startup" "$(cat "$FB/up.count")" "1"

rm -f "$FB/docker.log" "$FB/up.count"
out="$(cd "$FB" && DOCKER_LOG="$FB/docker.log" UP_COUNT="$FB/up.count" CHOWN_FAIL=1 TAR_FAIL=0 PATH="$FB/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "archive finalization failure is not reported as success (#1965)" "$rc" "1"
assert_contains "archive finalization failure keeps its specific cause" "$out" "could not assign the archive"
assert_eq "finalization failure still recovers the running stack" "$(cat "$FB/up.count")" "1"
assert_eq "finalization failure retains the completed archive" "$(ls "$FB"/backups/pithead-backup-* 2>/dev/null | wc -l | tr -d ' ')" "1"

rm -f "$FB/docker.log" "$FB/up.count" "$FB"/backups/pithead-backup-*
out="$(cd "$FB" && DOCKER_LOG="$FB/docker.log" UP_COUNT="$FB/up.count" UP_FAILS=1 TAR_FAIL=0 PATH="$FB/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "backup retries one failed post-archive restart (#1965)" "$rc" "0"
assert_contains "restart retry is reported" "$out" "retrying the normal startup path once"
assert_eq "restart retry makes exactly two up attempts" "$(cat "$FB/up.count")" "2"

rm -f "$FB/docker.log" "$FB/up.count" "$FB"/backups/pithead-backup-*
out="$(cd "$FB" && DOCKER_LOG="$FB/docker.log" UP_COUNT="$FB/up.count" UP_FAILS=2 TAR_FAIL=0 PATH="$FB/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "backup reports failure when both restart attempts fail (#1965)" "$rc" "1"
assert_contains "failed restart says the completed archive remains valid" "$out" "archive is valid"
assert_eq "valid archive survives a restart failure" "$(ls "$FB"/backups/pithead-backup-* 2>/dev/null | wc -l | tr -d ' ')" "1"

echo "== black-box: reset-dashboard targets .env dirs, not config.json (#139) =="
# Reset uses live .env dirs; stub sudo records without deleting.
R="$SANDBOX/reset"
mkdir -p "$R/bin" "$R/envdir/dashboard" "$R/envdir/p2pool"
cp "$STACK" "$R/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' >"$R/bin/docker"
cat >"$R/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "[sudo] $*" >> "${SUDO_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$R/bin/docker" "$R/bin/sudo"
cat >"$R/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
DASHBOARD_DATA_DIR=$R/envdir/dashboard
P2POOL_DATA_DIR=$R/envdir/p2pool
EOF
# config.json points the data dirs somewhere ELSE (a path the running stack never used).
printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"data_dir":"%s/CONFIGONLY/p2pool"}, "dashboard":{"data_dir":"%s/CONFIGONLY/dashboard"} }\n' "$WALLET" "$R" "$R" >"$R/config.json"
SUDO_LOG="$R/sudo.log"
: >"$SUDO_LOG"
out="$(cd "$R" && SUDO_LOG="$SUDO_LOG" PATH="$R/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset-dashboard succeeds" "$rc" "0"
sudo_calls="$(cat "$SUDO_LOG")"
assert_contains "reset rm targets the .env dashboard dir" "$sudo_calls" "rm -rf $R/envdir/dashboard"
case "$sudo_calls" in *CONFIGONLY*) bad "reset must ignore the config-only data_dir" "$sudo_calls" ;; *) ok "reset ignores the config-only data_dir" ;; esac

echo "== black-box: reset-dashboard refuses to guess without .env dirs (#139) =="
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node\nHOST_IP=box.lan\n' >"$R/.env"
out="$(cd "$R" && SUDO_LOG=/dev/null PATH="$R/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset refuses with no data dirs in .env" "$rc" "1"
assert_contains "reset refuse message" "$out" "refusing to guess"

echo "== black-box: reset-dashboard's final compose_up_checked is if!-guarded, not bare (#557/#180) =="
# Real pithead must preserve the #180 explanation when reset's guarded Compose pipeline fails (#557).
RD557="$SANDBOX/reset557"
mkdir -p "$RD557/bin" "$RD557/envdir/dashboard" "$RD557/envdir/p2pool"
cp "$STACK" "$RD557/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' >"$RD557/bin/sudo"
cat >"$RD557/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"compose up"*)
    echo "Error response from daemon: Pool overlaps with other one on this address space" >&2
    exit 1
    ;;
esac
exit 0
EOF
chmod +x "$RD557/bin/docker" "$RD557/bin/sudo"
cat >"$RD557/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
NETWORK_SUBNET=172.28.0.0/24
DASHBOARD_DATA_DIR=$RD557/envdir/dashboard
P2POOL_DATA_DIR=$RD557/envdir/p2pool
EOF
printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"} }\n' "$WALLET" >"$RD557/config.json"
out="$(cd "$RD557" && PATH="$RD557/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset-dashboard: compose failure still exits 1 (fail-closed unchanged)" "$rc" "1"
assert_contains "reset-dashboard: #180 subnet-collision explanation reaches the operator (#557)" \
    "$out" "Docker refused the stack's bridge subnet"
assert_contains "reset-dashboard: crafted failure message names the retry command" "$out" "did NOT come back up"
