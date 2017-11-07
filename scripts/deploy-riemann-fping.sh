#!/usr/bin/env bash

# MIT license
# Copyright 2017 Sergej Alikov <sergej.alikov@gmail.com>

set -euo pipefail


display_usage_and_exit () {
    cat <<EOF
Usage: ${0} [OPTIONS] RIEMANN-SERVER [AUTOMATED-ARGS]

Deploy the riemann-fping instance to target(s) and configure it to send
the data to a RIEMANN instance (over the SSL).

OPTIONS
        -h,--help                       Show help text and exit.
        --ping ADDRESS                  Ping ADDRESS. At least one is required.
                                        May be specified multiple times.

EXAMPLES

        ${0} \\
          --ping www.google.com \\
          --ping www.kernel.org \\
          riemann.example.com \\
          probe1.example.com \\
          probe2.example.com \\
          -v

AUTOMATING

        Run riemann-ssl-files-macro.sh --help to see more help on
        environment variables.
EOF

    exit "${1:-0}"
}

ping_targets () {
    PING_TARGETS=("${@}")

    declared_var PING_TARGETS
}

# For convenience this file is structured in such a way that the locally executed
# functions are above this block and the remotely executed functions are below
if [[ -n "${BASH_SOURCE[0]:-}" && "${0}" = "${BASH_SOURCE[0]}" ]]; then

    [[ "${#}" -gt 1 ]] || display_usage_and_exit 1


    # shellcheck disable=SC1091
    source automated-config.sh
    # shellcheck disable=SC1090
    source "${AUTOMATED_LIBDIR%/}/libautomated.sh"

    # shellcheck disable=SC1091
    source automated-extras-config.sh

    PING_TARGETS=()

    declare arg

    while [[ "${#}" -gt 0 ]]; do

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
                export RIEMANN_SERVER="${arg}"
                break
                ;;
        esac
    done

    export -f ping_targets

    # shellcheck disable=SC2016
    exec automated.sh \
         -s \
         -e RIEMANN_SERVER \
         -m 'riemann-ssl-files-macro.sh "${target}"' \
         -m "ping_targets $(quoted "${PING_TARGETS[@]}")" \
         -l "${BASH_SOURCE[0]}" \
         -l "${AUTOMATED_EXTRAS_LIBDIR}" \
         "${@}"
fi


DEST_DIR=/opt/riemann-fping
FPING_INTERVAL=10


drop_ssl_files () {
    drop riemann-ssl-key "${FACT_PKI_KEYS%/}/${RIEMANN_SERVER}-fping-client.key" 0600
    drop riemann-ssl-cert "${FACT_PKI_CERTS%/}/${RIEMANN_SERVER}-fping-client.crt" 0644
    drop riemann-ssl-cacert "${FACT_PKI_CERTS%/}/${RIEMANN_SERVER}-fping-ca.crt" 0644
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
        "${FACT_PKI_CERTS%/}/${RIEMANN_SERVER}-fping-ca.crt" \
        "${PING_TARGETS[@]}" | to_file "/etc/systemd/system/${service_name}.service" refresh_systemd_service

    service_ensure enabled "${service_name}"

    systemctl -q is-active "${service_name}" || cmd systemctl start "${service_name}"

}

main () {
    packages_ensure present patch

    drop_ssl_files
    setup_riemann_fping
}
