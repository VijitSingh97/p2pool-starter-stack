# shellcheck shell=bash
# Sourced artifact-reference helpers for verify-image.sh and their focused self-tests.

# Write the compose file named by the image's COMPOSE_SOURCE stamp (#1215): the tree's copy for
# `tree`, or the staged commit's copy for `tag NAME SHA`. Missing or malformed stamps fail closed.
compose_reference() { # <image-root> <out-file>
    local kind tag sha extra trailing
    {
        read -r kind tag sha extra || return 1
        if IFS= read -r trailing || [ -n "$trailing" ]; then return 1; fi
    } 2>/dev/null <"$1/opt/pithead/COMPOSE_SOURCE" || return 1
    case "$kind" in
    tree) [ -z "$tag$sha$extra" ] && cp ./docker-compose.yml "$2" || return 1 ;;
    tag) [ -n "$sha" ] && [ -z "$extra" ] && [ "$tag" = "v$(tr -d ' \t\r\n' <"$1/opt/pithead/VERSION")" ] && git show "$sha:docker-compose.yml" >"$2" 2>/dev/null || return 1 ;;
    *) return 1 ;;
    esac
}

# pithead-data-reset runs these behind `|| true`, so both must be baked into the image (#1069 W11).
data_reset_repair_tools_present() { # <image-root> — 0 iff both tools are executable
    local root="$1"
    { [ -x "$root/usr/sbin/e2fsck" ] || [ -x "$root/sbin/e2fsck" ]; } &&
        { [ -x "$root/usr/sbin/mkfs.ext4" ] || [ -x "$root/sbin/mkfs.ext4" ]; }
}

# Compare the wizard implementation inside an OCI/Docker archive to this checkout.
# The entry module became a package; comparing only __init__.py would miss stale code.
wizard_server_matches() { # <container-archive> <expected-server.py>
    local archive="$1" expected="$2" tmp layer member reason rc=1
    tmp=$(mktemp -d) || return 1
    reason="container archive could not be unpacked"
    if tar -xzf "$archive" -C "$tmp" 2>"$tmp/untar.err"; then
        reason="no layer lists mining_dashboard/wizard/server.py"
        for layer in "$tmp"/blobs/sha256/* "$tmp"/*/layer.tar; do
            [ -f "$layer" ] || continue
            # Consume the listing fully: an early exit can SIGPIPE tar under pipefail.
            member=$(tar -tf "$layer" 2>/dev/null | grep 'mining_dashboard/wizard/server\.py$' | sed -n '1p')
            [ -n "$member" ] || continue
            if tar -xOf "$layer" "$member" >"$tmp/server.py" 2>"$tmp/extract.err"; then
                if cmp -s "$tmp/server.py" "$expected"; then
                    rc=0
                else
                    reason="shipped wizard/server.py differs from the tree: $(cmp "$tmp/server.py" "$expected" 2>&1 | head -1)"
                fi
                break
            fi
            reason="tar -xOf $member from $(basename "$layer" | cut -c1-12) failed: $(head -c 120 "$tmp/extract.err" | tr -c '[:print:]' '?')"
        done
    else
        reason="tar -xzf $(basename "$archive") failed: $(head -c 120 "$tmp/untar.err" | tr -c '[:print:]' '?')"
    fi
    [ "$rc" -eq 0 ] || printf '     · %s\n' "$reason"
    rm -rf "$tmp"
    return "$rc"
}
