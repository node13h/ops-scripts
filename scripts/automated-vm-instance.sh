#!/usr/bin/env bash

# MIT license
# Copyright 2020-2021 Sergej Alikov <sergej.alikov@gmail.com>

_DOC='Create or destroy a cloud image-based VM instance on a Linux KVM host (libvirt)'

set -euo pipefail


usage () {
    exit_code="${1:-0}"
    error_message="${2:-}"

    if [[ -n "$error_message" ]]; then
        printf 'ERROR: %s\n\n' "$error_message" >&2
    fi

    cat <<EOM
${_DOC}

Usage: ${0} FLAGS create|destroy CONFIG-FILE AUTOMATED-ARGS
       ${0} --help

FLAGS
  --yes                   Automatically approve the destroy action
  --destroy-disks-please  When destroying a VM destroy disks too

CONFIG-FILE example:

---- 8< cut here 8<----------------
INSTANCE_NAME=test
INSTANCE_ID=f371060a-a886-4076-b61a-d279f7c57c1e
INSTANCE_NETWORK_BRIDGE=br0
INSTANCE_IP=192.168.100.100/24
INSTANCE_MTU=9000
INSTANCE_GW=192.168.100.1
INSTANCE_DNS1=1.1.1.1
INSTANCE_DNS2=8.8.8.8
INSTANCE_CLOUD_IMAGE=CentOS-8-GenericCloud-8.2.2004-20200611.2.x86_64.qcow2
# INSTANCE_ROOT_VG=vg0
INSTANCE_ROOT_VOLUME_SIZE=12G
INSTANCE_RAM_MB=2048
INSTANCE_VCPUS=2

instance_user_data () {
  cat <<EOF
#cloud-config
users:
  - name: myuser
    gecos: My Custom User
    primary_group: myuser
    groups: wheel
    lock_passwd: false
    passwd: <PASSWORD-HASH-HERE>
    ssh_authorized_keys:
      - <SSH-PUBLIC-KEY-HERE>
packages:
  - python3
  - tmux
  - system-release
  - patch
EOF
}
---- 8< cut here 8<----------------

Note: the image specified in INSTANCE_CLOUD_IMAGE must already exist in /var/lib/libvirt/images.

EOM

    exit "$exit_code"
}


if ! (return 2> /dev/null); then
    # shellcheck disable=SC1091
    source automated-config.sh

    # shellcheck disable=SC1091,SC1090
    source "${AUTOMATED_LIBDIR}/libautomated.sh"

    if ! command -v automated-config.sh >/dev/null; then
        echo "Please install automated from https://github.com/node13h/automated" >&2
        exit 1
    fi

    if ! command -v automated-extras-config.sh >/dev/null; then
        echo "Please install automated-extras from https://github.com/node13h/automated-extras" >&2
        exit 1
    fi

    AUTO_APPROVE=FALSE
    DESTROY_DISKS=FALSE

    while [[ "$#" -gt 0 ]]; do

        case "$1" in
            --help) usage
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

    [[ "$#" -gt 2 ]] || usage 1

    ACTION="$1"
    CONFIG_FILE="$2"

    shift 2

    case "$ACTION" in
        create)
            declare -a required_vars=(
                INSTANCE_NAME
                INSTANCE_ID
                INSTANCE_NETWORK_BRIDGE
                INSTANCE_IP
                INSTANCE_GW
                INSTANCE_DNS1
                INSTANCE_DNS2
                INSTANCE_CLOUD_IMAGE
                INSTANCE_ROOT_VOLUME_SIZE
                INSTANCE_RAM_MB
                INSTANCE_VCPUS
            )
            ;;
        destroy)
            declare -a required_vars=(INSTANCE_NAME)
            ;;
        *)
            usage 1 "Unrecognized action ${ACTION}"
            ;;
    esac

    if [[ "$ACTION" == 'destroy' ]] && ! is_true "$AUTO_APPROVE"; then
        read -r -p 'Type yes to continue: '
        if ! [[ "$REPLY" == 'yes' ]]; then
            echo 'Aborting' >&2
            exit
        fi
    fi

    # shellcheck disable=SC1091
    source automated-extras-config.sh

    # Config defaults
    INSTANCE_ROOT_VG=vg0
    INSTANCE_MTU=1500

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    declare var
    for var in "${required_vars[@]}"; do
        if ! [[ -v "$var" ]]; then
            printf 'ERROR: Required config variable %s is not set!\n' "$var" >&2
            exit 1
        fi
    done

    export ACTION
    export DESTROY_DISKS

    # shellcheck disable=SC2016
    exec automated.sh \
         -e ACTION \
         -e DESTROY_DISKS \
         -l "${AUTOMATED_EXTRAS_LIBDIR}/automated-extras-config.sh" \
         -l "${AUTOMATED_EXTRAS_LIBDIR}/automated-extras.sh" \
         -l "${AUTOMATED_EXTRAS_LIBDIR}/os.sh" \
         -l "${BASH_SOURCE[0]}" \
         -l "$CONFIG_FILE" \
         -c main \
         -- \
         "$@"
