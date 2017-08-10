#!/usr/bin/env bash

# MIT license
# Copyright 2017 Sergej Alikov <sergej.alikov@gmail.com>


set -euo pipefail

POSITIONAL_ARGS=('CA_NAME' 'RIEMANN_SERVER')
DEST_DIR=/opt/riemann-fping
FPING_INTERVAL=10

PING_TARGETS=()


display_usage_and_exit () {
    cat <<EOF
Usage: ${0} [OPTIONS] ${POSITIONAL_ARGS[*]//_/-} [AUTOMATED-ARGS]

Set up rieman-fping on remote targets using automated.sh tool


OPTIONS
        -h,--help                       Show help text and exit.
        --ping ADDRESS                  Ping ADDRESS. At least one is required.
                                        May be specified multiple times.

EXAMPLES

        ${0} \\
          --ping www.google.com \\
          --ping www.kernel.org \\
          'My CA' \\
          riemann.example.com \\
          probe1.example.com \\
          probe2.example.com \\
          -v
EOF

    return "${1:-0}"
}

decrypted_rsa_key () {
    local key_file="${1}"
    local passphrase="${2}"

    openssl rsa -passin stdin -in "${key_file}" <<< "${passphrase}"
}

drag_ssl_files () {
    local target="${1}"
    local pass_namespace="${2}"
    local pki_dir="${3}"

    local passphrase cacert cert key pass_name address

    address=$(target_address_only "${target}")

    cacert="${pki_dir%/}/ca.crt"
    cert="${pki_dir%/}/issued/${address}.crt"
    key="${pki_dir%/}/private/${address}.key"
    pass_name="${pass_namespace%/}/${address}"

    passphrase=$(pass "${pass_name}")

    file_as_function <(decrypted_rsa_key "${key}" "${passphrase}") ssl-key
    file_as_function "${cert}" ssl-cert
    file_as_function "${cacert}" ssl-cacert
}

ping_targets () {
    PING_TARGETS=("${@}")

    declared_var PING_TARGETS
}

local_main () {
    local arg

    local -a args=("${POSITIONAL_ARGS[@]}")

    [[ "${#}" -gt "${#args[@]}" ]] || display_usage_and_exit 1

    while [[ "${#}" -gt 0 ]]; do

        [[ "${#args[@]}" -gt 0 ]] || break

        arg="${1}"
        shift

        case "${arg}" in

            -h|--help)
                display_usage_and_exit
                ;;

            --ping)
                PING_TARGETS+=("${1}")
                shift
                ;;

            *)
                declare -g "${args[0]}"="${arg}"

                args=("${args[@]:1}")
                ;;
        esac
    done

    [[ "${#PING_TARGETS[@]}" -gt 0 ]] || throw "At least one ping target is required"

    PASS_NAMESPACE="${PASS_NAMESPACE:-CA/${CA_NAME}}"
    PKI_DIR="${PKI_DIR:-${HOME}/CA/${CA_NAME}/pki}"

    export -f decrypted_rsa_key
    export -f drag_ssl_files
    export -f ping_targets

    export CA_NAME
    export RIEMANN_SERVER

    exec automated.sh \
         -s \
         -e CA_NAME \
         -e RIEMANN_SERVER \
         -e PING_TARGETS \
         -m "drag_ssl_files \"\${target}\" $(quoted "${PASS_NAMESPACE}") $(quoted "${PKI_DIR}")" \
         -m "ping_targets $(quoted "${PING_TARGETS[@]}")" \
         -l "${BASH_SOURCE[0]}" \
         "${@}"

    echo "${@}"
}


# For convenience this file is structured in such a way that the locally executed
# functions are above this block and the remotely executed functions are below
if [[ -n "${BASH_SOURCE[0]:-}" && "${0}" = "${BASH_SOURCE[0]}" ]]; then

    # Source some useful functions like throw

    # shellcheck disable=SC1091
    source automated-config.sh
    # shellcheck disable=SC1090
    source "${AUTOMATED_LIBDIR%/}/libautomated.sh"

    local_main "${@}"
fi


drop_ssl_files () {
    drop ssl-key "${FACT_PKI_KEYS%/}/${RIEMANN_SERVER}-fping-client.key" 0600
    drop ssl-cert "${FACT_PKI_CERTS%/}/${RIEMANN_SERVER}-fping-client.crt" 0644
    drop ssl-cacert "${FACT_PKI_CERTS%/}/${CA_NAME}.crt" 0644
}

riemann_fping_systemd_service () {
    local command="${1}"
    local user="${2}"
    local server="${3}"
    local port="${4}"
    local protocol="${5}"
    local probe="${6}"
    local interval="${7}"
    local keyfile="${8}"
    local certfile="${9}"
    local ca_certs="${10}"
    shift 10

    cat <<EOF
[Unit]
Description=riemann-fping for the ${server}
After=network.target

[Service]
Type=simple
User=${user}
ExecStart=$(quoted_for_systemd "${command}" --host "${server}" --port "${port}" --protocol "${protocol}" --probe "${probe}" --interval "${interval}" --keyfile "${keyfile}" --certfile "${certfile}" --ca-certs "${ca_certs}" "${@}")
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
}

refresh_systemd_service () {
    local unit_file="${1}"

    local service_name

    service_name=$(basename "${unit_file}")

    cmd systemctl daemon-reload

    ! systemctl -q is-active "${service_name}" || cmd systemctl restart "${service_name}"
}

setup_riemann_fping () {
    local service_name="fping-to-${RIEMANN_SERVER}"

    msg "Setting up riemann-fping"

    packages_ensure absent python-virtualenv
    packages_ensure present python34 python34-pip fping

    cmd pip3 install virtualenv

    if ! getent passwd riemann-fping >/dev/null; then
        cmd useradd --system riemann-fping
    fi

    cmd chown riemann-fping:riemann-fping "${FACT_PKI_KEYS%/}/${RIEMANN_SERVER}-fping-client.key"

    if ! [[ -d "${DEST_DIR}" ]]; then
        cmd virtualenv -p python3 "${DEST_DIR}"

        "${DEST_DIR%/}/bin/pip3" install riemann-fping
    fi

    riemann_fping_systemd_service \
        "${DEST_DIR%/}/bin/riemann-fping" \
        riemann-fping \
        "${RIEMANN_SERVER}" \
        5554 \
        tls \
        "$(target_address_only "${CURRENT_TARGET}")" \
        "${FPING_INTERVAL}" \
        "${FACT_PKI_KEYS%/}/${RIEMANN_SERVER}-fping-client.key" \
        "${FACT_PKI_CERTS%/}/${RIEMANN_SERVER}-fping-client.crt" \
        "${FACT_PKI_CERTS%/}/${CA_NAME}.crt" \
        "${PING_TARGETS[@]}" | to_file "/etc/systemd/system/${service_name}.service" refresh_systemd_service

    service_ensure enabled "${service_name}"

    systemctl -q is-active "${service_name}" || cmd systemctl start "${service_name}"

}

main () {
    packages_ensure present patch

    drop_ssl_files
    setup_riemann_fping
}
