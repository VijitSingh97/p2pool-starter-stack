#!/usr/bin/env bash
# Exercise the real archive comparison without an image mount or a running container.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/verify-image-artifact-helpers.sh
source "$HERE/../../os/verify-image-artifact-helpers.sh"
echo "== verify-image: wizard package archive matches the checkout =="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/layer/app/mining_dashboard/wizard" "$TMP/image/blobs/sha256"
printf 'current wizard\n' >"$TMP/expected.py"
cp "$TMP/expected.py" "$TMP/layer/app/mining_dashboard/wizard/server.py"
pack() {
    tar -cf "$TMP/image/blobs/sha256/layer" -C "$TMP/layer" app
    tar -czf "$TMP/image.tar.gz" -C "$TMP/image" blobs
}
check() {
    local name="$1" want="$2" rc=0
    wizard_server_matches "$TMP/image.tar.gz" "$TMP/expected.py" >"$TMP/result" || rc=$?
    if [ "$rc" -ne "$want" ]; then
        echo "FAIL: $name (expected $want, got $rc)"
        cat "$TMP/result"
        exit 1
    fi
    echo "PASS: $name"
}
pack
check 'current package server matches' 0
printf 'stale wizard\n' >"$TMP/layer/app/mining_dashboard/wizard/server.py"
pack
check 'stale server fails' 1
rm "$TMP/layer/app/mining_dashboard/wizard/server.py"
cp "$TMP/expected.py" "$TMP/layer/app/mining_dashboard/wizard.py"
pack
check 'legacy wizard.py does not stand in for the package server' 1
cp "$TMP/expected.py" "$TMP/layer/app/mining_dashboard/wizard/server.py"
pack
rm "$TMP/expected.py"
check 'missing checkout source fails' 1
printf 'invalid archive\n' >"$TMP/image.tar.gz"
check 'invalid archive fails' 1
