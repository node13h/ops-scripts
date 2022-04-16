#!/usr/bin/env bash

# MIT license
# Copyright 2022 Sergej Alikov <sergej.alikov@gmail.com>

_DOC='Create an LV on an encrypted file-backed loop device and bind mount it onto specified directories'

set -euo pipefail


secrets () {
    declare address="$1"

    declare -A SECRETS=()

    SECRETS['LUKS/secure-loop-pv']=$("$PASS_CMD" "${PASS_NAMESPACE}/${address}/${LOOP_PV_SECRET_NAME}")

    declared_var SECRETS
}


usage () {
    exit_code="${1:-0}"
    error_message="${2:-}"

    if [[ -n "$error_message" ]]; then
        printf 'ERROR: %s\n\n' "$error_message" >&2
    fi

    cat <<EOM
${_DOC}

Usage: ${0} CONFIG-FILE TARGET
       ${0} --help
       ${0} --version

CONFIG-FILE example:

---- 8< cut here 8<----------------
# Defaults are commented out.

#PASS_NAMESPACE=LUKS

#PASS_CMD=pass

# The location of the encrypted file to create, and map a loop device to.
#LOOP_PV_FILE=/var/lib/secure/loop-pv

# Leave empty for auto (free space minus 8G).
LOOP_PV_SIZE_GB=100

#LOOP_PV_SECRET_NAME=secure-loop-pv

#VG_NAME=secure

#BLOCK_OVERLAY_LV_NAME=block-overlay

# Leave empty for auto (data volume size minus 1G).
BLOCK_OVERLAY_LV_SIZE_GB=2

#BLOCK_OVERLAY_LV_FS=xfs
#BLOCK_OVERLAY_LV_MOUNT_OPTS=relatime

# List of directories to bind mount secure overlay on.
declare -a BIND_MOUNT_OVERLAY_DIRS=(
    /etc/ipsec
    /var/lib/pgsql
)

---- 8< cut here 8<----------------

EOM

    exit "$exit_code"
}


if ! (return 2> /dev/null); then

    if ! command -v automated-config.sh >/dev/null; then
        echo "Please install automated from https://github.com/node13h/automated" >&2
        exit 1
    fi

    if ! command -v automated-extras-config.sh >/dev/null; then
        echo "Please install automated-extras from https://github.com/node13h/automated-extras" >&2
        exit 1
    fi

    # Load the AUTOMATED_LIBDIR value.
    # shellcheck disable=SC1091
    source automated-config.sh

    # Load libautomated for functions like declared_var() and log_debug().
    # shellcheck disable=SC1091
    source "${AUTOMATED_LIBDIR%/}/libautomated.sh"

    # Load the AUTOMATED_EXTRAS_LIBDIR value.
    # shellcheck disable=SC1091
    source automated-extras-config.sh

    # readlink -f should be okay for us :) (this repo is Linux scripts only).
    canonical_bash_source=$(readlink -f "${BASH_SOURCE[0]}")
    canonical_bash_source_dir=$(dirname "$canonical_bash_source")

    # Load the AUTOMATED_OPS_SCRIPTS_LIBDIR value.
    # We locate automated-ops-scripts-config.sh from the same directory as this
    # script to support multiple versions with only one symlinked to bin/.
    # shellcheck disable=SC1091
    source "${canonical_bash_source_dir%/}/automated-ops-scripts-config.sh"

    # Config defaults
    PASS_NAMESPACE=LUKS
    PASS_CMD=pass
    LOOP_PV_SECRET_NAME=secure-loop-pv

    while [[ "$#" -gt 0 ]]; do

        case "$1" in
            --help)
                usage
                ;;
            --version)
                printf \
                    'secure-block-overlay.sh from automated-ops-scripts version %s\n' \
                    "$AUTOMATED_OPS_SCRIPTS_VERSION"
                exit 0
                ;;
            *)
                break
                ;;
        esac

        shift
    done

    [[ "$#" -eq 2 ]] || usage 1

    CONFIG_FILE="$1"
    TARGET="$2"

    shift 2

    # Load only variables we're interested in locally from the config.
    # shellcheck disable=SC1090
    source <(
        set -e

        # shellcheck disable=SC1090
        source "$CONFIG_FILE"

        declare var
        for var in PASS_NAMESPACE PASS_CMD LOOP_PV_SECRET_NAME; do
            if [[ -v "$var" ]]; then
                declared_var "$var"
            fi
        done
    )

    export -f secrets
    export PASS_NAMESPACE
    export PASS_CMD
    export LOOP_PV_SECRET_NAME

    # shellcheck disable=SC2016
    exec automated.sh \
         -s \
         -m 'secrets "$(target_address_only "$target")"' \
         -l "${AUTOMATED_EXTRAS_LIBDIR}/automated-extras-config.sh" \
         -l "${AUTOMATED_EXTRAS_LIBDIR}/automated-extras.sh" \
         -l "${AUTOMATED_EXTRAS_LIBDIR}/os.sh" \
         -l "${AUTOMATED_EXTRAS_LIBDIR}/lvm.sh" \
         -l "${AUTOMATED_EXTRAS_LIBDIR}/systemd.sh" \
         -l "${AUTOMATED_OPS_SCRIPTS_LIBDIR}/automated-ops-scripts.sh" \
         -l "${AUTOMATED_OPS_SCRIPTS_LIBDIR}/secure-volumes.sh" \
         -l "${BASH_SOURCE[0]}" \
         -l "$CONFIG_FILE" \
         -c main \
         -- \
         "$TARGET"
