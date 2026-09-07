# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
echo "== black-box: administrative restore stages and constrains archives =="
CR="$SANDBOX/cli-restore"
ROOTS="$CR/roots"
mkdir -p "$ROOTS/${BK#/}/data/tor" "$ROOTS/${BK#/}/data/dashboard" "$CR/tmp"
cp "$BK/config.json" "$BK/.env" "$ROOTS/${BK#/}/"
printf 'CADDY-SAFE\n' >"$ROOTS/${BK#/}/Caddyfile"
printf 'KEY-SAFE\n' >"$ROOTS/${BK#/}/data/tor/hs_ed25519_secret_key"
printf 'DB-SAFE\n' >"$ROOTS/${BK#/}/data/dashboard/dashboard.db"
chmod 644 "$ROOTS/${BK#/}/config.json" "$ROOTS/${BK#/}/.env" \
    "$ROOTS/${BK#/}/Caddyfile" "$ROOTS/${BK#/}/data/tor/hs_ed25519_secret_key" \
    "$ROOTS/${BK#/}/data/dashboard/dashboard.db"
CR_ARCHIVE="$CR/valid.tar.gz"
cr_archive() {
    tar -czf "$1" -C "$ROOTS" "${BK#/}/config.json" "${BK#/}/.env" "${BK#/}/Caddyfile" "${BK#/}/data/tor" "${BK#/}/data/dashboard"
}
cr_archive "$CR_ARCHIVE"

cat >"$BK/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"compose ps --status "*)
    n=0
    [ -z "${PS_COUNT:-}" ] || { [ ! -f "$PS_COUNT" ] || n=$(cat "$PS_COUNT"); n=$((n + 1)); printf '%s' "$n" >"$PS_COUNT"; }
    { [ -z "${ACTIVE_AFTER_PS_COUNT:-}" ] || [ "$n" -gt "$ACTIVE_AFTER_PS_COUNT" ]; } &&
        [ "$*" = "compose ps --status ${STACK_STATUS:-stopped} -q" ] && echo cid123
    ;;
esac
exit 0
EOF
chmod +x "$BK/bin/docker"

out="$(cd "$BK" && STACK_STATUS=paused PATH="$BK/bin:$PATH" ./pithead restore -y "$CR_ARCHIVE" 2>&1)"
assert_rc "restore refuses a paused service" "$?" 1
assert_contains "live restore names the stop requirement" "$out" "pithead down"

printf 'CADDY-LIVE\n' >"$BK/Caddyfile"
rm -f "$CR/ps.count"
out="$(cd "$BK" && PS_COUNT="$CR/ps.count" ACTIVE_AFTER_PS_COUNT=3 STACK_STATUS=running PATH="$BK/bin:$PATH" ./pithead restore -y "$CR_ARCHIVE" 2>&1)"
assert_rc "restore rechecks service state under its lock" "$?" 1
assert_eq "late service start prevents commit" "$(cat "$BK/Caddyfile")" CADDY-LIVE

mkdir -p "$ROOTS/${SANDBOX#/}"
printf ATTACK >"$ROOTS/${SANDBOX#/}/victim"
tar -czf "$CR/outside.tar.gz" -C "$ROOTS" "${BK#/}/config.json" "${BK#/}/.env" "${SANDBOX#/}/victim"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$CR/outside.tar.gz" 2>&1)"
assert_rc "restore rejects a regular member outside its destination set" "$?" 1
assert_contains "outside-member refusal names the boundary" "$out" "outside this appliance"

mkdir -p "$CR/wrong/${BK#/}"
cp "$BK/config.json" "$BK/.env" "$CR/wrong/${BK#/}/"
mkdir "$CR/wrong/${BK#/}/Caddyfile"
tar -czf "$CR/wrong-type.tar.gz" -C "$CR/wrong" "${BK#/}"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$CR/wrong-type.tar.gz" 2>&1)"
assert_rc "restore rejects a directory in place of Caddyfile" "$?" 1

printf VICTIM >"$CR/victim"
rm -f "$BK/data/tor/hs_ed25519_secret_key"
ln -s "$CR/victim" "$BK/data/tor/hs_ed25519_secret_key"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$CR_ARCHIVE" 2>&1)"
assert_rc "restore rejects a nested destination symlink" "$?" 1
assert_eq "nested destination victim stays untouched" "$(cat "$CR/victim")" VICTIM
rm -f "$BK/data/tor/hs_ed25519_secret_key"

printf '{bad json' >"$ROOTS/${BK#/}/config.json"
cr_archive "$CR/bad-config.tar.gz"
out="$(cd "$BK" && TMPDIR="$CR/tmp" PATH="$BK/bin:$PATH" ./pithead restore -y "$CR/bad-config.tar.gz" 2>&1)"
assert_rc "invalid staged config is refused" "$?" 1
assert_eq "failed restore removes its private stage" "$(find "$CR/tmp" -mindepth 1 -print -quit)" ""

cp "$BK/config.json" "$ROOTS/${BK#/}/config.json"
chmod 644 "$ROOTS/${BK#/}/config.json"
cr_archive "$CR_ARCHIVE"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$CR_ARCHIVE" 2>&1)"
assert_rc "validated administrative restore succeeds" "$?" 0
assert_eq "restored config is owner-only" "$(file_mode "$BK/config.json")" 600
assert_eq "restored env is owner-only" "$(file_mode "$BK/.env")" 600
assert_eq "restored Caddyfile is owner-only" "$(file_mode "$BK/Caddyfile")" 600
assert_eq "restored onion key is owner-only" "$(file_mode "$BK/data/tor/hs_ed25519_secret_key")" 600
assert_eq "restored database is owner-only" "$(file_mode "$BK/data/dashboard/dashboard.db")" 600
unset -f cr_archive
unset CR ROOTS CR_ARCHIVE out
