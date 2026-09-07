# shellcheck shell=bash
boot_label_serial_verdict() { # <serial-log> <version> <current-slot> <previous-slot>
    local log="$1" version="$2" current="$3" previous="$4"
    grep -Fq "Pithead $version (slot $current, current)" "$log" 2>/dev/null &&
        grep -Fq "Pithead $version (slot $previous, previous)" "$log" 2>/dev/null || {
        printf 'serial menu did not name Pithead %s as slot %s current and slot %s previous' \
            "$version" "$current" "$previous"
        return 1
    }
    printf 'serial menu names Pithead %s as slot %s current and slot %s previous' \
        "$version" "$current" "$previous"
}
