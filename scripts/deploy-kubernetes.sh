#!/usr/bin/env bash

# MIT license
# Copyright 2018 Sergej Alikov <sergej.alikov@gmail.com>
#

# Set up an all-in-one Kubernetes cluster on Fedora
#
# Based on (with some corrections):
#   - https://kubernetes.io/docs/getting-started-guides/fedora/fedora_manual_config/
#   - https://kubernetes.io/docs/getting-started-guides/fedora/flannel_multi_node_cluster/
#
# For every target address create a file named "<TARGET-ADDRESS>-vars.sh" in the
# current directory. This file will be sourced automatically for corresponding
# target. The following variables are supported:
#
# OVERLAY_NETWORK_CIDR [string]
# KUBE_CLUSTER_CIDR [string]
# TRUSTED_SOURCES [array]
#

set -eu
set -o pipefail

certs () {
    local address="$1"

    GET_KUBERNETES_CA_CERT_PATH_CMD="${GET_KUBERNETES_CA_CERT_PATH_CMD:-interactive_answer}"
    GET_KUBERNETES_CERT_PATH_CMD="${GET_KUBERNETES_CERT_PATH_CMD:-interactive_answer}"
    GET_KUBERNETES_CERT_KEY_PATH_CMD="${GET_KUBERNETES_CERT_KEY_PATH_CMD:-interactive_answer}"
    GET_KUBERNETES_CERT_KEY_PASSPHRASE_CMD="${GET_KUBERNETES_CERT_KEY_PASSPHRASE_CMD:-interactive_secret}"

    declare passphrase cacert cert key address

    cacert=$("${GET_KUBERNETES_CA_CERT_PATH_CMD}" "${address}" 'CA certificate')
    cert=$("${GET_KUBERNETES_CERT_PATH_CMD}" "${address}" 'Certificate')
    key=$("${GET_KUBERNETES_CERT_KEY_PATH_CMD}" "${address}" 'Key')

    passphrase=$("${GET_KUBERNETES_CERT_KEY_PASSPHRASE_CMD}" "${address}" "Passphrase for ${key}")

    file_as_function <(decrypted_rsa_key "${key}" "${passphrase}") kubernetes-ssl-key
    file_as_function "${cert}" kubernetes-ssl-cert
    file_as_function "${cacert}" kubernetes-ssl-cacert
}

secrets () {
    local address="${1}"
    local KUBE_ADMIN_PASSPHRASE

    GET_AUTH_PASSPHRASE="${GET_AUTH_PASSPHRASE:-interactive_secret}"
    # shellcheck disable=SC2034
    KUBE_ADMIN_PASSPHRASE=$("${GET_AUTH_PASSPHRASE}" "${address}/kubernetes/admin" 'Kubernetes admin password')

    declared_var KUBE_ADMIN_PASSPHRASE
}

target_settings () {
    local address="${1}"

    local target_config="${address}-vars.sh"

    if [[ -f "${target_config}" ]]; then
        sourced_file "${target_config}"
    else
        confirm "${address}" "${target_config} is missing. Proceed with default settings"
    fi
}

if [[ -n "${BASH_SOURCE[0]:-}" && "${0}" = "${BASH_SOURCE[0]}" ]]; then

    # shellcheck disable=SC1091
    source automated-config.sh
    # shellcheck disable=SC1090
    source "${AUTOMATED_LIBDIR%/}/libautomated.sh"

    # shellcheck disable=SC1091
    source automated-extras-config.sh
    # shellcheck disable=SC1090
    source "${AUTOMATED_EXTRAS_LIBDIR%/}/ssl.sh"

    export -f secrets
    export -f certs
    export -f decrypted_rsa_key
    export -f confirm
    export -f target_settings

    # shellcheck disable=SC2016
    exec automated.sh \
         -s \
         -m 'TARGET_ADDRESS=$(target_address_only "${target}")' \
         -m 'secrets "${TARGET_ADDRESS}"' \
         -m 'certs "${TARGET_ADDRESS}"' \
         -m 'target_settings "${TARGET_ADDRESS}"' \
         -l "${AUTOMATED_EXTRAS_LIBDIR}" \
         -l "${BASH_SOURCE[0]}" \
         "${@}"
fi

# 10.254.0.0/22 is used by Concourse Garden by default
OVERLAY_NETWORK_CIDR="${OVERLAY_NETWORK_CIDR:-10.0.0.0/16}"
KUBE_CLUSTER_CIDR="${KUBE_CLUSTER_CIDR:-10.1.0.0/16}"

declare -a TRUSTED_SOURCES="${TRUSTED_SOURCES:-()}"

declare -A SYSTEMCTL_ACTIONS=()

drop_ssl_files () {
    drop kubernetes-ssl-key '/etc/pki/tls/private/kubernetes.key' 0600
    cmd chown kube:root '/etc/pki/tls/private/kubernetes.key'
    drop kubernetes-ssl-cert '/etc/pki/tls/certs/kubernetes.crt' 0644
    drop kubernetes-ssl-cacert '/etc/pki/tls/certs/kubernetes-ca.crt' 0644
}

