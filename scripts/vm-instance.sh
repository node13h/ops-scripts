#!/usr/bin/env bash

# MIT license
# Copyright 2020 Sergej Alikov <sergej.alikov@gmail.com>

_DOC='Create or destroy a cloud image-based VM instance on a Linux KVM host (libvirt)'

set -euo pipefail


usage () {
    cat <<EOM
${_DOC}

Usage: ${0} FLAGS create|destroy INSTANCE-CONFIG-FILE TARGET
       ${0} --help

FLAGS
  --yes                   Automatically approve the destroy action
  --destroy-disks-please  When destroying a VM destroy disks too

TARGET format is [user@]kvm.host.address[:port]

INSTANCE-CONFIG-FILE example:

---- 8< cut here 8<----------------
INSTANCE_NAME=test
INSTANCE_ID=f371060a-a886-4076-b61a-d279f7c57c1e
INSTANCE_NETWORK_BRIDGE=br0
INSTANCE_IP=192.168.100.100/24
INSTANCE_GW=192.168.100.1
INSTANCE_DNS1=1.1.1.1
INSTANCE_DNS2=8.8.8.8
INSTANCE_CLOUD_IMAGE=CentOS-8-GenericCloud-8.2.2004-20200611.2.x86_64.qcow2
INSTANCE_ROOT_VOLUME_SIZE=12G
INSTANCE_OS_VARIANT=centos8
INSTANCE_RAM_MB=2048

instance_user_data () {
  cat <<EOF
#cloud-config
password: passw0rd
chpasswd: { expire: False }
ssh_pwauth: True
EOF
}
---- 8< cut here 8<----------------

Note: the image specified in INSTANCE_CLOUD_IMAGE must already exist in /var/lib/libvirt/images.

EOM
}


if ! (return 2> /dev/null); then

    AUTO_APPROVE=FALSE
    DESTROY_DISKS=FALSE

    if ! command -v automated-config.sh >/dev/null; then
        echo "Please install automated from https://github.com/node13h/automated" >&2
        exit 1
    fi

    if ! command -v automated-extras-config.sh >/dev/null; then
        echo "Please install automated-extras from https://github.com/node13h/automated-extras" >&2
        exit 1
    fi

    # shellcheck disable=SC1091
    source automated-config.sh

    # shellcheck disable=SC1091,SC1090
    source "${AUTOMATED_LIBDIR}/libautomated.sh"

    if [[ "$#" -eq 0 ]]; then
        usage >&2
        exit 1
    fi

    while [[ "$#" -gt 0 ]]; do

        case "$1" in
            --help) usage
                    exit 0
                    ;;
            --yes)
                # shellcheck disable=SC2034
                AUTO_APPROVE=TRUE
                ;;
            --destroy-disks-please)
                # shellcheck disable=SC2034
                DESTROY_DISKS=TRUE
                ;;
            *)
                break
                ;;
        esac

        shift
    done

    # shellcheck disable=SC2034
    INSTANCE_ACTION="$1"
    INSTANCE_CONFIG="$2"

    shift 2

    if ! [[ "$INSTANCE_ACTION" =~ (create|destroy) ]]; then
        throw "Unrecognized action ${INSTANCE_ACTION}"
    fi

    if [[ "$INSTANCE_ACTION" == 'destroy' ]] && ! is_true "$AUTO_APPROVE"; then
        read -r -p 'Type yes to continue: '
        if ! [[ "$REPLY" == 'yes' ]]; then
            echo 'Aborting' >&2
            exit
        fi
    fi

    # shellcheck disable=SC1091
    source automated-extras-config.sh

    export INSTANCE_ACTION
    export DESTROY_DISKS

    # shellcheck disable=SC2016
    exec automated.sh \
         -s \
         -e INSTANCE_ACTION \
         -e DESTROY_DISKS \
         -l "${AUTOMATED_EXTRAS_LIBDIR}/automated-extras-config.sh" \
         -l "${AUTOMATED_EXTRAS_LIBDIR}/automated-extras.sh" \
         -l "${AUTOMATED_EXTRAS_LIBDIR}/os.sh" \
         -l "$INSTANCE_CONFIG" \
         -l "${BASH_SOURCE[0]}" \
         -c main \
         "$@"
fi


# Everything beyond this point will only be executed on the target (see exec above)


supported_automated_versions 0.2
supported_automated_extras_versions 0.2

TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TEMP_DIR%/}/seed_image"; rmdir "$TEMP_DIR"' EXIT

IMAGES_DIR=/var/lib/libvirt/images/
VM_VG=vg0


