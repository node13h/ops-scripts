#!/usr/bin/env bash


secure_volumes_set_up_bind_mounts () {
    declare base_dir="$1"

    shift

    log_info "Setting up bind mounts"

    declare dir mountpoint

    for mountpoint in "$@"; do
        dir="${base_dir%/}/${mountpoint#/}"

        mkdir -p "$dir"

        systemd_set_up_mount \
            "$dir" \
            "$mountpoint" \
            none \
            bind \
            "Mount ${dir} on ${mountpoint}" \
            FALSE
    done
}