fi

# Everything beyond this point will only be executed on the target (see exec above)


supported_automated_versions 0.3
supported_automated_extras_versions 0.3


LOOP_PV_FILE=/var/lib/secure/loop-pv

# Leave empty for auto.
LOOP_PV_SIZE_GB=

VG_NAME=secure

BLOCK_OVERLAY_LV_NAME=block-overlay

# Leave empty for auto.
BLOCK_OVERLAY_LV_SIZE_GB=

BLOCK_OVERLAY_LV_FS=xfs
BLOCK_OVERLAY_LV_MOUNT_OPTS=relatime


# List of directories to bind mount secure overlay on.
declare -a BIND_MOUNT_OVERLAY_DIRS=()


set_up_secure_block_overlay () {
    log_info "Setting up the encrypted loop-volume at ${LOOP_PV_FILE}"

    declare -i loop_pv_size_gb

    # Auto-calculate the size of the encrypted data volume
    if [[ -z "${LOOP_PV_SIZE_GB:-}" ]]; then
        declare loop_pv_file_dir
        loop_pv_file_dir=$(dirname "$LOOP_PV_FILE")
        mkdir -p "$loop_pv_file_dir"

        declare -i parent_size_gb
        parent_size_gb=$(LC_ALL=C df --output=size --block-size=1G "$loop_pv_file_dir" | sed /1G-blocks/d | awk '{ print $1 }')
        # Keep some free space for OS and growth
        loop_pv_size_gb="$((parent_size_gb-8))"
    else
        loop_pv_size_gb="$LOOP_PV_SIZE_GB"
    fi

    lvm_set_up_encrypted_volume_file \
        "decrypted-${VG_NAME}-loop-pv" \
        "$LOOP_PV_FILE" \
        "${loop_pv_size_gb}G" \
        "${SECRETS['LUKS/secure-loop-pv']}" \
        "$VG_NAME"

    declare -i block_overlay_lv_size_gb

    if [[ -z "${BLOCK_OVERLAY_LV_SIZE_GB:-}" ]]; then
        # Leave 1GB free for expansion
        block_overlay_lv_size_gb=$((loop_pv_size_gb-1))
    else
        block_overlay_lv_size_gb="$BLOCK_OVERLAY_LV_SIZE_GB"
    fi

    if ! lvm_lv_exists "${VG_NAME}/${BLOCK_OVERLAY_LV_NAME}"; then
        log_info "Creating ${BLOCK_OVERLAY_LV_NAME} secure LV"

        lvcreate -y -L "${block_overlay_lv_size_gb}G" -n "$BLOCK_OVERLAY_LV_NAME" "$VG_NAME"
        "mkfs.${BLOCK_OVERLAY_LV_FS}" "/dev/${VG_NAME}/${BLOCK_OVERLAY_LV_NAME}"
    fi

    log_info 'Ensuring secure filesystems are mounted'

    systemd_set_up_mount \
        "/dev/${VG_NAME}/${BLOCK_OVERLAY_LV_NAME}" \
        "/mnt/${VG_NAME}-${BLOCK_OVERLAY_LV_NAME}" \
        "$BLOCK_OVERLAY_LV_FS" \
        "$BLOCK_OVERLAY_LV_MOUNT_OPTS" \
        'Encrypted bind-mount overlay storage'
}


main () {

    if ! systemd_is_active; then
        throw 'Only SystemD systems are supported'
    fi

    (
        if ! flock --verbose -x -n "$LOCK_FD"; then
            throw "Another instance of this script is already running"
        fi

        # Close $LOCK_FD to prevent it from leaking into sub-processes (conmon
        # specifically) which may stay resident and retain the lock.
        exec {LOCK_FD}>&-

        lvm_install_packages

        # TODO: Check if all required variables were set.

        set_up_secure_block_overlay
        secure_volumes_set_up_bind_mounts /mnt/secure-block-overlay "${BIND_MOUNT_OVERLAY_DIRS[@]}"

    ) {LOCK_FD}>/var/lock/secure-block-overlay
}