kubelet_config () {
    cat <<"EOF"
###
# kubernetes kubelet (minion) config

# The address for the info server to serve on (set to 0.0.0.0 or "" for all interfaces)
KUBELET_ADDRESS="--address=127.0.0.1"

# The port for the info server to serve on
# KUBELET_PORT="--port=10250"

# You may leave this blank to use the actual hostname
KUBELET_HOSTNAME="--hostname-override=127.0.0.1"

# Add your own!
KUBELET_ARGS="--cgroup-driver=systemd --fail-swap-on=false --kubeconfig=/etc/kubernetes/master-kubeconfig.yaml --require-kubeconfig"
EOF
}

apiserver_config () {
    cat <<EOF
###
# kubernetes system config
#
# The following values are used to configure the kube-apiserver
#

# The address on the local server to listen to.
KUBE_API_ADDRESS="--insecure-bind-address=127.0.0.1"

# The port on the local server to listen on.
# KUBE_API_PORT="--port=8080"

# Port minions listen on
# KUBELET_PORT="--kubelet-port=10250"

# Comma separated list of nodes in the etcd cluster
KUBE_ETCD_SERVERS="--etcd-servers=http://127.0.0.1:2379,http://127.0.0.1:4001"

# Address range to use for services
KUBE_SERVICE_ADDRESSES="--service-cluster-ip-range=${KUBE_CLUSTER_CIDR}"

# default admission control policies
KUBE_ADMISSION_CONTROL="--admission-control=NamespaceLifecycle,LimitRanger,SecurityContextDeny,ServiceAccount,ResourceQuota"

# Add your own!
KUBE_API_ARGS="--basic-auth-file=/etc/kubernetes/basic-auth.csv --service-account-key-file=/etc/kubernetes/service-account-private.key.pub --tls-cert-file=/etc/pki/tls/certs/kubernetes.crt --tls-private-key-file=/etc/pki/tls/private/kubernetes.key"
EOF
}

controller_manager_config () {
    cat <<"EOF"
###
# The following values are used to configure the kubernetes controller-manager

# defaults from config and apiserver should be adequate

# Add your own!
KUBE_CONTROLLER_MANAGER_ARGS="--service-account-private-key-file=/etc/kubernetes/service-account-private.key --root-ca-file=/etc/pki/tls/certs/kubernetes-ca.crt"
EOF
}

master_kubeconfig () {
    cat <<"EOF"
kind: Config
clusters:
  - name: local
    cluster:
      server: http://localhost:8080
users:
  - name: kubelet
contexts:
  - context:
      cluster: local
      user: kubelet
    name: kubelet-context
current-context: kubelet-context
EOF
}

basic_auth_config () {
    cat <<EOF
"${KUBE_ADMIN_PASSPHRASE}",admin,admin
EOF
}

flannel_etcd_config () {
    cat <<EOF
{
    "Network": "${OVERLAY_NETWORK_CIDR}",
    "SubnetLen": 24,
    "Backend": {
        "Type": "vxlan",
        "VNI": 1
     }
}
EOF
}

flanneld_config () {
    cat <<"EOF"
# Flanneld configuration options

# etcd url location.  Point this to the server where etcd runs
FLANNEL_ETCD_ENDPOINTS="http://localhost:2379"

# etcd config key.  This is the configuration key that flannel queries
# For address range assignment
FLANNEL_ETCD_PREFIX="/coreos.com/network"

# Any additional options that you want to pass
FLANNEL_OPTIONS=""
EOF
}

etcd_config () {
    cat <<"EOF"
# [member]
ETCD_NAME=default
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
#ETCD_WAL_DIR=""
#ETCD_SNAPSHOT_COUNT="10000"
#ETCD_HEARTBEAT_INTERVAL="100"
#ETCD_ELECTION_TIMEOUT="1000"
#ETCD_LISTEN_PEER_URLS="http://localhost:2380"
ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:2379"
#ETCD_MAX_SNAPSHOTS="5"
#ETCD_MAX_WALS="5"
#ETCD_CORS=""
#
#[cluster]
#ETCD_INITIAL_ADVERTISE_PEER_URLS="http://localhost:2380"
# if you use different ETCD_NAME (e.g. test), set ETCD_INITIAL_CLUSTER value for this name, i.e. "test=http://..."
#ETCD_INITIAL_CLUSTER="default=http://localhost:2380"
#ETCD_INITIAL_CLUSTER_STATE="new"
#ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
ETCD_ADVERTISE_CLIENT_URLS="http://localhost:2379"
#ETCD_DISCOVERY=""
#ETCD_DISCOVERY_SRV=""
#ETCD_DISCOVERY_FALLBACK="proxy"
#ETCD_DISCOVERY_PROXY=""
#ETCD_STRICT_RECONFIG_CHECK="false"
#ETCD_AUTO_COMPACTION_RETENTION="0"
#
#[proxy]
#ETCD_PROXY="off"
#ETCD_PROXY_FAILURE_WAIT="5000"
#ETCD_PROXY_REFRESH_INTERVAL="30000"
#ETCD_PROXY_DIAL_TIMEOUT="1000"
#ETCD_PROXY_WRITE_TIMEOUT="5000"
#ETCD_PROXY_READ_TIMEOUT="0"
#
#[security]
#ETCD_CERT_FILE=""
#ETCD_KEY_FILE=""
#ETCD_CLIENT_CERT_AUTH="false"
#ETCD_TRUSTED_CA_FILE=""
#ETCD_AUTO_TLS="false"
#ETCD_PEER_CERT_FILE=""
#ETCD_PEER_KEY_FILE=""
#ETCD_PEER_CLIENT_CERT_AUTH="false"
#ETCD_PEER_TRUSTED_CA_FILE=""
#ETCD_PEER_AUTO_TLS="false"
#
#[logging]
#ETCD_DEBUG="false"
# examples for -log-package-levels etcdserver=WARNING,security=DEBUG
#ETCD_LOG_PACKAGE_LEVELS=""
EOF
}

