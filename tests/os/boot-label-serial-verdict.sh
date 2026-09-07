# shellcheck shell=bash
boot_label_serial_verdict() { # <serial-log> <byte-offset> <version> <current-slot> <previous-slot>
    local log="$1" offset="$2" version="$3" current="$4" previous="$5" serial
    [[ "$offset" =~ ^[0-9]+$ ]] || return 1
    serial=$(tail -c "+$((offset + 1))" "$log" 2>/dev/null)
    grep -Fq "Pithead $version (slot $current, current)" <<<"$serial" &&
        grep -Fq "Pithead $version (slot $previous, previous)" <<<"$serial" || {
        printf 'serial menu did not name Pithead %s as slot %s current and slot %s previous' \
            "$version" "$current" "$previous"
        return 1
    }
    printf 'serial menu names Pithead %s as slot %s current and slot %s previous' \
        "$version" "$current" "$previous"
}
