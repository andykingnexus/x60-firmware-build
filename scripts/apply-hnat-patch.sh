#!/usr/bin/env bash

set -euo pipefail


ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OPENWRT_DIR="${ROOT_DIR}/openwrt"


echo "===== Check MediaTek HNAT dependency ====="


cd "${OPENWRT_DIR}"


echo "Searching IP_NF_NAT references..."

MATCHES=$(grep -RIl \
    --include='*.patch' \
    --include='Kconfig' \
    'IP_NF_NAT' \
    target/linux/mediatek \
    || true)


if [ -z "${MATCHES}" ]; then

    echo "No IP_NF_NAT dependency found."

    echo "HNAT may already use NF_NAT."

    exit 0

fi


echo "Found files:"
echo "${MATCHES}"


PATCH_FILE="${ROOT_DIR}/patches/zzz-999-mtkhnat-use-generic-nf-nat-dependency.patch"


if [ ! -f "${PATCH_FILE}" ]; then

    echo "ERROR: HNAT patch missing"

    exit 1

fi



echo "Testing patch applicability..."


git apply \
    --check \
    "${PATCH_FILE}" \
    || {

        echo

        echo "Patch cannot be applied."

        echo "Current HNAT source does not match expected context."

        echo

        grep -Rns \
            --include='*.patch' \
            --include='Kconfig' \
            'IP_NF_NAT' \
            target/linux/mediatek \
            || true

        exit 1

    }



echo "Applying HNAT NF_NAT patch"


git apply "${PATCH_FILE}"



echo

echo "Verify remaining IP_NF_NAT"


if grep -Rqs \
    --include='*.patch' \
    --include='Kconfig' \
    'IP_NF_NAT' \
    target/linux/mediatek
then

    echo "ERROR: IP_NF_NAT still exists"

    grep -Rns \
        --include='*.patch' \
        --include='Kconfig' \
        'IP_NF_NAT' \
        target/linux/mediatek

    exit 1

fi



echo

echo "HNAT dependency fixed:"
echo

grep -Rns \
    --include='*.patch' \
    --include='Kconfig' \
    'NF_NAT' \
    target/linux/mediatek \
    || true


echo

echo "Done."