create_seed_image () {
    declare image_path="$1"

    mkdir -p "${TEMP_DIR%/}/seed_image"

    instance_user_data >"${TEMP_DIR%/}/seed_image/user-data"

    cat <<EOF >"${TEMP_DIR%/}/seed_image/meta-data"
instance-id: ${INSTANCE_ID}
local-hostname: ${INSTANCE_NAME}
EOF

    cat <<EOF >"${TEMP_DIR%/}/seed_image/network-config"
version: 2
ethernets:
    eth0:
        dhcp4: false
        dhcp6: false
        addresses:
          - ${INSTANCE_IP}
        gateway4: ${INSTANCE_GW}
        nameservers:
          addresses:
            - ${INSTANCE_DNS1}
            - ${INSTANCE_DNS2}
EOF

    cmd genisoimage \
        -output "$image_path" \
        -input-charset utf-8 \
        -volid cidata \
        -joliet \
        -rock \
        "${TEMP_DIR%/}/seed_image/user-data" \
        "${TEMP_DIR%/}/seed_image/meta-data" \
        "${TEMP_DIR%/}/seed_image/network-config"
}


create_instance () {
    declare -a expected_vars=(
        INSTANCE_NAME
        INSTANCE_ID
        INSTANCE_NETWORK_BRIDGE
        INSTANCE_IP
        INSTANCE_GW
        INSTANCE_DNS1
        INSTANCE_DNS2
        INSTANCE_CLOUD_IMAGE
        INSTANCE_ROOT_VOLUME_SIZE
        INSTANCE_OS_VARIANT
        INSTANCE_RAM_MB
    )

    declare var
    for var in "${expected_vars[@]}"; do
        [[ -v "$var" ]] || throw "Please set the ${var} variable!"
    done

    if ! declare -f instance_user_data >/dev/null; then
       throw "Please define the instance_user_data function!"
    fi

    packages_ensure present genisoimage

    cmd mkdir -p "$IMAGES_DIR"

    declare seed_image_file="${IMAGES_DIR%/}/vm-${INSTANCE_NAME}-seed.iso"
    if [[ -e "$seed_image_file" ]]; then
        throw "${seed_image_file} already exists!"
    fi

    msg "Creating the ${seed_image_file} metadata disk image"
    create_seed_image "$seed_image_file"

    declare instance_lv="vm-${INSTANCE_NAME}-hdd0"
    declare instance_lv_dev="/dev/${VM_VG}/${instance_lv}"

    if lvm lvs "${VM_VG}/${instance_lv}" &>/dev/null || [[ -e "$instance_lv_dev" ]]; then
        throw "${VM_VG}/${instance_lv} LV already exists!"
    fi

    msg "Creating the ${VM_VG}/${instance_lv} LVM volume"
    cmd lvcreate -L "$INSTANCE_ROOT_VOLUME_SIZE" -n "$instance_lv" "$VM_VG"
    cmd qemu-img convert -f qcow2 -O raw "${IMAGES_DIR%/}/${INSTANCE_CLOUD_IMAGE}" "$instance_lv_dev"

    msg "Creating the ${INSTANCE_NAME} instance"
    cmd virt-install \
        --connect qemu:///system \
        --hvm \
        --name "$INSTANCE_NAME" \
        --memory "$INSTANCE_RAM_MB" \
        --disk "${instance_lv_dev},device=disk,bus=virtio" \
        --disk "${seed_image_file},device=cdrom" \
        --os-variant "$INSTANCE_OS_VARIANT" \
        --virt-type kvm \
        --graphics none \
        --network "bridge=${INSTANCE_NETWORK_BRIDGE},model=virtio" \
        --import \
        --noautoconsole
}


destroy_instance () {
    declare -a expected_vars=(
        INSTANCE_NAME
    )

    declare var
    for var in "${expected_vars[@]}"; do
        [[ -v "$var" ]] || throw "Please set the ${var} variable!"
    done

    declare seed_image_file="${IMAGES_DIR%/}/vm-${INSTANCE_NAME}-seed.iso"

    declare instance_lv="vm-${INSTANCE_NAME}-hdd0"
    declare instance_lv_dev="/dev/${VM_VG}/${instance_lv}"

    if virsh -q list --state-running \
            | awk '{print $2}' \
            | grep "^${INSTANCE_NAME}$" >/dev/null; then

        msg "Destroying the ${INSTANCE_NAME} instance"
        cmd virsh destroy "$INSTANCE_NAME"
    fi

    if virsh -q list --all \
            | awk '{print $2}' \
            | grep "^${INSTANCE_NAME}$" >/dev/null; then

        msg "De-registering the ${INSTANCE_NAME} instance"
        cmd virsh undefine "$INSTANCE_NAME"
    fi

    if is_true "$DESTROY_DISKS"; then
        if lvm lvs "${VM_VG}/${instance_lv}" &>/dev/null || [[ -e "$instance_lv_dev" ]]; then
            msg "Destroying the ${VM_VG}/${instance_lv} VM volume"
            cmd lvremove -f "${VM_VG}/${instance_lv}"
        fi
    fi

    if [[ -e "$seed_image_file" ]]; then
        msg "Deleting the ${seed_image_file} metadata disk image"
        cmd rm -f -- "$seed_image_file"
    fi
}


main () {
    case "$INSTANCE_ACTION" in
        create)
            create_instance
            ;;
        destroy)
            destroy_instance
            ;;
    esac
}
