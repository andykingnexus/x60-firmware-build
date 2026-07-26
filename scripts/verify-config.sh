#!/usr/bin/env bash

set -euo pipefail


CONFIG_FILE="${1:-openwrt/.config}"


if [ ! -f "${CONFIG_FILE}" ]; then

    echo "ERROR: ${CONFIG_FILE} not found"

    exit 1

fi



check_yes()
{

    local item="$1"


    if grep -qx "${item}=y" "${CONFIG_FILE}"
    then

        echo "OK   ${item}"

    else

        echo "FAIL ${item}"

        exit 1

    fi

}



check_no()
{

    local item="$1"


    if grep -qx "${item}=y" "${CONFIG_FILE}"
    then

        echo "FAIL ${item} should be disabled"

        exit 1

    else

        echo "OK   disabled ${item}"

    fi

}



echo

echo "===== Target ====="


check_yes \
CONFIG_TARGET_mediatek_filogic_DEVICE_ruijie-rg-x60



echo

echo "===== HNAT ====="


check_yes CONFIG_PACKAGE_kmod-mediatek_hnat



echo

echo "===== firewall4 nft ====="


check_yes CONFIG_PACKAGE_firewall4

check_yes CONFIG_PACKAGE_nftables



echo

echo "===== eBPF / BTF ====="


check_yes CONFIG_KERNEL_CGROUPS

check_yes CONFIG_KERNEL_KPROBES

check_yes CONFIG_KERNEL_KPROBE_EVENTS

check_yes CONFIG_KERNEL_BPF_EVENTS

check_yes CONFIG_KERNEL_BPF_STREAM_PARSER

check_yes CONFIG_KERNEL_DEBUG_INFO

check_yes CONFIG_KERNEL_DEBUG_INFO_BTF

check_yes CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES

check_yes CONFIG_KERNEL_XDP_SOCKETS

check_yes CONFIG_PACKAGE_kmod-xdp-sockets-diag



echo

echo "===== Remove legacy iptables ====="



REMOVE_LIST=(

CONFIG_PACKAGE_iptables-legacy

CONFIG_PACKAGE_iptables-nft

CONFIG_PACKAGE_ip6tables-nft

CONFIG_PACKAGE_ip6tables-extra

CONFIG_PACKAGE_xtables-nft

CONFIG_PACKAGE_ipset

CONFIG_PACKAGE_libipset

CONFIG_PACKAGE_libxtables

CONFIG_PACKAGE_kmod-ip6tables

CONFIG_PACKAGE_kmod-ipt-core

CONFIG_PACKAGE_kmod-ipt-compat-xtables

CONFIG_PACKAGE_kmod-ipt-conntrack

CONFIG_PACKAGE_kmod-ipt-nat

CONFIG_PACKAGE_kmod-ipt-offload

CONFIG_PACKAGE_ebtables-legacy

CONFIG_PACKAGE_ebtables-legacy-utils

)



for item in "${REMOVE_LIST[@]}"
do

    check_no "${item}"

done



echo

echo "===== Config verification passed ====="
