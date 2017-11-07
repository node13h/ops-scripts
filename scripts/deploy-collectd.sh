#!/usr/bin/env bash

# MIT license
# Copyright 2017 Sergej Alikov <sergej.alikov@gmail.com>

set -euo pipefail


display_usage_and_exit () {
    cat <<EOF
Usage: ${0} RIEMANN-SERVER [AUTOMATED-ARGS]

Deploy the CollectD instance to target(s) and configure it to send
the data to a RIEMANN instance (over the SSL).

AUTOMATING

        Run riemann-ssl-files-macro.sh --help to see more help on
        environment variables.
EOF

    exit "${1:-0}"
}


# For convenience this file is structured in such a way that the locally executed
# functions are above this block and the remotely executed functions are below
if [[ -n "${BASH_SOURCE[0]:-}" && "${0}" = "${BASH_SOURCE[0]}" ]]; then

    [[ "${#}" -gt 1 ]] || display_usage_and_exit 1

    # shellcheck disable=SC1091
    source automated-extras-config.sh

    export RIEMANN_SERVER="${1}"
    shift

    # shellcheck disable=SC2016
    exec automated.sh \
         -s \
         -e RIEMANN_SERVER \
         -m 'riemann-ssl-files-macro.sh "${target}"' \
         -l "${BASH_SOURCE[0]}" \
         -l "${AUTOMATED_EXTRAS_LIBDIR}" \
         "${@}"

fi

declare -A SYSTEMCTL_ACTIONS

drop_ssl_files () {
    drop riemann-ssl-key "${FACT_PKI_KEYS%/}/${RIEMANN_SERVER}-collectd-client.key" 0600
    drop riemann-ssl-cert "${FACT_PKI_CERTS%/}/${RIEMANN_SERVER}-collectd-client.crt" 0644
    drop riemann-ssl-cacert "${FACT_PKI_CERTS%/}/${RIEMANN_SERVER}-collectd-ca.crt" 0644
}

collectd_sys_config () {
    cat <<"EOF"
LoadPlugin cpu
LoadPlugin df
LoadPlugin load
LoadPlugin memory
LoadPlugin processes
LoadPlugin swap

<Plugin "df">
  FSType "tmpfs"
  FSType "devtmpfs"
  IgnoreSelected true
</Plugin>
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
        TTLFactor 5.0
        BatchFlushTimeout 10
    </Node>
    Tag "collectd"
</Plugin>

<Target "write">
    Plugin "write_riemann/local"
</Target>
EOF
}

handle_riemann_config_change () {
    ! systemctl -q is-active collectd || SYSTEMCTL_ACTIONS[collectd]=try-restart
}

setup_collectd () {
    msg "Setting up CollectD"

    packages_ensure present collectd collectd-write_riemann collectd-sensors

    if [[ "${FACT_OS_FAMILY}" = "RedHat" ]]; then
        cmd setsebool -P collectd_tcp_network_connect 1
    fi

    to_file /etc/collectd.d/sys.conf handle_riemann_config_change < <(collectd_sys_config)
    to_file /etc/collectd.d/interface.conf handle_riemann_config_change < <(collectd_interface_config)

    # shellcheck disable=SC2153
    to_file /etc/collectd.d/riemann.conf handle_riemann_config_change < <(
        collectd_riemann_write_config \
            "${RIEMANN_SERVER}" \
            "${FACT_PKI_KEYS%/}/${RIEMANN_SERVER}-collectd-client.key" \
            "${FACT_PKI_CERTS%/}/${RIEMANN_SERVER}-collectd-client.crt" \
            "${FACT_PKI_CERTS%/}/${RIEMANN_SERVER}-collectd-ca.crt"
    )

    cmd systemctl enable collectd
    systemctl -q is-active collectd || cmd systemctl start collectd
}


main () {
    local service

    packages_ensure present patch

    drop_ssl_files
    setup_collectd

    [[ "${#SYSTEMCTL_ACTIONS[@]}" -eq 0 ]] || for service in "${!SYSTEMCTL_ACTIONS[@]}"; do
        cmd systemctl "${SYSTEMCTL_ACTIONS[${service}]}" "${service}"
    done
}
