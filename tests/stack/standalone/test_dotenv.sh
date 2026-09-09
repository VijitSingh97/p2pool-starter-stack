#!/usr/bin/env bash
# Verify literal strings against Compose's real parser without starting a service.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=lib/pithead/19-small-utilities.sh
source "$ROOT/lib/pithead/19-small-utilities.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
literal=$' single\'quote "double" \\path\\ $LABEL\t# text\nnext '
printf 'LITERAL=%s\n' "$(dotenv_render_value "$literal")" >"$tmp/fixture.env"
printf '%s\n' '{"services":{"fixture":{"image":"fixture:local","environment":{"LITERAL":"${LITERAL}"}}}}' >"$tmp/compose.json"
resolved="$(docker compose --env-file "$tmp/fixture.env" -f "$tmp/compose.json" config --format json)"
# config emits another Compose document, so literal dollar signs are escaped again.
expected="${literal//\$/\$\$}"
jq -e --arg expected "$expected" '.services.fixture.environment.LITERAL == $expected' <<<"$resolved" >/dev/null
echo "  ✓ Compose preserves literal dotenv strings"
