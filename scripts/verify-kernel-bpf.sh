#!/usr/bin/env bash

set -euo pipefail


OPENWRT_DIR="${1:-openwrt}"


KERNEL_CONFIG=$(find \
"${OPENWRT_DIR}/build_dir" \
-path '*linux-6.6*/.config' \
-type f \
| head -n 1)



if [ -z "${KERNEL_CONFIG}" ]; then

    echo "ERROR: Linux kernel .config not found"

    exit 1

fi



echo "Using kernel config:"
echo "${KERNEL_CONFIG}"

echo



check_kernel()
{
    local option="$1"

    if grep -qx "${option}=y" "${KERNEL_CONFIG}"
    then
        echo "OK   ${option}"
    else
        echo "FAIL ${option}"
        exit 1
    fi
}



echo "===== Required Linux eBPF/BTF ====="


check_kernel CONFIG_BPF

check_kernel CONFIG_BPF_SYSCALL

check_kernel CONFIG_BPF_JIT

check_kernel CONFIG_BTF

check_kernel CONFIG_DEBUG_INFO

check_kernel CONFIG_DEBUG_INFO_BTF

check_kernel CONFIG_DEBUG_INFO_BTF_MODULES

check_kernel CONFIG_KPROBES

check_kernel CONFIG_KPROBE_EVENTS

check_kernel CONFIG_BPF_EVENTS

check_kernel CONFIG_CGROUPS

check_kernel CONFIG_CGROUP_BPF

check_kernel CONFIG_XDP_SOCKETS



echo

echo "Kernel eBPF/BTF verification passed."
