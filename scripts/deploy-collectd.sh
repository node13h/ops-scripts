#!/usr/bin/env bash

# MIT license
# Copyright 2017 Sergej Alikov <sergej.alikov@gmail.com>


set -euo pipefail

POSITIONAL_ARGS=('CA_NAME' 'RIEMANN_SERVER')


display_usage_and_exit () {
    cat <<EOF
Usage: ${0} ${POSITIONAL_ARGS[*]//_/-} [AUTOMATED-ARGS]

EOF

    exit "${1:-0}"
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

local_main () {
    local arg

    local -a args=("${POSITIONAL_ARGS[@]}")

    [[ "${#}" -gt "${#args[@]}" ]] || display_usage_and_exit 1

    while [[ "${#}" -gt 0 ]]; do

        [[ "${#args[@]}" -gt 0 ]] || break

        arg="${1}"
        shift

        case "${arg}" in

            -h|--help|help|'')
                display_usage_and_exit
                ;;

            *)
                declare -g "${args[0]}"="${arg}"

                args=("${args[@]:1}")
                ;;
        esac
    done

    PASS_NAMESPACE="${PASS_NAMESPACE:-CA/${CA_NAME}}"
    CA_DIR="${CA_DIR:-${HOME%/}/CA}"
    PKI_DIR="${PKI_DIR:-${CA_DIR%/}/${CA_NAME}/pki}"

    export -f decrypted_rsa_key
    export -f drag_ssl_files

    export CA_NAME
    export RIEMANN_SERVER

    exec automated.sh \
         -s \
         -e CA_NAME \
         -e RIEMANN_SERVER \
         -m "drag_ssl_files \"\${target}\" $(quoted "${PASS_NAMESPACE}") $(quoted "${PKI_DIR}")" \
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
    drop ssl-key "${FACT_PKI_KEYS%/}/${RIEMANN_SERVER}-collectd-client.key" 0600
    drop ssl-cert "${FACT_PKI_CERTS%/}/${RIEMANN_SERVER}-collectd-client.crt" 0644
    drop ssl-cacert "${FACT_PKI_CERTS%/}/${CA_NAME}.crt" 0644
}

collectd_sys_config () {
    cat <<"EOF"
LoadPlugin cpu
LoadPlugin df
LoadPlugin load
LoadPlugin memory
LoadPlugin processes
LoadPlugin swap
EOF
}

collectd_interface_config () {
    cat <<EOF
LoadPlugin interface

<Plugin "interface">
  Interface "lo"
  Interface "sit0"
  IgnoreSelected true
</Plugin>
EOF
}

collectd_riemann_write_config () {
    local riemann_server="${1}"
    local key="${2}"
    local cert="${3}"
    local cacert="${4}"

    cat <<EOF
LoadPlugin write_riemann

<Plugin "write_riemann">
    <Node "local">
        Host "${riemann_server}"
        Port "5554"
        Protocol TLS
        TLSCertFile "${cert}"
        TLSCAFile "${cacert}"
        TLSKeyFile "${key}"
        StoreRates true
        AlwaysAppendDS false
    </Node>
    Tag "collectd"
</Plugin>

<Target "write">
    Plugin "write_riemann/local"
</Target>
EOF
}

setup_collectd () {
    msg "Setting up CollectD"

    packages_ensure present collectd collectd-write_riemann

    if [[ "${FACT_OS_FAMILY}" = "RedHat" ]]; then
        cmd setsebool -P collectd_tcp_network_connect 1
    fi

    collectd_sys_config | to_file /etc/collectd.d/sys.conf
    collectd_interface_config | to_file /etc/collectd.d/interface.conf

    # shellcheck disable=SC2153
    collectd_riemann_write_config \
        "${RIEMANN_SERVER}" \
        "${FACT_PKI_KEYS%/}/${RIEMANN_SERVER}-collectd-client.key" \
        "${FACT_PKI_CERTS%/}/${RIEMANN_SERVER}-collectd-client.crt" \
        "${FACT_PKI_CERTS%/}/${CA_NAME}.crt" | to_file /etc/collectd.d/riemann.conf

    systemctl -q is-active collectd || cmd systemctl start collectd
}


main () {
    packages_ensure present patch

    drop_ssl_files
    setup_collectd
}
