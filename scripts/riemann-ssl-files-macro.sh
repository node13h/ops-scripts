#!/usr/bin/env bash

# MIT license
# Copyright 2017 Sergej Alikov <sergej.alikov@gmail.com>

set -euo pipefail


display_usage_and_exit () {
    cat <<EOF
Usage: ${0} --help
       ${0} TARGET

Macro for automated.sh to enable transporting of certificates and keys to remote targets.

ENVIRONMENT VARIABLES

            GET_RIEMANN_CA_CERT_PATH_CMD
            GET_RIEMANN_CERT_PATH_CMD
            GET_RIEMANN_CERT_KEY_PATH_CMD
            GET_RIEMANN_CERT_KEY_PASSPHRASE_CMD
EOF

    exit "${1:-0}"
}


if [[ -n "${BASH_SOURCE[0]:-}" && "${0}" = "${BASH_SOURCE[0]}" ]]; then

    [[ "${#}" -eq 1 ]] || display_usage_and_exit 1
    ! [[ "${1}" = '--help' ]] || display_usage_and_exit

    # shellcheck disable=SC1091
    source automated-config.sh
    # shellcheck disable=SC1090
    source "${AUTOMATED_LIBDIR%/}/libautomated.sh"
    # shellcheck disable=SC1091
    source automated-extras-config.sh
    # shellcheck disable=SC1090
    source "${AUTOMATED_EXTRAS_LIBDIR%/}/ssl.sh"

    TARGET="${1}"

    GET_RIEMANN_CA_CERT_PATH_CMD="${GET_RIEMANN_CA_CERT_PATH_CMD:-interactive_answer}"
    GET_RIEMANN_CERT_PATH_CMD="${GET_RIEMANN_CERT_PATH_CMD:-interactive_answer}"
    GET_RIEMANN_CERT_KEY_PATH_CMD="${GET_RIEMANN_CERT_KEY_PATH_CMD:-interactive_answer}"
    GET_RIEMANN_CERT_KEY_PASSPHRASE_CMD="${GET_RIEMANN_CERT_KEY_PASSPHRASE_CMD:-interactive_secret}"

    declare passphrase cacert cert key address

    address=$(target_address_only "${TARGET}")

    cacert=$("${GET_RIEMANN_CA_CERT_PATH_CMD}" "${address}" 'CA certificate')
    cert=$("${GET_RIEMANN_CERT_PATH_CMD}" "${address}" 'Certificate')
    key=$("${GET_RIEMANN_CERT_KEY_PATH_CMD}" "${address}" 'Key')

    passphrase=$("${GET_RIEMANN_CERT_KEY_PASSPHRASE_CMD}" "${address}" "Passphrase for ${key}")

    file_as_function <(decrypted_rsa_key "${key}" "${passphrase}") riemann-ssl-key
    file_as_function "${cert}" riemann-ssl-cert
    file_as_function "${cacert}" riemann-ssl-cacert
fi