fi


# Everything beyond this point will only be executed on the target (see exec above)


supported_automated_versions 0.3
supported_automated_extras_versions 0.3

TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TEMP_DIR%/}/seed_image"; rmdir "$TEMP_DIR"' EXIT

IMAGES_DIR=/var/lib/libvirt/images/


# This function may be overridden in the config file
instance_user_data () {
    echo
}


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
        mtu: ${INSTANCE_MTU}
        gateway4: ${INSTANCE_GW}
        nameservers:
          addresses:
            - ${INSTANCE_DNS1}
            - ${INSTANCE_DNS2}
EOF

    genisoimage \
        -output "$image_path" \
        -input-charset utf-8 \
        -volid cidata \
        -joliet \
        -rock \
        "${TEMP_DIR%/}/seed_image/user-data" \
        "${TEMP_DIR%/}/seed_image/meta-data" \
        "${TEMP_DIR%/}/seed_image/network-config"
}


domain_xml () {
    declare instance_lv_dev="$1"
    declare seed_image_file="$2"

    cat <<EOF
<domain type='kvm'>
  <name>${INSTANCE_NAME}</name>
  <uuid>${INSTANCE_ID}</uuid>
  <memory unit='MiB'>${INSTANCE_RAM_MB}</memory>
  <currentMemory unit='MiB'>${INSTANCE_RAM_MB}</currentMemory>
  <vcpu placement='static'>${INSTANCE_VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='pc-i440fx-rhel7.0.0'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-model' check='partial'>
    <model fallback='allow'/>
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native'/>
      <source dev='${instance_lv_dev}'/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x06' function='0x0'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${seed_image_file}'/>
      <target dev='hda' bus='ide'/>
      <readonly/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>
    <controller type='usb' index='0' model='ich9-ehci1'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x7'/>
    </controller>
    <controller type='usb' index='0' model='ich9-uhci1'>
      <master startport='0'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0' multifunction='on'/>
    </controller>
    <controller type='usb' index='0' model='ich9-uhci2'>
      <master startport='2'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x1'/>
    </controller>
    <controller type='usb' index='0' model='ich9-uhci3'>
      <master startport='4'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x2'/>
    </controller>
    <controller type='pci' index='0' model='pci-root'/>
    <controller type='ide' index='0'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x01' function='0x1'/>
    </controller>
    <controller type='virtio-serial' index='0'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
    </controller>
    <interface type='bridge'>
      <source bridge='${INSTANCE_NETWORK_BRIDGE}'/>
      <model type='virtio'/>
      <!--
        TODO: CentOS7 throws "setting MTU is not supported with this QEMU binary", so
        need to make this conditional.
        There is still a way to set the MTU on vnet* interfaces - via a udev persistent
        net rule like this:
        $ cat /etc/udev/rules.d/70-persistent-net.rules
        SUBSYSTEM=="net", ACTION=="add", KERNEL=="vnet*", ATTR{mtu}="9000"
      <mtu size='${INSTANCE_MTU}'/>
      -->
      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0'/>
    </interface>
    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
      <address type='virtio-serial' controller='0' bus='0' port='1'/>
    </channel>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <memballoon model='virtio'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x07' function='0x0'/>
    </memballoon>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x08' function='0x0'/>
    </rng>
  </devices>
</domain>
EOF
}


create_instance () {
    os_packages_ensure present genisoimage lvm2

    mkdir -p "$IMAGES_DIR"

    declare seed_image_file="${IMAGES_DIR%/}/vm-${INSTANCE_NAME}-seed.iso"
    if [[ -e "$seed_image_file" ]]; then
        throw "${seed_image_file} already exists!"
    fi

    log_info "Creating the ${seed_image_file} metadata disk image"
    create_seed_image "$seed_image_file"

    # TODO: Support both file-based and LVM-based disk images
    declare instance_lv="vm-${INSTANCE_NAME}-hdd0"
    declare instance_lv_dev="/dev/${INSTANCE_ROOT_VG}/${instance_lv}"

    if lvm lvs "${INSTANCE_ROOT_VG}/${instance_lv}" &>/dev/null || [[ -e "$instance_lv_dev" ]]; then
        throw "${INSTANCE_ROOT_VG}/${instance_lv} LV already exists!"
    fi

    log_info "Creating the ${INSTANCE_ROOT_VG}/${instance_lv} LVM volume"
    lvcreate -L "$INSTANCE_ROOT_VOLUME_SIZE" -n "$instance_lv" "$INSTANCE_ROOT_VG"
    qemu-img convert -O raw "${IMAGES_DIR%/}/${INSTANCE_CLOUD_IMAGE}" "$instance_lv_dev"

    log_info "Creating the ${INSTANCE_NAME} instance"

    virsh define <(domain_xml "$instance_lv_dev" "$seed_image_file")
    [[ "$(virsh domstate "$INSTANCE_NAME")" == 'running' ]] || virsh start "$INSTANCE_NAME"
}


destroy_instance () {
    declare seed_image_file="${IMAGES_DIR%/}/vm-${INSTANCE_NAME}-seed.iso"

    declare instance_lv="vm-${INSTANCE_NAME}-hdd0"
    declare instance_lv_dev="/dev/${INSTANCE_ROOT_VG}/${instance_lv}"

    if virsh -q list --state-running \
            | awk '{print $2}' \
            | grep "^${INSTANCE_NAME}$" >/dev/null; then

        log_info "Destroying the ${INSTANCE_NAME} instance"
        virsh destroy "$INSTANCE_NAME"
    fi

    if virsh -q list --all \
            | awk '{print $2}' \
            | grep "^${INSTANCE_NAME}$" >/dev/null; then

        log_info "De-registering the ${INSTANCE_NAME} instance"
        virsh undefine "$INSTANCE_NAME"
    fi

    if is_true "$DESTROY_DISKS"; then
        if lvm lvs "${INSTANCE_ROOT_VG}/${instance_lv}" &>/dev/null || [[ -e "$instance_lv_dev" ]]; then
            log_info "Destroying the ${INSTANCE_ROOT_VG}/${instance_lv} VM volume"
            lvremove -f "${INSTANCE_ROOT_VG}/${instance_lv}"
        fi
    fi

    if [[ -e "$seed_image_file" ]]; then
        log_info "Deleting the ${seed_image_file} metadata disk image"
        rm -f -- "$seed_image_file"
    fi
}


main () {
    case "$ACTION" in
        create)
            create_instance
            ;;
        destroy)
            destroy_instance
            ;;
    esac
}