handle_apiserver_config_change () {
    SYSTEMCTL_ACTIONS[kube-apiserver]=try-restart
}

handle_kubelet_config_change () {
    SYSTEMCTL_ACTIONS[kubelet]=try-restart
}

handle_controller_manager_config_change () {
    SYSTEMCTL_ACTIONS[kube-controller-manager]=try-restart
}

handle_flanneld_config_change () {
    SYSTEMCTL_ACTIONS[flanneld]=try-restart
}

handle_etcd_config_change () {
    SYSTEMCTL_ACTIONS[etcd]=try-restart
}

setup_etcd () {
    msg "Setting up etcd"

    packages_ensure present etcd

    to_file /etc/etcd/etcd.conf handle_etcd_config_change < <(etcd_config)

    cmd systemctl enable etcd
    systemctl is-active -q etcd || cmd systemctl restart etcd
}


setup_flannel () {
    msg "Setting up Flannel"

    etcdctl set /coreos.com/network/config < <(flannel_etcd_config)

    packages_ensure present flannel

    to_file /etc/sysconfig/flanneld handle_flanneld_config_change < <(flanneld_config)

    systemctl enable flanneld
    systemctl is-active -q flanneld || cmd systemctl restart flanneld
}

setup_kubernetes () {
    local svc trusted_source

    msg "Setting up Kubernetes"

    packages_ensure present kubernetes

    to_file /etc/kubernetes/apiserver handle_apiserver_config_change < <(apiserver_config)
    to_file /etc/kubernetes/kubelet handle_kubelet_config_change < <(kubelet_config)
    to_file /etc/kubernetes/master-kubeconfig.yaml handle_kubelet_config_change < <(master_kubeconfig)
    to_file /etc/kubernetes/basic-auth.csv handle_apiserver_config_change < <(basic_auth_config)
    to_file /etc/kubernetes/controller-manager handle_controller_manager_config_change < <(controller_manager_config)
    cmd chmod 600 /etc/kubernetes/basic-auth.csv
    cmd chown kube:root /etc/kubernetes/basic-auth.csv

    [[ -f /etc/kubernetes/service-account-private.key ]] || cmd openssl genrsa -out /etc/kubernetes/service-account-private.key 2048
    [[ -f /etc/kubernetes/service-account-private.key.pub ]] || cmd openssl rsa -in /etc/kubernetes/service-account-private.key -pubout > /etc/kubernetes/service-account-private.key.pub
    cmd chown kube:root /etc/kubernetes/service-account-private.key

    msg "Starting master services"
    for svc in kube-apiserver kube-controller-manager kube-scheduler; do
        systemctl is-active -q "${svc}" || cmd systemctl restart "${svc}"
        cmd systemctl enable "${svc}"
    done

    msg "Starting node services"
    for svc in kube-proxy kubelet docker; do
        systemctl is-active -q "${svc}" || cmd systemctl restart "${svc}"
        cmd systemctl enable "${svc}"
    done

    cmd firewall-cmd --add-port=6443/tcp

    if [[ "${#TRUSTED_SOURCES[@]}" -gt 0 ]]; then
        for trusted_source in "${TRUSTED_SOURCES[@]}"; do
            cmd firewall-cmd --zone=trusted --add-source="${trusted_source}"
        done
    fi
    cmd firewall-cmd --runtime-to-permanent
}


main () {
    drop_ssl_files
    setup_etcd
    setup_flannel
    setup_kubernetes

    [[ "${#SYSTEMCTL_ACTIONS[@]}" -eq 0 ]] || for service in "${!SYSTEMCTL_ACTIONS[@]}"; do
        cmd systemctl "${SYSTEMCTL_ACTIONS[${service}]}" "${service}"
    done
}
